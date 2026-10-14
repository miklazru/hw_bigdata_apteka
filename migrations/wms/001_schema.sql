-- =============================================================================
-- wms_service_db: склад, поставки, движение товара
-- =============================================================================
CREATE SCHEMA wms;

CREATE TABLE wms.supplier (
    supplier_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_bk    text NOT NULL UNIQUE CHECK (supplier_bk ~ '^SUP-\d{4}$'),
    supplier_name  text NOT NULL,
    country_code   char(2) NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    source_system  text NOT NULL DEFAULT 'WMS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz
);

CREATE TABLE wms.distribution_center (
    dc_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dc_bk          text NOT NULL UNIQUE CHECK (dc_bk ~ '^DC-\d{2}$'),
    dc_name        text NOT NULL,
    region_code    text NOT NULL REFERENCES ref.region,
    city           text NOT NULL,
    timezone       text NOT NULL DEFAULT 'Europe/Moscow',
    source_system  text NOT NULL DEFAULT 'WMS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz
);

-- Единая таблица локаций (полиморфная ссылка). Аптеки - справочная копия
-- из POS по BK, без FK между базами.
CREATE TABLE wms.location (
    location_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_type  text NOT NULL CHECK (location_type IN ('dc','pharmacy')),
    location_bk    text NOT NULL,
    dc_id          bigint UNIQUE REFERENCES wms.distribution_center,
    source_system  text NOT NULL DEFAULT 'WMS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,
    UNIQUE (location_type, location_bk),
    UNIQUE (location_id, location_type),          -- цель составных FK из movement
    CONSTRAINT location_kind_chk CHECK (
           (location_type = 'dc'       AND dc_id IS NOT NULL AND location_bk ~ '^DC-\d{2}$')
        OR (location_type = 'pharmacy' AND dc_id IS NULL     AND location_bk ~ '^PH-\d{4}$'))
);

CREATE TABLE wms.batch (                          -- партия (серия)
    batch_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_bk           text NOT NULL UNIQUE CHECK (batch_bk ~ '^BATCH-\d{4}-\d{5}$'),
    sku_bk             text NOT NULL CHECK (sku_bk ~ '^SKU-\d{6}$'),   -- -> catalog, по BK
    series_no          text NOT NULL,
    manufactured_date  date NOT NULL,
    expiry_date        date NOT NULL,
    received_at        timestamptz NOT NULL,
    source_system      text NOT NULL DEFAULT 'WMS',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT batch_series_uk UNIQUE (sku_bk, series_no),             -- C14
    CONSTRAINT batch_dates_chk CHECK (expiry_date > manufactured_date) -- C13
);

CREATE TABLE wms.purchase (                       -- заказ поставщику (шапка)
    purchase_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_bk    text NOT NULL UNIQUE CHECK (purchase_bk ~ '^PO-\d{8}-\d{4}$'),
    supplier_id    bigint NOT NULL REFERENCES wms.supplier,
    dc_id          bigint NOT NULL REFERENCES wms.distribution_center,
    ordered_at     timestamptz NOT NULL,
    currency       char(3) NOT NULL DEFAULT 'RUB' CHECK (currency ~ '^[A-Z]{3}$'),
    source_system  text NOT NULL DEFAULT 'WMS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE wms.purchase_line (
    purchase_line_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_id       bigint NOT NULL REFERENCES wms.purchase,
    line_no           int NOT NULL CHECK (line_no > 0),
    sku_bk            text NOT NULL CHECK (sku_bk ~ '^SKU-\d{6}$'),
    quantity          numeric(12,3) NOT NULL CHECK (quantity > 0),
    unit_cost         numeric(12,2) NOT NULL CHECK (unit_cost >= 0),
    line_cost         numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_cost, 2)) STORED,
    batch_id          bigint REFERENCES wms.batch,
    received_at       timestamptz,
    source_system     text NOT NULL DEFAULT 'WMS',
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (purchase_id, line_no),
    CONSTRAINT purchase_line_received_chk                                -- C19
        CHECK ((received_at IS NULL) = (batch_id IS NULL))
);

