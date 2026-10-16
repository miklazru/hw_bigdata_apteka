#!/usr/bin/env bash
# Э7. Наплыв подключений: напрямую в PostgreSQL (max_connections=100) и через PgBouncer.
. "$(dirname "$0")/common.sh" e7_flood
$LAB init >/dev/null
STEPS="${STEPS:-20,50,90,100,150,300,500}"
docker compose exec -T "$(leader)" psql -U postgres -Atc "SHOW max_connections; SHOW superuser_reserved_connections;"
say "БЕЗ пула: HAProxy :5000 -> лидер, каждый клиент держит транзакцию 1 c"
$LAB flood --dsn "postgresql://app:app@localhost:5000/ha_lab" --steps "$STEPS"
say "С пулом: PgBouncer :6432 (default_pool_size=20, transaction pooling)"
$LAB flood --dsn "postgresql://app:app@localhost:6432/ha_lab" --steps "$STEPS"
