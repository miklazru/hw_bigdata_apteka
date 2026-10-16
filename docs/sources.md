# Лог внешних источников

| что | откуда | где использовано |
|-----|--------|------------------|
| структура compose для PG18 (PGDATA, конфиг вне PGDATA) | `week02/sem/demo2_automated_replication` репозитория курса | ранняя версия стенда |
| конфиг PgBouncer (transaction pooling, userlist) | `week02/sem/demo3_pgbouncer` | `config/pgbouncer.ini` |
| образ Patroni, `patroni.yml`, `haproxy.cfg` (проверки `/primary`, `/replica`) | `week02/sem/demo4_ha_patroni` | `docker/patroni/`, `config/haproxy.cfg` |
| кворумный etcd, `post_bootstrap`, `checkpoint: fast` | документация Patroni и etcd | `docker-compose.yml`, `docker/patroni/patroni.yml` |
| коды регионов | ISO 3166-2:RU | `migrations/_common/001_common.sql` |
| проектирование, SQL, генератор, скрипты экспериментов — с помощью LLM (Claude); решения приняты и проверены вручную, все измерения в журнале — на собственном стенде | — | весь репозиторий |
