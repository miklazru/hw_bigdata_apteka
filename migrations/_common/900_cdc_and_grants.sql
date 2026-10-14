-- =============================================================================
-- Применяется к КАЖДОЙ базе последним, после миграций сервиса.
-- CDC-готовность + права ролей.
-- =============================================================================

-- CDC: одна publication на все таблицы базы, включая будущие.
-- REPLICA IDENTITY DEFAULT достаточно: у каждой таблицы есть PRIMARY KEY.
CREATE PUBLICATION dwh_cdc FOR ALL TABLES;

-- app: приложение / генератор / негативные тесты - чтение и запись в таблицы
DO $$
DECLARE s text;
BEGIN
    FOR s IN SELECT nspname FROM pg_namespace
              WHERE nspname NOT LIKE 'pg\_%' AND nspname NOT IN ('information_schema','public')
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO app', s);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA %I TO app', s);
        EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO app', s);
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO app', s);
    END LOOP;
END $$;
-- DELETE намеренно не выдан: в справочниках soft delete (ADR-0010).

-- checker: только чтение контракта. К базовым таблицам (в т.ч. PII) доступа нет;
-- представления выполняются с правами владельца.
GRANT USAGE ON SCHEMA contract TO checker;
GRANT SELECT ON ALL TABLES IN SCHEMA contract TO checker;
