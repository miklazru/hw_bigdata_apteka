#!/usr/bin/env bash
# Э5. Цена синхронной репликации: synchronous_mode=true, повтор Э1 и Э2, возврат в async.
. "$(dirname "$0")/common.sh" e5_sync
N=$(any_node)
say "включаем синхронную репликацию"
docker compose exec -T "$N" patronictl edit-config --set synchronous_mode=true --force
sleep 15; plist
say "Э1 в sync-режиме"
DUR="${DUR:-60}"
$LAB writeloop --duration "$DUR" --out "$RAW/e5_sync_writeloop.csv"
$LAB analyze "$RAW/e5_sync_writeloop.csv"
say "Э2 в sync-режиме (отдельный лог e5_sync_kill.txt)"
EXP_NAME=e5_sync_kill bash scripts/failover/e2_kill_leader.sh || true
K=$(cat "$RAW/.killed_node")
say "возвращаем $K"; docker start "apteka_$K"; $LAB wait-member "$K" --states streaming --timeout 300
say "выключаем синхронную репликацию"
docker compose exec -T "$(any_node)" patronictl edit-config --set synchronous_mode=false --force
sleep 15; plist
