#!/usr/bin/env bash
# Patroni вызывает этот скрипт один раз - после initdb первого лидера.
# Первым аргументом приходит строка подключения суперпользователя; нам хватает
# локального unix-сокета (в pg_hba: local all all trust).
set -euo pipefail
export PGHOST=/var/run/postgresql PGPORT=5432 PGUSER=postgres
MIGRATIONS_DIR=/migrations exec /scripts/apply_migrations.sh
