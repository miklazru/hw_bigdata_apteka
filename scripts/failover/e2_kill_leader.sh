#!/usr/bin/env bash
# Э2. Аварийная потеря лидера: docker kill при работающем write-loop.
. "$(dirname "$0")/common.sh" "${EXP_NAME:-e2_kill_leader}"
DUR="${DUR:-90}"; KILL_AT="${KILL_AT:-20}"
$LAB init >/dev/null
say "до аварии"; plist
L=$(leader); echo "лидер: $L"
$LAB writeloop --duration "$DUR" --out "$RAW/${EXP}_writeloop.csv" & WL=$!
sleep "$KILL_AT"
KILL_TS=$(iso)
say "docker kill apteka_$L"; docker kill "apteka_$L"
echo "$L" > "$RAW/.killed_node"
wait $WL
say "результат write-loop"; $LAB analyze "$RAW/${EXP}_writeloop.csv" --check-lost
NEW=$(leader); say "новый лидер: $NEW"; plist
say "лог Patroni нового лидера ($NEW) с момента kill"; plog "$NEW" "$KILL_TS" 40
for r in $(replicas); do
  [ "$r" = "$NEW" ] && continue
  running "apteka_$r" && { say "лог Patroni второй реплики ($r)"; plog "$r" "$KILL_TS" 25; }
done
say "параметры DCS"; docker compose exec -T "$NEW" patronictl show-config | grep -E "ttl|loop_wait|retry_timeout|synchronous"
