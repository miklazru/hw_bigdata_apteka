#!/usr/bin/env bash
# Э1. Baseline: запись под нагрузкой 60 с через PgBouncer -> HAProxy -> лидер.
. "$(dirname "$0")/common.sh" e1_baseline
DUR="${DUR:-60}"
$LAB init
say "состояние кластера"; plist
say "write-loop ${DUR} c: $LAB writeloop --duration $DUR"
$LAB writeloop --duration "$DUR" --out "$RAW/e1_writeloop.csv"
say "результат"; $LAB analyze "$RAW/e1_writeloop.csv"