CREATE TABLE wms.movement (                       -- журнал движений (append-only)
    movement_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    movement_bk      text NOT NULL UNIQUE CHECK (movement_bk ~ '^MOV-\d{8}-\d{6}$'),
    movement_type    text NOT NULL
                     CHECK (movement_type IN ('receipt','transfer','sale_writeoff','return','writeoff')),
    batch_id         bigint NOT NULL REFERENCES wms.batch,
    src_type         text CHECK (src_type IN ('dc','pharmacy','supplier')),
    src_location_id  bigint,
    supplier_id      bigint REFERENCES wms.supplier,     -- контрагент: источник receipt / получатель return
    dst_type         text CHECK (dst_type IN ('dc','pharmacy','customer')),
    dst_location_id  bigint,
    qty              numeric(12,3) NOT NULL CHECK (qty > 0),
    dispatched_at    timestamptz,
    moved_at         timestamptz NOT NULL,
    writeoff_reason  text CHECK (writeoff_reason IN ('defect','expired','damaged')),
    source_system    text NOT NULL DEFAULT 'WMS',
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    -- тип локации обязан совпадать с заявленным src_type / dst_type
    -- (MATCH SIMPLE: при NULL в location_id проверка не выполняется)
    FOREIGN KEY (src_location_id, src_type) REFERENCES wms.location (location_id, location_type),
    FOREIGN KEY (dst_location_id, dst_type) REFERENCES wms.location (location_id, location_type),
    CONSTRAINT movement_time_chk CHECK (dispatched_at IS NULL OR dispatched_at <= moved_at),   -- C17
    CONSTRAINT movement_not_self_chk CHECK (src_location_id IS DISTINCT FROM dst_location_id), -- C16
    -- допустимые формы движения по типу
    CONSTRAINT movement_shape_chk CHECK (
        CASE movement_type
        WHEN 'receipt' THEN        -- поставщик -> РЦ
            src_type = 'supplier' AND supplier_id IS NOT NULL AND src_location_id IS NULL
            AND dst_type = 'dc' AND dst_location_id IS NOT NULL
        WHEN 'transfer' THEN       -- РЦ/аптека -> РЦ/аптека
            src_type IN ('dc','pharmacy') AND src_location_id IS NOT NULL
            AND dst_type IN ('dc','pharmacy') AND dst_location_id IS NOT NULL
            AND supplier_id IS NULL
        WHEN 'sale_writeoff' THEN  -- аптека -> покупатель, дневной агрегат (ADR-0007)
            src_type = 'pharmacy' AND src_location_id IS NOT NULL
            AND dst_type = 'customer' AND dst_location_id IS NULL AND supplier_id IS NULL
        WHEN 'return' THEN         -- возврат поставщику: уходит из сети
            src_type IN ('dc','pharmacy') AND src_location_id IS NOT NULL
            AND dst_type IS NULL AND dst_location_id IS NULL AND supplier_id IS NOT NULL
        WHEN 'writeoff' THEN       -- списание брака / просрочки
            src_type IN ('dc','pharmacy') AND src_location_id IS NOT NULL
            AND dst_type IS NULL AND dst_location_id IS NULL AND writeoff_reason IS NOT NULL
        END)
);

CREATE TABLE wms.stock (                          -- материализованный остаток (ADR-0004)
    location_id  bigint NOT NULL REFERENCES wms.location,
    batch_id     bigint NOT NULL REFERENCES wms.batch,
    qty_on_hand  numeric(12,3) NOT NULL CONSTRAINT stock_non_negative CHECK (qty_on_hand >= 0), -- I7
    source_system text NOT NULL DEFAULT 'WMS',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (location_id, batch_id)
);

