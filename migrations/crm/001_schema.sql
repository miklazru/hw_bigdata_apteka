-- =============================================================================
-- crm_service_db: клиенты, контакты, согласия, карты лояльности
-- =============================================================================
CREATE SCHEMA crm;

CREATE TABLE crm.loyalty_level (
    level_code     text PRIMARY KEY CHECK (level_code ~ '^[a-z]+$'),
    level_name     text NOT NULL,
    sort_order     int NOT NULL UNIQUE,
    source_system  text NOT NULL DEFAULT 'CRM',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
INSERT INTO crm.loyalty_level (level_code, level_name, sort_order) VALUES
    ('basic','Базовый',1), ('silver','Серебряный',2), ('gold','Золотой',3), ('platinum','Платиновый',4);

CREATE TABLE crm.customer (
    customer_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_bk    text NOT NULL UNIQUE CHECK (customer_bk ~ '^CUST-\d{7}$'),
    birth_date     date CHECK (birth_date >= DATE '1900-01-01'),
    sex            char(1) CHECK (sex IN ('M','F')),
    city           text,
    region_code    text REFERENCES ref.region,
    loyalty_level  text REFERENCES crm.loyalty_level,
    registered_at  timestamptz NOT NULL,
    source_system  text NOT NULL DEFAULT 'CRM',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,                       -- запрос на забывание (ADR-0008)
    CONSTRAINT customer_birth_chk CHECK (birth_date IS NULL OR birth_date < registered_at::date)
);

-- персональные данные отдельно: одно место для обезличивания и прав доступа
CREATE TABLE crm.customer_pii (
    customer_id    bigint PRIMARY KEY REFERENCES crm.customer,
    full_name      text,
    phone          text CHECK (phone ~ '^\+7\d{10}$'),
    email          text CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    anonymized_at  timestamptz,
    source_system  text NOT NULL DEFAULT 'CRM',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pii_anonymized_chk CHECK (
        anonymized_at IS NULL OR (full_name IS NULL AND phone IS NULL AND email IS NULL))
);

CREATE TABLE crm.customer_history (               -- журнал изменений (ADR-0006)
    history_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint NOT NULL REFERENCES crm.customer,
    attr_name    text NOT NULL,
    old_value    text,
    new_value    text,
    changed_at   timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE crm.loyalty_card (
    card_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    card_bk        text NOT NULL UNIQUE CHECK (card_bk ~ '^CARD-\d{7}$'),
    customer_id    bigint NOT NULL REFERENCES crm.customer,
    issued_at      timestamptz NOT NULL,
    closed_at      timestamptz,
    status         text NOT NULL CHECK (status IN ('active','blocked','closed')),
    bonus_balance  numeric(12,2) NOT NULL DEFAULT 0 CHECK (bonus_balance >= 0),   -- C23
    source_system  text NOT NULL DEFAULT 'CRM',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT card_closed_chk CHECK (closed_at IS NULL OR status <> 'active'),    -- C23
    CONSTRAINT card_dates_chk CHECK (closed_at IS NULL OR closed_at >= issued_at)
);
-- у клиента не больше одной активной карты (C22)
CREATE UNIQUE INDEX loyalty_card_one_active ON crm.loyalty_card (customer_id)
    WHERE status = 'active';

CREATE TABLE crm.consent (                        -- версионируемые согласия
    consent_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id    bigint NOT NULL REFERENCES crm.customer,
    consent_type   text NOT NULL CHECK (consent_type IN ('pd_processing','marketing','sms')),
    granted_at     timestamptz NOT NULL,
    revoked_at     timestamptz,
    source_system  text NOT NULL DEFAULT 'CRM',
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT consent_dates_chk CHECK (revoked_at IS NULL OR revoked_at > granted_at)
);
-- I6: активное согласие данного типа - только одно
CREATE UNIQUE INDEX consent_one_active ON crm.consent (customer_id, consent_type)
    WHERE revoked_at IS NULL;
CREATE INDEX ON crm.consent (customer_id);
CREATE INDEX ON crm.loyalty_card (customer_id);

-- ----------------------------------------------------------------------------
-- триггеры
-- ----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['loyalty_level','customer','customer_pii','customer_history',
                             'loyalty_card','consent']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON crm.%I
                        FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at()', t, t);
    END LOOP;
END $$;
CREATE TRIGGER trg_customer_bk BEFORE UPDATE ON crm.customer
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('customer_bk');
CREATE TRIGGER trg_card_bk BEFORE UPDATE ON crm.loyalty_card
    FOR EACH ROW EXECUTE FUNCTION ref.forbid_bk_change('card_bk');

-- журнал изменений уровня и географии клиента (ADR-0006)
CREATE FUNCTION crm.log_customer_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.loyalty_level IS DISTINCT FROM OLD.loyalty_level THEN
        INSERT INTO crm.customer_history (customer_id, attr_name, old_value, new_value, changed_at)
        VALUES (NEW.customer_id, 'loyalty_level', OLD.loyalty_level, NEW.loyalty_level, NEW.updated_at);
    END IF;
    IF NEW.city IS DISTINCT FROM OLD.city THEN
        INSERT INTO crm.customer_history (customer_id, attr_name, old_value, new_value, changed_at)
        VALUES (NEW.customer_id, 'city', OLD.city, NEW.city, NEW.updated_at);
    END IF;
    IF NEW.region_code IS DISTINCT FROM OLD.region_code THEN
        INSERT INTO crm.customer_history (customer_id, attr_name, old_value, new_value, changed_at)
        VALUES (NEW.customer_id, 'region_code', OLD.region_code, NEW.region_code, NEW.updated_at);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_customer_history AFTER UPDATE ON crm.customer
    FOR EACH ROW EXECUTE FUNCTION crm.log_customer_change();

-- забывание клиента: при установке deleted_at PII обезличиваются автоматически,
-- активные согласия отзываются, карты закрываются (ADR-0008)
CREATE FUNCTION crm.forget_customer() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE crm.customer_pii
       SET full_name = NULL, phone = NULL, email = NULL, anonymized_at = NEW.deleted_at
     WHERE customer_id = NEW.customer_id;
    UPDATE crm.consent SET revoked_at = NEW.deleted_at
     WHERE customer_id = NEW.customer_id AND revoked_at IS NULL AND granted_at < NEW.deleted_at;
    UPDATE crm.loyalty_card SET status = 'closed', closed_at = NEW.deleted_at
     WHERE customer_id = NEW.customer_id AND closed_at IS NULL;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_customer_forget AFTER UPDATE OF deleted_at ON crm.customer
    FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION crm.forget_customer();

-- восстановить забытого клиента нельзя
CREATE FUNCTION crm.forbid_unforget() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'customer % was forgotten and cannot be restored', OLD.customer_bk
          USING ERRCODE = 'P0001';
END $$;
CREATE TRIGGER trg_customer_unforget BEFORE UPDATE OF deleted_at ON crm.customer
    FOR EACH ROW WHEN (OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS DISTINCT FROM OLD.deleted_at)
    EXECUTE FUNCTION crm.forbid_unforget();
