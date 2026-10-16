#!/usr/bin/env bash
# Э8 (по желанию). Сетевой раздел: лидер жив, но отключён от сети.
. "$(dirname "$0")/common.sh" e8_partition
$LAB init >/dev/null
say "до"; plist
L=$(leader)
$LAB writeloop --duration 120 --out "$RAW/e8_writeloop.csv" & WL=$!
sleep 15
T=$(iso); say "docker network disconnect apteka108_dbnet apteka_$L"; docker network disconnect apteka108_dbnet "apteka_$L"
sleep 50
say "что думает изолированный узел $L о себе"
docker exec "apteka_$L" curl -s http://127.0.0.1:8008/patroni | head -c 600; echo
docker exec "apteka_$L" psql -U postgres -Atc "SELECT pg_is_in_recovery()" || true
say "кластер глазами остальных"; plist || true
say "лог изолированного узла"; plog "$L" "$T" 25
say "docker network connect"; docker network connect --ip "10.42.0.1${L#pg}" apteka108_dbnet "apteka_$L"
wait $WL
say "результат"; $LAB analyze "$RAW/e8_writeloop.csv" --check-lost
sleep 20; plist
