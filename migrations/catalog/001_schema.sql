-- =============================================================================
-- catalog_service_db: номенклатура и цены
-- =============================================================================
CREATE SCHEMA catalog;

CREATE TABLE catalog.manufacturer (
    manufacturer_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    manufacturer_bk    text NOT NULL UNIQUE CHECK (manufacturer_bk ~ '^MFR-\d{4}$'),
    manufacturer_name  text NOT NULL,
    country_code       char(2) NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    source_system      text NOT NULL DEFAULT 'CAT',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz
);

CREATE TABLE catalog.drug_form (
    drug_form_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    form_code     text NOT NULL UNIQUE CHECK (form_code ~ '^[a-z_]+$'),
    form_name     text NOT NULL,
    source_system text NOT NULL DEFAULT 'CAT',
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);

CREATE TABLE catalog.inn (                       -- МНН, действующее вещество
    inn_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inn_bk        text NOT NULL UNIQUE CHECK (inn_bk ~ '^INN-\d{4}$'),
    inn_name      text NOT NULL UNIQUE,
    source_system text NOT NULL DEFAULT 'CAT',
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);

CREATE TABLE catalog.sku (
    sku_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku_bk           text NOT NULL UNIQUE CHECK (sku_bk ~ '^SKU-\d{6}$'),
    sku_name         text NOT NULL CHECK (btrim(sku_name) <> ''),
    manufacturer_id  bigint NOT NULL REFERENCES catalog.manufacturer,
    drug_form_id     bigint REFERENCES catalog.drug_form,
    category         text NOT NULL
                     CHECK (category IN ('rx','otc','supplement','device','cosmetics')),
    is_vital         boolean NOT NULL DEFAULT false,        -- ЖНВЛП
    vital_max_price  numeric(12,2) CHECK (vital_max_price > 0),
    pack_qty         numeric(10,2) NOT NULL CHECK (pack_qty > 0),
    source_system    text NOT NULL DEFAULT 'CAT',
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    -- предельная цена бывает только у ЖНВЛП
    CONSTRAINT sku_vital_cap_chk CHECK (vital_max_price IS NULL OR is_vital)
);
-- is_rx НЕ хранится: выводится из category (ADR-0009)

CREATE TABLE catalog.sku_inn (                   -- M:N, комбинированные препараты
    sku_id     bigint NOT NULL REFERENCES catalog.sku,
    inn_id     bigint NOT NULL REFERENCES catalog.inn,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (sku_id, inn_id)
);

CREATE TABLE catalog.sku_history (               -- журнал изменений (ADR-0006)
    history_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku_id      bigint NOT NULL REFERENCES catalog.sku,
    attr_name   text NOT NULL,
    old_value   text,
    new_value   text,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE catalog.price (                     -- SCD2 (ADR-0003)
    price_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku_id       bigint NOT NULL REFERENCES catalog.sku,
    price_scope  text NOT NULL CHECK (price_scope IN ('chain','region','pharmacy')),
    scope_bk     text NOT NULL,
    -- для региональной цены - честный FK на локальный справочник регионов
    region_code  text GENERATED ALWAYS AS
                 (CASE WHEN price_scope = 'region' THEN scope_bk END) STORED
                 REFERENCES ref.region,
    price        numeric(12,2) NOT NULL CHECK (price > 0),
    currency     char(3) NOT NULL DEFAULT 'RUB' CHECK (currency ~ '^[A-Z]{3}$'),
    valid_from   timestamptz NOT NULL,
    valid_to     timestamptz,
    is_current   boolean GENERATED ALWAYS AS (valid_to IS NULL) STORED,
    source_system text NOT NULL DEFAULT 'CAT',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT price_interval_chk CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT price_scope_bk_chk CHECK (
           (price_scope = 'chain'    AND scope_bk = 'ALL')
        OR (price_scope = 'region'   AND scope_bk ~ '^RU-[A-Z]{2,3}$')
        OR (price_scope = 'pharmacy' AND scope_bk ~ '^PH-\d{4}$')),
    -- I5: интервалы одной (sku, область) не пересекаются
    CONSTRAINT price_no_overlap EXCLUDE USING gist (
        sku_id WITH =, price_scope WITH =, scope_bk WITH =,
        tstzrange(valid_from, valid_to, '[)') WITH &&)
);

-- ----------------------------------------------------------------------------
-- триггеры
-- ----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['manufacturer','drug_form','inn','sku','sku_inn',
                             'sku_history','price']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON catalog.%I
                        FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at()', t, t);
    END LOOP;
END $$;

CREATE TRIGGER trg_sku_bk_immutable BEFORE UPDATE ON catalog.sku
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('sku_bk');
CREATE TRIGGER trg_manufacturer_bk_immutable BEFORE UPDATE ON catalog.manufacturer
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('manufacturer_bk');
CREATE TRIGGER trg_inn_bk_immutable BEFORE UPDATE ON catalog.inn
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('inn_bk');

-- журнал изменений атрибутов SKU (ADR-0006)
CREATE FUNCTION catalog.log_sku_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.sku_name IS DISTINCT FROM OLD.sku_name THEN
        INSERT INTO catalog.sku_history (sku_id, attr_name, old_value, new_value, changed_at)
        VALUES (NEW.sku_id, 'sku_name', OLD.sku_name, NEW.sku_name, NEW.updated_at);
    END IF;
    IF NEW.category IS DISTINCT FROM OLD.category THEN
        INSERT INTO catalog.sku_history (sku_id, attr_name, old_value, new_value, changed_at)
        VALUES (NEW.sku_id, 'category', OLD.category, NEW.category, NEW.updated_at);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_sku_history AFTER UPDATE ON catalog.sku
    FOR EACH ROW EXECUTE FUNCTION catalog.log_sku_change();

-- ЖНВЛП: цена не выше предельной
CREATE FUNCTION catalog.check_vital_cap() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE cap numeric;
BEGIN
    SELECT vital_max_price INTO cap FROM catalog.sku WHERE sku_id = NEW.sku_id;
    IF cap IS NOT NULL AND NEW.price > cap THEN
        RAISE EXCEPTION 'price % exceeds vital max price % for sku_id %',
              NEW.price, cap, NEW.sku_id USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_price_vital_cap BEFORE INSERT OR UPDATE OF price, sku_id ON catalog.price
    FOR EACH ROW EXECUTE FUNCTION catalog.check_vital_cap();
