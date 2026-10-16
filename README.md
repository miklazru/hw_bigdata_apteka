# «Аптека 108» — источники данных и отказоустойчивый кластер (ДЗ №1)

Курс «Modern Storages and Data Warehousing», ФТиАД НИУ ВШЭ, 2026.
Выполняет в одиночку: Новиков Матвей (`@miklazru`). Ветка сдачи — `hw1`.

Четыре независимые базы сети аптек — `crm_service_db`, `catalog_service_db`,
`pos_service_db`, `wms_service_db` — спроектированы под последующую сборку DWH (ДЗ2–4):
стабильные business keys, история изменяемых атрибутов, snapshot-поля в фактах,
soft delete, контракт `contract.*` и готовность к CDC. Базы живут в HA-кластере
Patroni (3 узла PostgreSQL 18) за HAProxy и PgBouncer.

## Быстрый старт

```bash
docker compose up -d --build        # первая сборка образа Patroni - несколько минут
./scripts/wait_ready.sh             # лидер + 2 streaming-реплики, схема contract во всех базах, пул
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
./scripts/seed.sh --seed 42         # ~1 минута: ~24.6 тыс. чеков, 13 месяцев истории
python3 hw01_check.py --submission hw01_submission.yaml
```

Пересоздать стенд с нуля (например, после изменения миграций): `docker compose down -v`.
Схема создаётся автоматически один раз — при бутстрапе кластера.

## Подключения (connection strings)

| что | строка подключения |
|-----|--------------------|
| **PgBouncer** (пул, запись → лидер) | `postgresql://app:app@localhost:6432/<db>` · чекер: `postgresql://checker:checker@localhost:6432/<db>` |
| **HAProxy, запись** (текущий лидер) | `postgresql://postgres:postgres@localhost:5000/<db>` |
| **HAProxy, чтение** (реплики, round robin) | `postgresql://checker:checker@localhost:5001/<db>` |
| узлы напрямую (отладка) | `localhost:5441` (pg1), `localhost:5442` (pg2), `localhost:5443` (pg3) |
| Patroni REST API | `http://localhost:8008` (pg1), `:8009` (pg2), `:8010` (pg3) — `GET /cluster` |
| HAProxy, статистика | `http://localhost:7000` |
| etcd | `http://localhost:2379` (etcd1; кластер из etcd1–3) |

`<db>` — `crm_service_db` | `catalog_service_db` | `pos_service_db` | `wms_service_db`.

Роли: `postgres` — суперпользователь; `app` — приложение и генератор (чтение/запись, без `DELETE`);
`checker` — только `SELECT` в схеме `contract` (+ `pg_read_all_stats` для мониторинга реплики);
`replicator` — физическая репликация. Пароли совпадают с именами (учебный стенд).

## Что где

| путь | содержимое |
|------|------------|
| `docker-compose.yml` | стенд: etcd ×3, Patroni ×3 (PG 18), HAProxy, PgBouncer |
| `docker/patroni/` | образ узла (PG 18 + Patroni 4.1.5) и `patroni.yml` |
| `config/` | `haproxy.cfg`, `pgbouncer.ini`, `userlist.txt` |
| `migrations/` | DDL: `_common/001` (общие функции, регионы, журнал seed) → `<сервис>/001_schema.sql`, `002_contract.sql` → `_common/900` (publication, права) |
| `scripts/apply_migrations.sh` | создаёт роли и 4 базы, применяет миграции; вызывается Patroni (`post_bootstrap`) |
| `scripts/seed.sh` | генератор данных ([docs/generator.md](docs/generator.md)) |
| `scripts/wait_ready.sh` | ожидание готовности стенда |
| `scripts/failover/` | эксперименты журнала отказоустойчивости (`e1_…e8_*.sh`, `lab.py`) |
| `tests/invariants/` | 12 негативных + 2 положительных теста |
| `docs/erd/` | ER-диаграммы четырёх баз (mermaid) |
| `docs/adr/` | журнал архитектурных решений (10 записей) |
| `docs/dwh_mapping.md` | карта склейки источников для DWH |
| `docs/failover_journal.md` | журнал отказоустойчивости, сырые логи — `docs/failover/raw/` |
| `docs/geography.md`, `docs/assumptions.md` | география сети и допущения модели |
| `docs/sources.md` | лог внешних источников |

## Архитектура стенда

```
 приложение / генератор / чекер
        │                    │
   PgBouncer :6432      HAProxy :5000 (запись)    HAProxy :5001 (чтение)
        └──────────┬─────────┘                         │
                   ▼  GET /primary = 200               ▼  GET /replica = 200
           ┌──────────────┐   streaming   ┌──────────────┐ ┌──────────────┐
           │ pg1 (лидер)  │ ────────────► │ pg2 (реплика)│ │ pg3 (реплика)│
           └──────┬───────┘   + слоты     └──────┬───────┘ └──────┬───────┘
                  └──────────── Patroni ─────────┴────────────────┘
                                   │ leader key, ttl = 30 c
                        etcd1 ─ etcd2 ─ etcd3 (кворум 2 из 3)
```

* Асинхронная физическая репликация, физический слот на каждую реплику (`use_slots`).
* `wal_level = logical` на всех узлах (задан в DCS) — для CDC в ДЗ2.
* Схема создаётся на первом лидере скриптом `post_bootstrap`, реплики получают её репликацией.
* HAProxy узнаёт лидера у Patroni REST API; PgBouncer смотрит в HAProxy, поэтому после
  failover клиентам не нужно знать новый адрес.

## Модель данных — ключевые решения

Подробно — в [ADR](docs/adr/README.md) и [ER-диаграммах](docs/erd/README.md).

