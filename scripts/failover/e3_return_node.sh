#!/usr/bin/env bash
# Э3. Возврат упавшего узла (после Э2): pg_rewind / basebackup / просто присоединился.
. "$(dirname "$0")/common.sh" e3_return_node
K=$(cat "$RAW/.killed_node")
LDR=$(leader)
say "лидер $LDR, LSN до возврата"
docker compose exec -T "$LDR" psql -U postgres -Atc "SELECT pg_current_wal_lsn()"
START=$(iso)
say "docker start apteka_$K"; docker start "apteka_$K"
SEC=$($LAB wait-member "$K" --states streaming --timeout 300)
say "узел $K в состоянии streaming через ${SEC} c"
plist
say "лог Patroni узла $K"; plog "$K" "$START" 40
say "pg_rewind / basebackup в логе узла $K"
docker logs --since "$START" "apteka_$K" 2>&1 | grep -iE "rewind|diverged|basebackup|bootstrap from" || echo "(нет)"
DIV=$(docker logs --since "$START" "apteka_$K" 2>&1 | grep -oE "diverged at WAL location [0-9A-F]+/[0-9A-F]+" | head -1 | awk '{print $NF}' || true)
if [ -n "$DIV" ]; then
  say "pg_rewind: точка расхождения $DIV; WAL, который узел догнал после неё:"
  docker compose exec -T "$LDR" psql -U postgres -Atc \
    "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '$DIV'))"
else
  echo "pg_rewind в логе не найден"
fi
