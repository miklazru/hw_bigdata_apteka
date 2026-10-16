#!/usr/bin/env bash
# Э0. Паспорт стенда для журнала: железо, ОС, версии, топология, параметры Patroni.
. "$(dirname "$0")/common.sh" e0_stand
say "машина"
lscpu 2>/dev/null | grep -E "Model name|^CPU\(s\)" || true
free -h | head -2
df -h . | tail -1
say "ОС";      uname -srm; (grep PRETTY_NAME /etc/os-release || true)
say "Docker";  docker --version; docker compose version
say "контейнеры"; docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
say "PostgreSQL"; docker compose exec -T "$(leader)" psql -U postgres -Atc "SELECT version()"
say "Patroni";  docker compose exec -T "$(any_node)" patroni --version
say "кластер";  plist
say "конфигурация DCS"; docker compose exec -T "$(any_node)" patronictl show-config
say "etcd";     docker compose exec -T etcd1 etcdctl endpoint status --cluster -w table
