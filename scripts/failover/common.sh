# Общие функции для экспериментов журнала отказоустойчивости.
# Подключается из eN_*.sh:  . "$(dirname "$0")/common.sh" eN_name
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
RAW=docs/failover/raw
mkdir -p "$RAW"
EXP="$1"
LOG="$RAW/${EXP}.txt"
exec > >(tee "$LOG") 2>&1        # весь вывод эксперимента - в сырой лог

PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python
LAB="$PY scripts/failover/lab.py"

ts()      { date '+%H:%M:%S.%3N'; }
iso()     { date -Iseconds; }
say()     { echo; echo "[$(ts)] >>> $*"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
any_node(){ local n; for n in pg1 pg2 pg3; do running "apteka_$n" && { echo "$n"; return; }; done; return 1; }
plist()   { docker compose exec -T "$(any_node)" patronictl list 2>&1 | awk 'NR<=12' || true; }
leader()  { $LAB leader; }
replicas(){ $LAB leader --json | $PY -c 'import json,sys; print(" ".join(m["name"] for m in json.load(sys.stdin)["members"] if m["role"]!="leader"))'; }
# лог узла с момента $2: только строки с отметкой времени (без трейсбэков, pg_controldata
# и «no action» раз в loop_wait). awk вместо head: head закрывает трубу раньше времени,
# и при pipefail это SIGPIPE -> скрипт падает.
plog()    { docker logs --since "$2" "apteka_$1" 2>&1 \
              | grep -E '^20[0-9]{2}-' \
              | grep -vE 'no action|no pg_hba.conf entry for replication connection from host "127|Can not fetch local timeline' \
              | awk -v n="${3:-40}" 'NR<=n' || true; }

echo "=== ${EXP}  $(date '+%Y-%m-%d %H:%M:%S %Z')  host=$(hostname)"
