#!/usr/bin/env bash
# Э4. Плановое переключение (switchover) при работающем write-loop.
. "$(dirname "$0")/common.sh" e4_switchover
DUR="${DUR:-60}"; AT="${AT:-15}"
$LAB init >/dev/null
say "до переключения"; plist
L=$(leader); C=$(replicas | awk '{print $1}')
echo "лидер: $L, кандидат: $C"
$LAB writeloop --duration "$DUR" --out "$RAW/e4_writeloop.csv" & WL=$!
sleep "$AT"
say "patronictl switchover --leader $L --candidate $C --force"
docker compose exec -T "$L" patronictl switchover --leader "$L" --candidate "$C" --force
wait $WL
say "результат"; $LAB analyze "$RAW/e4_writeloop.csv" --check-lost
plist
