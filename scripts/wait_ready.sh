#!/usr/bin/env bash
# Ждёт, пока все базы примут запросы и в каждой появится схема contract.
set -euo pipefail
cd "$(dirname "$0")/.."

TIMEOUT="${TIMEOUT:-180}"
SERVICES=(crm catalog pos wms)
deadline=$(( $(date +%s) + TIMEOUT ))

echo -n "waiting for pg_master"
until [ "$(docker inspect -f '{{.State.Health.Status}}' apteka_pg_master 2>/dev/null)" = "healthy" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && { echo " - timeout"; docker compose logs --tail 50 pg_master; exit 1; }
    echo -n "."; sleep 2
done
echo " healthy"

for svc in "${SERVICES[@]}"; do
    db="${svc}_service_db"
    n=$(docker compose exec -T pg_master psql -U postgres -d "$db" -tAc \
        "SELECT count(*) FROM pg_views WHERE schemaname = 'contract'")
    echo "  ${db}: contract views = ${n}"
    [ "${n:-0}" -gt 0 ] || { echo "contract schema missing in ${db}"; exit 1; }
done
echo "ready"