CREATE INDEX ON wms.movement (batch_id);
CREATE INDEX ON wms.movement (moved_at);
CREATE INDEX ON wms.purchase_line (batch_id);

-- ----------------------------------------------------------------------------
-- триггеры
-- ----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['supplier','distribution_center','location','batch',
                             'purchase','purchase_line','movement','stock']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON wms.%I
                        FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at()', t, t);
    END LOOP;
END $$;

CREATE TRIGGER trg_supplier_bk BEFORE UPDATE ON wms.supplier
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('supplier_bk');
CREATE TRIGGER trg_dc_bk BEFORE UPDATE ON wms.distribution_center
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('dc_bk');
CREATE TRIGGER trg_location_bk BEFORE UPDATE ON wms.location
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('location_bk');
CREATE TRIGGER trg_batch_bk BEFORE UPDATE ON wms.batch
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('batch_bk');
CREATE TRIGGER trg_purchase_bk BEFORE UPDATE ON wms.purchase
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('purchase_bk');
CREATE TRIGGER trg_movement_bk BEFORE UPDATE ON wms.movement
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('movement_bk');

-- I9: партия с истёкшим сроком не принимается на склад
CREATE FUNCTION wms.check_batch_not_expired() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.received_at AT TIME ZONE 'Europe/Moscow')::date > NEW.expiry_date THEN
        RAISE EXCEPTION 'batch % is expired (expiry %, received %)',
              NEW.batch_bk, NEW.expiry_date, NEW.received_at USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_batch_not_expired
    BEFORE INSERT OR UPDATE OF received_at, expiry_date ON wms.batch
    FOR EACH ROW EXECUTE FUNCTION wms.check_batch_not_expired();

-- журнал движений append-only: количественные поля не правятся задним числом
CREATE FUNCTION wms.forbid_movement_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'movement % is append-only; post a reversing movement instead',
          OLD.movement_bk USING ERRCODE = 'P0001';
END $$;
CREATE TRIGGER trg_movement_append_only
    BEFORE UPDATE OF batch_id, qty, src_location_id, dst_location_id, movement_type
    ON wms.movement FOR EACH ROW EXECUTE FUNCTION wms.forbid_movement_change();

-- Остаток пересчитывается движением (ADR-0004).
-- Источник: UPDATE существующего остатка; если списываем больше, чем есть,
-- qty_on_hand уходит в минус и срабатывает CHECK stock_non_negative -> 23514 (I7).
-- Если остатка в локации нет вовсе - INSERT отрицательной строки, тот же CHECK.
-- (INSERT ... ON CONFLICT для источника не годится: CHECK проверяется на
--  вставляемой строке ДО обнаружения конфликта, и списание падало бы всегда.)
CREATE FUNCTION wms.apply_movement_to_stock() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.src_location_id IS NOT NULL THEN
        UPDATE wms.stock
           SET qty_on_hand = qty_on_hand - NEW.qty,
               updated_at  = GREATEST(updated_at, NEW.moved_at)
         WHERE location_id = NEW.src_location_id AND batch_id = NEW.batch_id;
        IF NOT FOUND THEN
            INSERT INTO wms.stock (location_id, batch_id, qty_on_hand, updated_at)
            VALUES (NEW.src_location_id, NEW.batch_id, -NEW.qty, NEW.moved_at);
        END IF;
    END IF;
    IF NEW.dst_location_id IS NOT NULL THEN
        INSERT INTO wms.stock AS s (location_id, batch_id, qty_on_hand, updated_at)
        VALUES (NEW.dst_location_id, NEW.batch_id, NEW.qty, NEW.moved_at)
        ON CONFLICT (location_id, batch_id) DO UPDATE
           SET qty_on_hand = s.qty_on_hand + NEW.qty,
               updated_at  = GREATEST(s.updated_at, NEW.moved_at);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_movement_stock AFTER INSERT ON wms.movement
    FOR EACH ROW EXECUTE FUNCTION wms.apply_movement_to_stock();
