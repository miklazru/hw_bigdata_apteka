#!/usr/bin/env python3
"""
Инструменты для журнала отказоустойчивости (docs/failover_journal.md).

  lab.py init                         создать лабораторную базу ha_lab и таблицу ha_probe
  lab.py leader                       имя текущего лидера Patroni (pg1/pg2/pg3)
  lab.py writeloop --duration 60 --out f.csv
                                      цикл записи через PgBouncer: одна транзакция = одна строка,
                                      каждую попытку пишем в CSV (время, ok/ошибка, узел, задержка)
  lab.py analyze f.csv                TPS, медиана/p95, окна недоступности (RTO), потерянные
                                      подтверждённые транзакции (сверка id с базой)
  lab.py flood --dsn ... --steps 50,100,150
                                      наплыв N одновременных клиентов, каждый держит транзакцию

Подключения по умолчанию - точки входа стенда:
  LAB_DSN   = postgresql://app:app@localhost:6432/ha_lab         (через PgBouncer)
  ADMIN_DSN = postgresql://postgres:postgres@localhost:5000/postgres   (HAProxy -> лидер)
"""
import argparse
import csv
import json
import os
import statistics
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone

import psycopg2

LAB_DSN = os.environ.get("LAB_DSN", "postgresql://app:app@localhost:6432/ha_lab")
ADMIN_DSN = os.environ.get("ADMIN_DSN", "postgresql://postgres:postgres@localhost:5000/postgres")
PATRONI_APIS = os.environ.get("PATRONI_APIS", "http://localhost:8008,http://localhost:8009,http://localhost:8010").split(",")


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds")


def dsn_db(dsn, db):
    return dsn.rsplit("/", 1)[0] + "/" + db


# --------------------------------------------------------------------- init
def cmd_init(a):
    conn = psycopg2.connect(ADMIN_DSN, connect_timeout=5)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = 'ha_lab'")
        if not cur.fetchone():
            cur.execute("CREATE DATABASE ha_lab")
    conn.close()
    conn = psycopg2.connect(dsn_db(ADMIN_DSN, "ha_lab"), connect_timeout=5)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("""CREATE TABLE IF NOT EXISTS ha_probe (
                           id         bigserial PRIMARY KEY,
                           client_ts  timestamptz NOT NULL,
                           node       text,
                           created_at timestamptz NOT NULL DEFAULT clock_timestamp())""")
        cur.execute("GRANT USAGE, CREATE ON SCHEMA public TO app")
        cur.execute("GRANT SELECT, INSERT ON ha_probe TO app")
        cur.execute("GRANT USAGE ON SEQUENCE ha_probe_id_seq TO app")
    conn.close()
    print("ha_lab.ha_probe ready")


# --------------------------------------------------------------------- leader
def cluster():
    for api in PATRONI_APIS:
        try:
            with urllib.request.urlopen(api.rstrip("/") + "/cluster", timeout=3) as r:
                return json.loads(r.read().decode())
        except Exception:
            continue
    return None


def cmd_leader(a):
    c = cluster()
    if not c:
        sys.exit("Patroni API недоступен")
    leaders = [m["name"] for m in c["members"] if m["role"] == "leader"]
    if a.json:
        print(json.dumps(c, ensure_ascii=False, indent=1))
    else:
        print(leaders[0] if leaders else "")


def cmd_wait_member(a):
    """Ждать, пока узел a.name не станет replica/streaming (или running); печатает секунды."""
    t0 = time.time()
    while time.time() - t0 < a.timeout:
        c = cluster()
        if c:
            for m in c["members"]:
                if m["name"] == a.name and m.get("state") in a.states.split(","):
                    print(f"{time.time() - t0:.1f}")
                    return
        time.sleep(0.5)
    sys.exit(f"{a.name}: не дождались {a.states} за {a.timeout} c")


