#!/usr/bin/env bash
# =============================================================================
# Создаёт роли и четыре базы, применяет миграции:
#   migrations/_common/0*.sql  ->  migrations/<service>/*.sql  ->  migrations/_common/9*.sql
# Запускается автоматически из /docker-entrypoint-initdb.d при ПЕРВОМ старте
# (пустой PGDATA). Можно запустить и вручную против пустого кластера:
#   MIGRATIONS_DIR=./migrations PGHOST=localhost PGUSER=postgres ./scripts/apply_migrations.sh
# =============================================================================
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/migrations}"
SERVICES=(crm catalog pos wms)
PSQL=(psql -v ON_ERROR_STOP=1 -X -q --username "${POSTGRES_USER:-${PGUSER:-postgres}}")

echo ">>> roles"
"${PSQL[@]}" -d postgres <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
        CREATE ROLE app LOGIN PASSWORD 'app';                -- приложение / генератор / тесты
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'checker') THEN
        CREATE ROLE checker LOGIN PASSWORD 'checker';        -- только чтение contract
    END IF;
    -- чтение pg_stat_wal_receiver / pg_stat_replication для мониторинга реплики
    GRANT pg_read_all_stats TO checker;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator';
    END IF;
END $$;
SQL

for svc in "${SERVICES[@]}"; do
    db="${svc}_service_db"
    echo ">>> database ${db}"
    "${PSQL[@]}" -d postgres -c "CREATE DATABASE ${db}"
    "${PSQL[@]}" -d postgres -c "REVOKE ALL ON DATABASE ${db} FROM PUBLIC;
                                 GRANT CONNECT ON DATABASE ${db} TO app, checker;"
    for f in "${MIGRATIONS_DIR}"/_common/0*.sql \
             "${MIGRATIONS_DIR}/${svc}"/*.sql \
             "${MIGRATIONS_DIR}"/_common/9*.sql; do
        echo "    ${f#${MIGRATIONS_DIR}/}"
        "${PSQL[@]}" -d "${db}" -f "${f}"
    done
done
echo ">>> migrations applied"
