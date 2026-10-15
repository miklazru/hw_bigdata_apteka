#!/usr/bin/env bash
# Генератор данных. Внутри - Python (scripts/seed.py).
#   ./scripts/seed.sh --seed 42                      базовая загрузка (~13 мес. истории)
#   ./scripts/seed.sh --seed 777 --receipts 500      догенерация поверх существующих данных
# Подключение: SEED_DB_HOST / SEED_DB_PORT / SEED_DB_USER / SEED_DB_PASSWORD
# (по умолчанию localhost:5432, postgres/postgres - напрямую в мастер).
set -euo pipefail
cd "$(dirname "$0")/.."
PY=python3
[ -x .venv/bin/python ] && PY=.venv/bin/python
"$PY" -c "import psycopg2" 2>/dev/null || { echo "нужен psycopg2: pip install -r requirements.txt"; exit 1; }
exec "$PY" scripts/seed.py "$@"