# --------------------------------------------------------------------- writeloop
def cmd_writeloop(a):
    deadline = time.time() + a.duration
    conn = None
    rows = 0
    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_start", "t_end", "ok", "latency_ms", "id", "node", "error"])
        while time.time() < deadline:
            t0 = time.time()
            ok, pid, node, err = 0, "", "", ""
            try:
                if conn is None or conn.closed:
                    conn = psycopg2.connect(a.dsn, connect_timeout=2)
                with conn.cursor() as cur:
                    # SET LOCAL: в transaction pooling обычный SET потерялся бы между транзакциями
                    cur.execute("SET LOCAL statement_timeout = '2s'")
                    if a.read:
                        cur.execute("SELECT 0, coalesce(inet_server_addr()::text, 'local') "
                                    "|| CASE WHEN pg_is_in_recovery() THEN ' (replica)' ELSE ' (primary)' END")
                    else:
                        cur.execute("INSERT INTO ha_probe (client_ts, node) "
                                    "VALUES (now(), coalesce(inet_server_addr()::text, 'local')) "
                                    "RETURNING id, node")
                    pid, node = cur.fetchone()
                conn.commit()          # успех = транзакция ПОДТВЕРЖДЕНА сервером
                ok = 1
            except Exception as e:
                err = str(e).strip().splitlines()[0][:160] if str(e).strip() else type(e).__name__
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
            t1 = time.time()
            w.writerow([f"{t0:.3f}", f"{t1:.3f}", ok, f"{(t1 - t0) * 1000:.1f}", pid, node, err])
            rows += 1
            if rows % 50 == 0:
                f.flush()
            if not ok:
                time.sleep(a.retry_pause)
            elif a.interval:
                time.sleep(a.interval)
    print(f"writeloop: {rows} attempts -> {a.out}")


def fmt_t(t):
    return datetime.fromtimestamp(float(t)).strftime("%H:%M:%S.%f")[:-3]


def cmd_analyze(a):
    with open(a.csv) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("пустой файл")
    t_first, t_last = float(rows[0]["t_start"]), float(rows[-1]["t_end"])
    dur = t_last - t_first
    oks = [r for r in rows if r["ok"] == "1"]
    lat = sorted(float(r["latency_ms"]) for r in oks)

    def pct(p):
        return lat[min(len(lat) - 1, int(round(p * (len(lat) - 1))))] if lat else float("nan")

    print(f"файл: {a.csv}")
    print(f"интервал: {fmt_t(t_first)} - {fmt_t(t_last)} ({dur:.1f} c)")
    print(f"попыток: {len(rows)}, успешных: {len(oks)}, ошибок: {len(rows) - len(oks)}")
    print(f"TPS (успешные / длительность): {len(oks) / dur:.1f}")
    if lat:
        print(f"задержка записи: медиана {statistics.median(lat):.1f} мс, p95 {pct(0.95):.1f} мс, max {lat[-1]:.1f} мс")
    nodes = []
    for r in oks:
        if not nodes or nodes[-1][0] != r["node"]:
            nodes.append([r["node"], 0])
        nodes[-1][1] += 1
    print("узлы, обслужившие запись (по порядку): " + " -> ".join(f"{n} ({c})" for n, c in nodes))

    # окна недоступности: подряд идущие неуспешные попытки
    windows, i = [], 0
    while i < len(rows):
        if rows[i]["ok"] == "1":
            i += 1
            continue
        j = i
        while j < len(rows) and rows[j]["ok"] != "1":
            j += 1
        before = rows[i - 1] if i > 0 else None
        after = rows[j] if j < len(rows) else None
        windows.append((before, rows[i:j], after))
        i = j
    if not windows:
        print("окон недоступности нет")
    for k, (before, fails, after) in enumerate(windows, 1):
        print(f"\nокно недоступности #{k}:")
        if before:
            print(f"  последняя успешная запись:   {fmt_t(before['t_end'])}  id={before['id']} узел={before['node']}")
        print(f"  первая ошибка:               {fmt_t(fails[0]['t_start'])}  {fails[0]['error']}")
        if after:
            print(f"  первая успешная после:       {fmt_t(after['t_end'])}  id={after['id']} узел={after['node']}")
        errs = {}
        for r in fails:
            errs[r["error"]] = errs.get(r["error"], 0) + 1
        print(f"  отклонённых попыток: {len(fails)}")
        for e, c in sorted(errs.items(), key=lambda x: -x[1])[:4]:
            print(f"    {c:4d} x {e}")
        if before and after:
            print(f"  RTO (окно недоступности записи): {float(after['t_end']) - float(before['t_end']):.2f} c")

    # потерянные подтверждённые транзакции
    if a.check_lost and oks and oks[0]["id"] not in ("", "0"):
        ids = [int(r["id"]) for r in oks]
        conn = psycopg2.connect(dsn_db(ADMIN_DSN, "ha_lab"), connect_timeout=5)
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM ha_probe WHERE id = ANY(%s)", (ids,))
            found = cur.fetchone()[0]
            cur.execute("SELECT max(id) FROM ha_probe")
            mx = cur.fetchone()[0]
        conn.close()
        print(f"\nподтверждённых транзакций: {len(ids)}, найдено в базе после теста: {found}, "
              f"потеряно: {len(ids) - found}")
        print(f"  max(id) в базе: {mx}; max подтверждённый id: {max(ids)}")


