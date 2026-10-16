#!/usr/bin/env bash
# Ждёт готовности стенда:
#   1) в кластере Patroni есть лидер и две реплики в состоянии streaming;
#   2) через HAProxy (порт записи) во всех четырёх базах есть схема contract;
#   3) PgBouncer принимает подключения.
set -euo pipefail
cd "$(dirname "$0")/.."

TIMEOUT="${TIMEOUT:-300}"
deadline=$(( $(date +%s) + TIMEOUT ))
SERVICES=(crm catalog pos wms)

# выполнить команду в любом живом узле кластера (там есть curl и psql)
in_node() {
    local n
    for n in pg1 pg2 pg3; do
        if docker compose exec -T "$n" true >/dev/null 2>&1; then
            docker compose exec -T "$n" "$@"
            return $?
        fi
    done
    return 1
}

wait_for() {   # $1 - описание, $2... - проверка
    local what="$1"; shift
    echo -n "waiting for ${what}"
    until "$@" >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo " - timeout"
            docker compose ps
            in_node patronictl list || true
            exit 1
        fi
        echo -n "."; sleep 3
    done
    echo " ok"
}

cluster_ready() {
    local js leaders streaming
    js=$(in_node curl -fsS http://127.0.0.1:8008/cluster) || return 1
    leaders=$(grep -o '"role": *"leader"' <<<"$js" | wc -l)
    streaming=$(grep -o '"state": *"streaming"' <<<"$js" | wc -l)
    [ "$leaders" -eq 1 ] && [ "$streaming" -ge 2 ]
}

contract_ready() {
    local svc n
    for svc in "${SERVICES[@]}"; do
        n=$(in_node env PGPASSWORD=postgres psql -h haproxy -p 5000 -U postgres -d "${svc}_service_db" -tAc \
            "SELECT count(*) FROM pg_views WHERE schemaname = 'contract'") || return 1
        [ "${n:-0}" -gt 0 ] || return 1
    done
}

pooler_ready() {
    in_node env PGPASSWORD=checker psql -h pgbouncer -p 6432 -U checker -d pos_service_db -tAc "SELECT 1"
}

wait_for "patroni: leader + 2 streaming replicas" cluster_ready
wait_for "schema contract in 4 databases (via haproxy)" contract_ready
wait_for "pgbouncer" pooler_ready
in_node patronictl list
echo "ready"
