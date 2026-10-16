#!/usr/bin/env bash
# Э6. Отказ DCS: гасим один узел etcd из трёх (кворум жив), затем второй (кворума нет).
. "$(dirname "$0")/common.sh" e6_etcd
# что бы ни случилось - вернуть etcd и не оставить циклы-сироты
trap 'docker start apteka_etcd2 apteka_etcd3 >/dev/null 2>&1 || true; kill $(jobs -p) 2>/dev/null || true' EXIT
$LAB init >/dev/null
say "до эксперимента"; plist
docker compose exec -T etcd1 etcdctl endpoint status --cluster -w table
$LAB writeloop --duration 170 --out "$RAW/e6_writeloop.csv" & WL=$!
$LAB writeloop --read --dsn "postgresql://app:app@localhost:5001/ha_lab" --duration 170 --interval 0.5 \
     --out "$RAW/e6_readloop.csv" & RL=$!
sleep 10
T1=$(iso); say "docker stop apteka_etcd3  (остаётся 2 из 3 - кворум есть)"; docker stop apteka_etcd3
sleep 40
say "кластер при 2 из 3 узлах etcd"; plist
T2=$(iso); say "docker stop apteka_etcd2  (остаётся 1 из 3 - кворума нет)"; docker stop apteka_etcd2
sleep 70
say "кластер без кворума DCS (patronictl list читает etcd - ожидаем ошибку)"
docker compose exec -T "$(any_node)" patronictl list 2>&1 | grep -E "Error|Etcd|\|" | awk 'NR<=8' || true
for n in pg1 pg2 pg3; do
  echo -n "$n: "; docker compose exec -T "$n" curl -s http://127.0.0.1:8008/patroni \
    | $PY -c 'import json,sys; d=json.load(sys.stdin); print(d.get("role"), d.get("state"), "dcs_last_seen=", d.get("dcs_last_seen"))' || echo "?"
done
L=$(any_node)
say "лог Patroni ($L) после потери кворума"; plog "$L" "$T2" 30
T3=$(iso); say "docker start apteka_etcd2 apteka_etcd3"; docker start apteka_etcd2 apteka_etcd3
wait $WL $RL
say "запись (через PgBouncer)"; $LAB analyze "$RAW/e6_writeloop.csv" --check-lost
say "чтение (через HAProxy :5001)"; $LAB analyze "$RAW/e6_readloop.csv"
say "после возврата etcd"; plist
say "лог Patroni ($L) после возврата etcd"; plog "$L" "$T3" 20
echo; echo "моменты: etcd3 stop=$T1  etcd2 stop=$T2  etcd start=$T3"