# --------------------------------------------------------------------- flood
def cmd_flood(a):
    print(f"flood: {a.dsn.split('@')[-1]}, каждый клиент держит транзакцию {a.hold} c")
    print(f"{'клиентов':>9} | {'успешно':>7} | {'ошибок':>6} | {'connect медиана/max, мс':>24} | {'время, c':>8} | первая ошибка")
    for n in [int(x) for x in a.steps.split(",")]:
        res = [None] * n
        start = threading.Barrier(n + 1)

        def client(i):
            try:
                start.wait()
            except threading.BrokenBarrierError:
                pass
            t0 = time.time()
            try:
                c = psycopg2.connect(a.dsn, connect_timeout=a.connect_timeout)
                tc = time.time() - t0
                with c.cursor() as cur:
                    cur.execute("SELECT pg_sleep(%s)", (a.hold,))
                c.commit()
                c.close()
                res[i] = (True, tc, "")
            except Exception as e:
                res[i] = (False, time.time() - t0, str(e).strip().splitlines()[0][:160])

        ths = [threading.Thread(target=client, args=(i,)) for i in range(n)]
        for t in ths:
            t.start()
        t0 = time.time()
        start.wait()
        for t in ths:
            t.join()
        el = time.time() - t0
        ok = [r for r in res if r and r[0]]
        bad = [r for r in res if not r or not r[0]]
        ct = sorted(r[1] * 1000 for r in ok)
        med = f"{statistics.median(ct):.0f}/{ct[-1]:.0f}" if ct else "-"
        first = bad[0][2] if bad and bad[0] else ""
        print(f"{n:>9} | {len(ok):>7} | {len(bad):>6} | {med:>24} | {el:>8.1f} | {first}")
        time.sleep(a.pause)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("init").set_defaults(fn=cmd_init)
    p = sp.add_parser("leader")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_leader)
    p = sp.add_parser("wait-member")
    p.add_argument("name")
    p.add_argument("--states", default="streaming,running")
    p.add_argument("--timeout", type=float, default=300)
    p.set_defaults(fn=cmd_wait_member)
    p = sp.add_parser("writeloop")
    p.add_argument("--dsn", default=LAB_DSN)
    p.add_argument("--duration", type=float, default=60)
    p.add_argument("--interval", type=float, default=0.0, help="пауза между успешными транзакциями, c")
    p.add_argument("--retry-pause", type=float, default=0.2, help="пауза после ошибки, c")
    p.add_argument("--out", required=True)
    p.add_argument("--read", action="store_true", help="читающий запрос вместо INSERT")
    p.set_defaults(fn=cmd_writeloop)
    p = sp.add_parser("analyze")
    p.add_argument("csv")
    p.add_argument("--check-lost", action="store_true")
    p.set_defaults(fn=cmd_analyze)
    p = sp.add_parser("flood")
    p.add_argument("--dsn", required=True)
    p.add_argument("--steps", default="20,50,90,100,150,300")
    p.add_argument("--hold", type=float, default=1.0)
    p.add_argument("--connect-timeout", type=int, default=10)
    p.add_argument("--pause", type=float, default=2.0)
    p.set_defaults(fn=cmd_flood)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