* **Business keys** `SKU-000148`, `PH-0001`, `RCPT-20261014-000731`, `BATCH-2026-04417`;
  суррогатный `bigint identity` внутри базы, наружу — только BK; BK неизменяем (триггер) — ADR-0001.
* **Никаких FK между базами**: ссылки по BK, проверка формата `CHECK`; регионы — коды ISO 3166-2
  с копией справочника в каждой базе — ADR-0002.
* **Цены** — SCD2 + `EXCLUDE USING gist` на пересечение интервалов, `is_current` — generated-колонка — ADR-0003.
* **Остаток** материализован в `wms.stock`, пересчитывается триггером на `movement`, `CHECK >= 0` — ADR-0004.
* **I10**: POS хранит `is_rx_snapshot`, рецепт привязан к позиции, `CHECK` — ADR-0005.
* **История** названия/категории SKU и уровня/города клиента — журнал через триггер — ADR-0006.
* **Продажи на складе** — дневной агрегат `sale_writeoff` — ADR-0007.
* **«Забывание» клиента**: PII в отдельной таблице, автообезличивание триггером, POS обнуляет ссылки — ADR-0008.
* **Snapshot** цены, названия, признака Rx и срока годности — в позиции чека.
* **Soft delete** (`deleted_at`) и `updated_at` через триггер — ADR-0010.

### Инварианты (все — средствами СУБД)

| № | инвариант | реализация | тест / SQLSTATE |
|---|-----------|------------|-----------------|
| I1 | BK уникален | `UNIQUE (sku_bk)` | `23505` |
| I2 | BK неизменяем | триггер `ref.forbid_bk_change` | `P0001` |
| I3 | сумма чека = сумма позиций | `CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED` | `P0001` на COMMIT |
| I4 | арифметика позиции | `CHECK` (`line_amount` — обычная колонка) | `23514` |
| I5 | интервалы цены не пересекаются | `EXCLUDE USING gist` (`btree_gist`) | `23P01` |
| I6 | одно активное согласие данного типа | partial `UNIQUE INDEX … WHERE revoked_at IS NULL` | `23505` |
| I7 | остаток ≥ 0 | `CHECK` на `wms.stock` + триггер на `movement` | `23514` |
| I8 | не продать просрочку | триггер: дата чека по местному времени аптеки ≤ `expiry_date_snapshot` | `P0001` |
| I9 | не принять просрочку | триггер на `wms.batch` | `P0001` |
| I10 | Rx только по рецепту | `CHECK (NOT is_rx_snapshot OR prescription_id IS NOT NULL)` | `23514` |
| I11 | возврат ≤ продано | триггер с блокировкой родительского чека | `P0001` |
| I12 | сумма оплат = сумма чека | `CONSTRAINT TRIGGER … DEFERRED` | `P0001` на COMMIT |
| P1 | `updated_at` обновляется сам | `BEFORE UPDATE` триггер | `ok = true` |
| P2 | soft delete скрывает клиента | `deleted_at` + триггер обезличивания | `ok = true` |

Тесты используют зарезервированные BK (`*-99xx`, `SKU-9999xx`, `CUST-99999xx`, `RCPT-2999…`) и
проходят как на пустой, так и на заполненной базе.

## Генератор данных

`./scripts/seed.sh --seed 42` — симуляция года работы сети по дням: закупки → партии →
РЦ → аптеки → продажи из партий на полке (FEFO), по действующей цене, с рецептами, оплатами,
возвратами, списаниями просрочки. Детерминированный, идемпотентный (`ref.seed_log`),
умеет догенерацию (`--seed 777 --receipts 500`). Распределения для бонуса «реалистичные данные» —
в [docs/generator.md](docs/generator.md).

## Результат самопроверки

`python3 hw01_check.py --submission hw01_submission.yaml` на стенде из этого репозитория:

| секция | результат |
|--------|-----------|
| контракт, обязательность, уникальность | 14/14, 27/27 |
| объёмы, C01–C23, X01–X10 | 14/14, 23/23, 10/10 |
| репликация и пул (после `seed_delta` отпечатки мастера и реплики совпадают) | 9/9 |
| инварианты | 14/14 (+ leakage) |
| CDC | 16/16 |
| реалистичность данных | 5/5 |
| HA-кластер | 5/6 — см. ниже |

### Известная проблема чекера: `running 1 из 3`

Проверка «все узлы в состоянии running» не учитывает, что Patroni ≥ 3.0 (в том числе 4.1.5 из
`week02/sem/demo4_ha_patroni`) в `GET /cluster` отдаёт для реплик `state = "streaming"`
(`patroni/utils.py`, `cluster_as_json`: `state = replication_state or state`). На здоровом кластере
это выглядит так:

```
members  pg1:leader/running; pg2:replica/streaming; pg3:replica/streaming
running  running 1 из 3
```

Состояние `streaming` для реплики — нормальное и даже более точное, чем `running`. Остальные
HA-проверки (3 узла, один лидер, HAProxy разводит запись и чтение) проходят.

## Допущения

Собраны в [docs/assumptions.md](docs/assumptions.md); главное:

* моделируется подмножество сети из легенды: 35 регионов, 6 РЦ, 74 аптеки; сеть в фазе
  экспансии — плотное ядро и пилотные аптеки в удалённых регионах;
* `return` в WMS — возврат поставщику; возвраты покупателей — брак и в остаток не возвращаются;
* продажи списываются со склада дневным агрегатом;
* «забывание» клиента затрагивает CRM и POS.

## Источники

[docs/sources.md](docs/sources.md): структура стенда — по мотивам семинарских демо курса
(`week02/sem/demo2…demo4`); при проектировании и написании кода использовалась LLM (Claude),
решения приняты и проверены вручную, все измерения — на собственном стенде.
