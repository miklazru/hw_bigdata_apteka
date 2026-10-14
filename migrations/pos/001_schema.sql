-- =============================================================================
-- pos_service_db: аптеки, кассы, смены, чеки, оплаты
-- =============================================================================
CREATE SCHEMA pos;

CREATE TABLE pos.pharmacy (
    pharmacy_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pharmacy_bk    text NOT NULL UNIQUE CHECK (pharmacy_bk ~ '^PH-\d{4}$'),
    pharmacy_name  text NOT NULL,
    region_code    text NOT NULL REFERENCES ref.region,
    city           text NOT NULL,
    address        text NOT NULL,
    timezone       text NOT NULL DEFAULT 'Europe/Moscow',
    opened_at      date NOT NULL,
    closed_at      date,
    source_system  text NOT NULL DEFAULT 'POS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,
    CONSTRAINT pharmacy_dates_chk CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

CREATE TABLE pos.cashier (
    cashier_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cashier_bk     text NOT NULL UNIQUE CHECK (cashier_bk ~ '^CSH-\d{5}$'),
    pharmacy_id    bigint NOT NULL REFERENCES pos.pharmacy,
    source_system  text NOT NULL DEFAULT 'POS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz
);

CREATE TABLE pos.register (                       -- касса
    register_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    register_bk    text NOT NULL UNIQUE CHECK (register_bk ~ '^REG-\d{4}-\d{2}$'),
    pharmacy_id    bigint NOT NULL REFERENCES pos.pharmacy,
    source_system  text NOT NULL DEFAULT 'POS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz
);

CREATE TABLE pos.shift (                          -- смена: одна касса, один кассир
    shift_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shift_bk       text NOT NULL UNIQUE CHECK (shift_bk ~ '^SHF-\d{4}-\d{2}-\d{8}$'),
    register_id    bigint NOT NULL REFERENCES pos.register,
    cashier_id     bigint NOT NULL REFERENCES pos.cashier,
    opened_at      timestamptz NOT NULL,
    closed_at      timestamptz,
    source_system  text NOT NULL DEFAULT 'POS',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT shift_time_chk CHECK (closed_at IS NULL OR closed_at > opened_at),
    -- смены одной кассы не пересекаются
    CONSTRAINT shift_no_overlap EXCLUDE USING gist (
        register_id WITH =, tstzrange(opened_at, closed_at, '[)') WITH &&)
);

CREATE TABLE pos.prescription (                   -- рецепт
    prescription_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prescription_bk  text NOT NULL UNIQUE CHECK (prescription_bk ~ '^RX-\d{8}-\d{6}$'),
    issued_at        date NOT NULL,
    valid_until      date NOT NULL,
    source_system    text NOT NULL DEFAULT 'POS',
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT prescription_dates_chk CHECK (valid_until >= issued_at)
);

CREATE TABLE pos.receipt (                        -- кассовый документ
    receipt_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_bk         text NOT NULL UNIQUE CHECK (receipt_bk ~ '^RCPT-\d{8}-\d{6}$'),
    shift_id           bigint NOT NULL REFERENCES pos.shift,
    customer_bk        text CHECK (customer_bk ~ '^CUST-\d{7}$'),   -- -> crm по BK; NULL = без карты
    receipt_dt         timestamptz NOT NULL,
    doc_type           text NOT NULL CHECK (doc_type IN ('sale','refund')),
    parent_receipt_id  bigint REFERENCES pos.receipt,
    total_amount       numeric(14,2) NOT NULL CHECK (total_amount >= 0),
    discount_amount    numeric(14,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    currency           char(3) NOT NULL DEFAULT 'RUB' CHECK (currency ~ '^[A-Z]{3}$'),
    source_system      text NOT NULL DEFAULT 'POS',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT receipt_parent_chk                                     -- C05
        CHECK ((doc_type = 'refund') = (parent_receipt_id IS NOT NULL))
);

CREATE TABLE pos.receipt_line (
    receipt_id            bigint NOT NULL REFERENCES pos.receipt,
    line_no               int NOT NULL CHECK (line_no > 0),
    sku_bk                text NOT NULL CHECK (sku_bk ~ '^SKU-\d{6}$'),            -- -> catalog
    batch_bk              text NOT NULL CHECK (batch_bk ~ '^BATCH-\d{4}-\d{5}$'),  -- -> wms
    quantity              numeric(12,3) NOT NULL,
    unit_price            numeric(12,2) NOT NULL,     -- snapshot цены на момент продажи
    line_discount         numeric(12,2) NOT NULL DEFAULT 0,
    line_amount           numeric(14,2) NOT NULL,     -- обычная колонка + CHECK (I4), не generated
    sku_name_snapshot     text NOT NULL,
    is_rx_snapshot        boolean NOT NULL,
    expiry_date_snapshot  date NOT NULL,              -- для I8: срок годности живёт в WMS
    prescription_id       bigint REFERENCES pos.prescription,
    source_system         text NOT NULL DEFAULT 'POS',
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (receipt_id, line_no),
    -- I4: арифметика и знаки
    CONSTRAINT line_qty_positive     CHECK (quantity > 0),
    CONSTRAINT line_price_nonneg     CHECK (unit_price >= 0),
    CONSTRAINT line_discount_range   CHECK (line_discount >= 0 AND line_discount <= quantity * unit_price),
    CONSTRAINT line_amount_math      CHECK (line_amount = round(quantity * unit_price - line_discount, 2)),
    -- I10: рецептурная позиция только по рецепту (ADR-0005)
    CONSTRAINT line_rx_requires_prescription
        CHECK (NOT is_rx_snapshot OR prescription_id IS NOT NULL)
);

CREATE TABLE pos.payment (
    receipt_id      bigint NOT NULL REFERENCES pos.receipt,
    payment_no      int NOT NULL CHECK (payment_no > 0),
    payment_method  text NOT NULL CHECK (payment_method IN ('cash','card','bonus','certificate')),
    amount          numeric(14,2) NOT NULL CHECK (amount > 0),
    currency        char(3) NOT NULL DEFAULT 'RUB' CHECK (currency ~ '^[A-Z]{3}$'),
    source_system   text NOT NULL DEFAULT 'POS',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (receipt_id, payment_no)
);

CREATE INDEX ON pos.receipt (shift_id);
CREATE INDEX ON pos.receipt (parent_receipt_id);
CREATE INDEX ON pos.receipt (receipt_dt);
CREATE INDEX ON pos.receipt (customer_bk);

-- ----------------------------------------------------------------------------
-- updated_at и неизменяемость BK
-- ----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['pharmacy','cashier','register','shift','prescription',
                             'receipt','receipt_line','payment']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON pos.%I
                        FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at()', t, t);
    END LOOP;
END $$;
CREATE TRIGGER trg_pharmacy_bk BEFORE UPDATE ON pos.pharmacy
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('pharmacy_bk');
CREATE TRIGGER trg_cashier_bk BEFORE UPDATE ON pos.cashier
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('cashier_bk');
CREATE TRIGGER trg_register_bk BEFORE UPDATE ON pos.register
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('register_bk');
CREATE TRIGGER trg_shift_bk BEFORE UPDATE ON pos.shift
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('shift_bk');
CREATE TRIGGER trg_prescription_bk BEFORE UPDATE ON pos.prescription
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('prescription_bk');
CREATE TRIGGER trg_receipt_bk BEFORE UPDATE ON pos.receipt
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('receipt_bk');

-- ----------------------------------------------------------------------------
-- Документ оформляется на открытой смене (время чека внутри смены)
-- ----------------------------------------------------------------------------
CREATE FUNCTION pos.check_receipt_in_shift() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s pos.shift;
BEGIN
    SELECT * INTO s FROM pos.shift WHERE shift_id = NEW.shift_id;
    IF NEW.receipt_dt < s.opened_at
       OR (s.closed_at IS NOT NULL AND NEW.receipt_dt >= s.closed_at) THEN
        RAISE EXCEPTION 'receipt % at % is outside shift % [%, %)',
              NEW.receipt_bk, NEW.receipt_dt, s.shift_bk, s.opened_at, s.closed_at
              USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_in_shift BEFORE INSERT OR UPDATE OF shift_id, receipt_dt
    ON pos.receipt FOR EACH ROW EXECUTE FUNCTION pos.check_receipt_in_shift();

-- ----------------------------------------------------------------------------
-- I3: сумма документа = сумма позиций; скидка = сумма скидок позиций.
-- Проверка в конце транзакции: при вставке шапки позиций ещё нет.
-- ----------------------------------------------------------------------------
CREATE FUNCTION pos.check_receipt_total() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    rid       bigint := CASE WHEN TG_OP = 'DELETE' THEN OLD.receipt_id ELSE NEW.receipt_id END;
    r         pos.receipt;
    s_amount  numeric;
    s_disc    numeric;
BEGIN
    SELECT * INTO r FROM pos.receipt WHERE receipt_id = rid;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT coalesce(sum(line_amount), 0), coalesce(sum(line_discount), 0)
      INTO s_amount, s_disc
      FROM pos.receipt_line WHERE receipt_id = rid;
    IF s_amount <> r.total_amount OR s_disc <> r.discount_amount THEN
        RAISE EXCEPTION 'receipt %: total % / discount % do not match lines % / %',
              r.receipt_bk, r.total_amount, r.discount_amount, s_amount, s_disc
              USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_receipt_total_hdr
    AFTER INSERT OR UPDATE OF total_amount, discount_amount ON pos.receipt
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pos.check_receipt_total();
CREATE CONSTRAINT TRIGGER trg_receipt_total_lines
    AFTER INSERT OR UPDATE OR DELETE ON pos.receipt_line
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pos.check_receipt_total();

-- ----------------------------------------------------------------------------
-- I12: сумма оплат = сумма документа. Тоже в конце транзакции.
-- ----------------------------------------------------------------------------
CREATE FUNCTION pos.check_payment_total() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    rid    bigint := CASE WHEN TG_OP = 'DELETE' THEN OLD.receipt_id ELSE NEW.receipt_id END;
    r      pos.receipt;
    s_paid numeric;
BEGIN
    SELECT * INTO r FROM pos.receipt WHERE receipt_id = rid;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT coalesce(sum(amount), 0) INTO s_paid FROM pos.payment WHERE receipt_id = rid;
    IF s_paid <> r.total_amount THEN
        RAISE EXCEPTION 'receipt %: payments % do not match total %',
              r.receipt_bk, s_paid, r.total_amount USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_payment_total_hdr
    AFTER INSERT OR UPDATE OF total_amount ON pos.receipt
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pos.check_payment_total();
CREATE CONSTRAINT TRIGGER trg_payment_total_pay
    AFTER INSERT OR UPDATE OR DELETE ON pos.payment
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pos.check_payment_total();

-- ----------------------------------------------------------------------------
-- I8 (продажа просрочки) и I11 (возврат не больше проданного) - на позиции
-- ----------------------------------------------------------------------------
CREATE FUNCTION pos.check_receipt_line() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r          pos.receipt;
    tz         text;
    parent     pos.receipt;
    sold       numeric;
    refunded   numeric;
BEGIN
    SELECT * INTO r FROM pos.receipt WHERE receipt_id = NEW.receipt_id;

    IF r.doc_type = 'sale' THEN
        -- I8: дата продажи по местному времени аптеки не позже срока годности
        SELECT p.timezone INTO tz
          FROM pos.shift s JOIN pos.register g USING (register_id)
          JOIN pos.pharmacy p USING (pharmacy_id)
         WHERE s.shift_id = r.shift_id;
        IF (r.receipt_dt AT TIME ZONE tz)::date > NEW.expiry_date_snapshot THEN
            RAISE EXCEPTION 'receipt %: batch % expired on %, sold on %',
                  r.receipt_bk, NEW.batch_bk, NEW.expiry_date_snapshot,
                  (r.receipt_dt AT TIME ZONE tz)::date USING ERRCODE = 'P0001';
        END IF;
    ELSE
        -- I11: вернуть не больше, чем продано, с учётом прошлых возвратов
        SELECT * INTO parent FROM pos.receipt
         WHERE receipt_id = r.parent_receipt_id FOR UPDATE;   -- сериализуем возвраты
        IF parent.doc_type <> 'sale' THEN
            RAISE EXCEPTION 'refund % must reference a sale, got %',
                  r.receipt_bk, parent.receipt_bk USING ERRCODE = 'P0001';
        END IF;
        SELECT coalesce(sum(quantity), 0) INTO sold
          FROM pos.receipt_line
         WHERE receipt_id = parent.receipt_id AND sku_bk = NEW.sku_bk;
        SELECT coalesce(sum(l.quantity), 0) INTO refunded
          FROM pos.receipt_line l JOIN pos.receipt rr USING (receipt_id)
         WHERE rr.parent_receipt_id = parent.receipt_id
           AND rr.doc_type = 'refund'
           AND l.sku_bk = NEW.sku_bk
           AND NOT (l.receipt_id = NEW.receipt_id AND l.line_no = NEW.line_no);
        IF refunded + NEW.quantity > sold THEN
            RAISE EXCEPTION 'refund %: % x % exceeds sold % (already refunded %) in %',
                  r.receipt_bk, NEW.quantity, NEW.sku_bk, sold, refunded, parent.receipt_bk
                  USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_receipt_line_check
    BEFORE INSERT OR UPDATE OF quantity, sku_bk, expiry_date_snapshot, receipt_id
    ON pos.receipt_line FOR EACH ROW EXECUTE FUNCTION pos.check_receipt_line();
