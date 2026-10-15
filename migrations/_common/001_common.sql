-- =============================================================================
-- Общие объекты. Применяется к КАЖДОЙ из четырёх баз первым.
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- для EXCLUDE по интервалам (I5)

CREATE SCHEMA IF NOT EXISTS ref;             -- локальные копии общих справочников
CREATE SCHEMA IF NOT EXISTS contract;        -- интерфейс для DWH

-- updated_at обновляется автоматически при любом UPDATE (ADR-0010).
-- Генератор может записать исторический updated_at, включив в сессии
-- SET app.backfill = 'on' (только для загрузки истории).
CREATE OR REPLACE FUNCTION ref.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF coalesce(current_setting('app.backfill', true), 'off') = 'on'
       AND NEW.updated_at IS DISTINCT FROM OLD.updated_at THEN
        RETURN NEW;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- Business key неизменяем (I2, ADR-0001). Имя колонки - аргумент триггера.
CREATE OR REPLACE FUNCTION ref.forbid_bk_change() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    col text := TG_ARGV[0];
BEGIN
    IF to_jsonb(NEW) ->> col IS DISTINCT FROM to_jsonb(OLD) ->> col THEN
        RAISE EXCEPTION 'business key %.% is immutable: % -> %',
              TG_TABLE_NAME, col, to_jsonb(OLD) ->> col, to_jsonb(NEW) ->> col
              USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;

-- Справочник регионов ISO 3166-2:RU (ADR-0002). Одинаковая копия в каждой базе.
CREATE TABLE ref.region (
    region_code   text PRIMARY KEY CHECK (region_code ~ '^RU-[A-Z]{2,3}$'),
    region_name   text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_region_updated_at BEFORE UPDATE ON ref.region
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();

INSERT INTO ref.region (region_code, region_name) VALUES
    ('RU-MOW','Москва'), ('RU-MOS','Московская область'), ('RU-NIZ','Нижегородская область'),
    ('RU-TVE','Тверская область'), ('RU-RYA','Рязанская область'), ('RU-KLU','Калужская область'),
    ('RU-TUL','Тульская область'), ('RU-YAR','Ярославская область'),
    ('RU-SPE','Санкт-Петербург'), ('RU-LEN','Ленинградская область'), ('RU-ARK','Архангельская область'),
    ('RU-KR','Республика Карелия'), ('RU-MUR','Мурманская область'),
    ('RU-ROS','Ростовская область'), ('RU-KDA','Краснодарский край'), ('RU-VGG','Волгоградская область'),
    ('RU-STA','Ставропольский край'),
    ('RU-TA','Республика Татарстан'), ('RU-SAM','Самарская область'), ('RU-UD','Удмуртская Республика'),
    ('RU-PER','Пермский край'), ('RU-SVE','Свердловская область'), ('RU-CHE','Челябинская область'),
    ('RU-TYU','Тюменская область'),
    ('RU-NVS','Новосибирская область'), ('RU-OMS','Омская область'), ('RU-TOM','Томская область'),
    ('RU-KEM','Кемеровская область'), ('RU-KYA','Красноярский край'), ('RU-IRK','Иркутская область'),
    ('RU-BU','Республика Бурятия'),
    ('RU-KHA','Хабаровский край'), ('RU-PRI','Приморский край'), ('RU-SA','Республика Саха (Якутия)'),
    ('RU-SAK','Сахалинская область');

-- Журнал запусков генератора: делает seed идемпотентным
-- (повторный запуск с тем же ключом ничего не меняет).
CREATE TABLE ref.seed_log (
    run_key     text PRIMARY KEY,          -- 'base:seed=42:as_of=2026-10-15' / 'delta:...'
    kind        text NOT NULL CHECK (kind IN ('base','delta')),
    seed        int  NOT NULL,
    as_of       date NOT NULL,
    details     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_seed_log_updated_at BEFORE UPDATE ON ref.seed_log
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();
