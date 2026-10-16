#!/usr/bin/env python3
"""
Генератор данных «Аптека 108».

Режимы:
  seed.py --seed 42                     базовая загрузка: ~13 месяцев истории (+ разогрев склада)
  seed.py --seed 777 --receipts 500     догенерация: N чеков за день --as-of поверх существующих данных

Свойства:
  * детерминированный: одинаковые (--seed, --as-of) -> одинаковые данные
    (только random.Random(seed), никаких set/hash-зависимых обходов);
  * идемпотентный: каждый запуск пишет ключ в ref.seed_log каждой базы;
    повторный запуск с тем же ключом базу не трогает;
  * кросс-сервисная целостность по построению: симулируется движение товара
    поставщик -> РЦ -> аптека -> покупатель, продаём только то, что лежит
    на полке, из непросроченных партий (FEFO), по действующей цене,
    клиентам, которые есть в CRM.

Подключение: переменные окружения SEED_DB_HOST/PORT/USER/PASSWORD
(по умолчанию localhost:5000 postgres/postgres - HAProxy, порт записи -> текущий лидер).
"""
import argparse
import io
import math
import os
import random
import sys
import time as _time
from collections import defaultdict
from datetime import date, datetime, time, timedelta
from decimal import ROUND_HALF_UP, Decimal

import psycopg2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from seed_config import (BRAND_PARTS_A, BRAND_PARTS_B, COSMETICS, DC_IANA, DCS,  # noqa: E402
                         DEVICES, DRUG_FORMS, FIRST_F, FIRST_M, INNS, LAST,
                         MANUFACTURERS, REGION_TRAFFIC, REGIONS, STREETS,
                         SUPPLEMENTS, SUPPLIERS, tz)

# ---------------------------------------------------------------------------
# параметры объёма
# ---------------------------------------------------------------------------
N_SKU = 600
N_CUSTOMERS = 2600
TARGET_SALES = 24000          # продаж за окно (возвраты сверху, ~2.5%)
WARMUP_DAYS = 42              # разогрев склада до начала продаж
CARD_SHARE = 0.55             # доля чеков с картой (без карты ~45%)
REFUND_P = 0.027              # вероятность возврата по продаже
WEEKDAY = [1.05, 1.00, 1.00, 1.02, 1.12, 0.86, 0.68]       # пн..вс
SEASON = {1: 1.15, 2: 1.15, 3: 1.05, 4: 0.95, 5: 0.90, 6: 0.85,
          7: 0.85, 8: 0.88, 9: 0.98, 10: 1.08, 11: 1.12, 12: 1.18}
HOUR_W = {8: 3, 9: 5, 10: 6, 11: 7, 12: 8, 13: 8, 14: 7, 15: 6, 16: 7, 17: 9, 18: 10, 19: 9, 20: 6, 21: 3}
LEVEL_DISCOUNT = {"basic": Decimal("0.02"), "silver": Decimal("0.03"),
                  "gold": Decimal("0.05"), "platinum": Decimal("0.07")}

C2 = Decimal("0.01")


def money(x) -> Decimal:
    if not isinstance(x, Decimal):
        x = Decimal(repr(float(x)))
    return x.quantize(C2, rounding=ROUND_HALF_UP)


def add_months(d: date, months: int) -> date:
    y, m = divmod(d.year * 12 + d.month - 1 + months, 12)
    return date(y, m + 1, 1)


def local_dt(d: date, h: int, m: int, off: int, s: int = 0) -> datetime:
    return datetime.combine(d, time(h, m, s), tzinfo=tz(off))


def local_date(dt: datetime, off: int) -> date:
    return dt.astimezone(tz(off)).date()


def log(msg):
    print(f"[seed {datetime.now():%H:%M:%S}] {msg}", flush=True)


# ===========================================================================
# симуляция
# ===========================================================================
class Sim:
    def __init__(self, seed: int, as_of: date):
        self.r = random.Random(seed)
        self.seed = seed
        self.as_of = as_of
        self.win_start = add_months(as_of.replace(day=1), -12)     # 12 полных месяцев + текущий
        self.warm_start = self.win_start - timedelta(days=WARMUP_DAYS)
        self.last_day = as_of - timedelta(days=1)                  # продажи по вчера включительно
        self.counters = defaultdict(int)

    # ------------------------------------------------------------------ utils
    def poisson(self, lam: float) -> int:
        if lam <= 0:
            return 0
        if lam > 30:
            return max(0, int(round(self.r.gauss(lam, math.sqrt(lam)))))
        L, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.r.random()
            if p <= L:
                return k
            k += 1

    def next_no(self, key) -> int:
        self.counters[key] += 1
        return self.counters[key]

    def day_factor(self, d: date) -> float:
        f = WEEKDAY[d.weekday()] * SEASON[d.month]
        if d.month == 1 and d.day == 1:
            f *= 0.4
        elif d.month == 1 and d.day <= 8:
            f *= 0.8
        return f

    # =================================================================== catalog
    def build_catalog(self):
        r = self.r
        self.manufacturers = [(f"MFR-{i:04d}", n, c) for i, (n, c) in enumerate(MANUFACTURERS, 1)]
        self.inns = [(f"INN-{i:04d}", n, rx, vital) for i, (n, rx, vital) in enumerate(INNS, 1)]
        rx_inns = [x for x in self.inns if x[2]]
        otc_inns = [x for x in self.inns if not x[2]]
        form_name = dict(DRUG_FORMS)

        ranks = list(range(1, N_SKU + 1))
        r.shuffle(ranks)
        cats = ["rx"] * 30 + ["otc"] * 40 + ["supplement"] * 12 + ["device"] * 10 + ["cosmetics"] * 8
        used_names = set()
        self.skus = []
        for i in range(1, N_SKU + 1):
            cat = r.choice(cats)
            inn_list, form, dose = [], None, None
            if cat in ("rx", "otc"):
                pool = rx_inns if cat == "rx" else otc_inns
                inn_list = [r.choice(pool)]
                if r.random() < 0.06:
                    other = r.choice(pool)
                    if other[0] != inn_list[0][0]:
                        inn_list.append(other)
                form = r.choice(["tablet", "tablet", "film_tablet", "capsule", "solution", "syrup",
                                 "injection", "ointment", "gel", "drops", "spray", "suppository",
                                 "lozenge", "powder", "cream"])
                dose = r.choice([5, 10, 20, 25, 40, 50, 100, 200, 250, 400, 500, 1000])
                brand = r.choice(BRAND_PARTS_A) + r.choice(BRAND_PARTS_B)
                base = brand.capitalize() if r.random() < 0.6 else inn_list[0][1].split(" ")[0].capitalize()
                pack = r.choice([10, 14, 20, 28, 30, 50, 100]) if form in ("tablet", "film_tablet", "capsule",
                                                                             "lozenge", "suppository") else 1
                name = f"{base} {form_name[form]} {dose} мг №{pack}"
                price = math.exp(r.gauss(5.6, 0.85))
                shelf = r.randint(720, 1080) if r.random() > 0.12 else r.randint(240, 330)
            elif cat == "supplement":
                form = r.choice(["capsule", "tablet", "powder", "drops"])
                pack = r.choice([30, 60, 90, 120]) if form in ("capsule", "tablet") else 1
                name = f"{r.choice(SUPPLEMENTS)} «{(r.choice(BRAND_PARTS_A) + r.choice(BRAND_PARTS_B)).capitalize()}» №{pack}"
                price = math.exp(r.gauss(6.3, 0.6))
                shelf = r.randint(540, 720)
            elif cat == "device":
                pack = r.choice([1, 1, 1, 10, 50, 100])
                name = f"{r.choice(DEVICES)} {r.choice(BRAND_PARTS_A).upper()}-{r.randint(10, 990)}"
                price = math.exp(r.gauss(6.6, 1.0))
                shelf = 1800
            else:
                form = r.choice(["cream", "gel", None])
                pack = 1
                name = f"{r.choice(COSMETICS)} «{(r.choice(BRAND_PARTS_A) + r.choice(BRAND_PARTS_B)).capitalize()}» {r.choice([30, 50, 75, 100, 150, 200, 250])} мл"
                price = math.exp(r.gauss(6.2, 0.6))
                shelf = r.randint(720, 1080)
            base_name, k = name, 1
            while name in used_names:
                k += 1
                name = f"{base_name} ({k})"
            used_names.add(name)
            vital = cat in ("rx", "otc") and inn_list[0][3] and r.random() < 0.7
            pop = 1.0 / (ranks[i - 1] ** 1.15)
            if cat in ("device", "cosmetics"):
                pop *= 0.6
            self.skus.append({
                "bk": f"SKU-{i:06d}", "name": name, "cat": cat, "inns": [x[0] for x in inn_list],
                "form": form if cat != "device" else None, "mfr": r.choice(self.manufacturers)[0],
                "vital": vital, "pack": pack, "price": max(30.0, min(15000.0, price)),
                "shelf": shelf, "pop": pop, "rank": ranks[i - 1],
                "created": datetime.combine(self.warm_start - timedelta(days=r.randint(30, 1500)),
                                            time(9, 0), tzinfo=tz(3)),
                "events": [],     # (ts, attr, new_value) - смена категории / названия
            })
        # события: 3 рецептурных препарата переводятся в безрецептурные, 5 переименований
        lo, hi = self.win_start + timedelta(days=60), self.as_of - timedelta(days=30)
        span = (hi - lo).days
        rx_mid = [s for s in self.skus if s["cat"] == "rx" and 150 < s["rank"] < 450]
        for s in r.sample(rx_mid, 3):
            ts = local_dt(lo + timedelta(days=r.randint(0, span)), 10, 0, 3)
            s["events"].append((ts, "category", "otc"))
        for s in r.sample(self.skus, 5):
            ts = local_dt(lo + timedelta(days=r.randint(0, span)), 11, 0, 3)
            s["events"].append((ts, "sku_name", s["name"] + " (новая упаковка)"))
        for s in self.skus:
            s["events"].sort(key=lambda e: e[0])
        self.sku_by_bk = {s["bk"]: s for s in self.skus}

    def attr_at(self, s, attr, ts):
        key = "cat" if attr == "category" else "name"
        val = s[key]
        for ets, a, v in s["events"]:
            if a == attr and ets <= ts:
                val = v
        return val

    # =================================================================== network
    def build_network(self):
        r = self.r
        self.pharmacies = []
        n = 0
        for reg, (off, iana, dc, cnt, cities, transit) in REGIONS.items():
            for k in range(cnt):
                n += 1
                opened = date(2012, 1, 1) + timedelta(days=r.randint(0, (self.warm_start - date(2012, 1, 1)).days - 90))
                size = math.exp(r.gauss(0, 0.45)) * REGION_TRAFFIC.get(reg, 1.0)
                self.pharmacies.append({
                    "bk": f"PH-{n:04d}", "num": n, "region": reg, "off": off, "iana": iana, "dc": dc,
                    "city": cities[k % len(cities)],
                    "address": f"{r.choice(STREETS)}, д. {r.randint(1, 180)}",
                    "name": f"Аптека 108 №{n}", "opened": opened, "closed": None,
                    "size": size, "transit": transit,
                })
        # две аптеки открылись внутри окна, одна закрылась
        cand = [p for p in self.pharmacies if p["region"] not in ("RU-MOW",)]
        for p in r.sample(cand, 2):
            p["opened"] = self.win_start + timedelta(days=r.randint(60, 200))
        closing = r.choice([p for p in self.pharmacies if p["region"] in ("RU-MOW", "RU-MOS")
                            and p["opened"] < self.warm_start])
        closing["closed"] = self.as_of - timedelta(days=r.randint(40, 100))
        self.ph_by_bk = {p["bk"]: p for p in self.pharmacies}

        cashier_no = 0
        for p in self.pharmacies:
            nreg = 1 + (p["size"] > 1.2) + (p["size"] > 2.0)
            p["registers"] = [f"REG-{p['num']:04d}-{j:02d}" for j in range(1, nreg + 1)]
            p["cashiers"] = []
            for _ in range(2 + 2 * nreg):
                cashier_no += 1
                p["cashiers"].append(f"CSH-{cashier_no:05d}")
            p["repl_days"] = {p["num"] % 5} | ({(p["num"] + 2) % 5} if p["size"] > 1.3 else set())

        self.suppliers = [{"bk": bk, "name": nm, "country": c, "dc": dc, "deleted": None}
                          for bk, nm, c, dc in SUPPLIERS]
        # SUP-0010 уходит с рынка: soft delete, его SKU переходят к SUP-0001
        self.sup_exit = local_dt(self.win_start + timedelta(days=180), 12, 0, 3)
        self.suppliers[9]["deleted"] = self.sup_exit
        fed = [s["bk"] for s in self.suppliers[:10]]
        order = list(range(N_SKU))
        r.shuffle(order)
        for k, idx in enumerate(order):
            self.skus[idx]["fed_sup"] = fed[k % 10]
        # региональные поставщики возят 8% SKU напрямую в свой РЦ
        self.direct = {}          # (dc, sku_bk) -> supplier
        for s in self.suppliers[10:]:
            for sku in r.sample(self.skus, int(N_SKU * 0.08)):
                self.direct[(s["dc"], sku["bk"])] = s["bk"]

    def supplier_for(self, sku, d: date) -> str:
        sup = sku["fed_sup"]
        if sup == "SUP-0010" and d >= self.sup_exit.date():
            return "SUP-0001"
        return sup

    # =================================================================== customers
    def build_customers(self):
        r = self.r
        weights = [(reg, cnt * REGION_TRAFFIC.get(reg, 1.0))
                   for reg, (_, _, _, cnt, _, _) in REGIONS.items()]
        regs = [w[0] for w in weights]
        regw = [w[1] for w in weights]
        before = (self.win_start - date(2019, 1, 1)).days
        inwin = (self.last_day - self.win_start).days
        self.customers = []
        card_no = 0
        for i in range(1, N_CUSTOMERS + 1):
            if r.random() < 0.7:
                reg_d = date(2019, 1, 1) + timedelta(days=r.randint(0, before - 1))
            else:
                reg_d = self.win_start + timedelta(days=r.randint(0, inwin))
            region = r.choices(regs, regw)[0]
            off = REGIONS[region][0]
            registered = local_dt(reg_d, r.randint(9, 20), r.randint(0, 59), off)
            sex = None if r.random() < 0.12 else ("F" if r.random() < 0.62 else "M")
            birth = None
            if r.random() < 0.75:
                age = max(18, min(88, int(r.gauss(47, 16))))
                birth = date(reg_d.year - age, r.randint(1, 12), r.randint(1, 28))
            c = {
                "bk": f"CUST-{i:07d}", "idx": i, "registered": registered, "region": region,
                "city": r.choice(REGIONS[region][4]), "sex": sex, "birth": birth,
                "activity": math.exp(r.gauss(0, 0.9)), "level": None, "cards": [], "events": [],
                "forget": None, "consents": [],
            }
            # ПДн
            male = sex == "M" or (sex is None and r.random() < 0.4)
            last = r.choice(LAST)
            c["full_name"] = (f"{last} {r.choice(FIRST_M)}" if male
                              else f"{last}а {r.choice(FIRST_F)}")
            c["phone"] = f"+79{(i * 7919 + 1000003) % 10**9:09d}"
            c["email"] = None if r.random() < 0.2 else f"client{i:07d}@mail.example"
            # карты
            if r.random() < 0.80:
                card_no += 1
                issued = registered + timedelta(days=r.randint(0, 20), minutes=5)
                if issued.date() >= self.as_of:
                    issued = registered + timedelta(minutes=5)
                card = {"bk": f"CARD-{card_no:07d}", "issued": issued, "closed": None, "status": "active",
                        "balance": money(r.uniform(0, 2500))}
                c["cards"].append(card)
                span = (self.last_day - issued.date()).days
                if r.random() < 0.08 and span > 120:
                    reissue = issued + timedelta(days=r.randint(60, span - 30))
                    card["closed"], card["status"] = reissue, "closed"
                    card["balance"] = Decimal("0.00")
                    card_no += 1
                    c["cards"].append({"bk": f"CARD-{card_no:07d}", "issued": reissue + timedelta(minutes=1),
                                       "closed": None, "status": "active",
                                       "balance": money(r.uniform(0, 2500))})
                elif r.random() < 0.02:
                    card["status"] = "blocked"
            # согласия
            c["consents"].append(["pd_processing", registered, None])
            if r.random() < 0.6:
                cons = ["marketing", registered, None]
                c["consents"].append(cons)
                span = (self.last_day - registered.date()).days
                if r.random() < 0.15 and span > 60:
                    cons[2] = registered + timedelta(days=r.randint(30, span - 10), hours=2)
                    if r.random() < 0.3 and (self.last_day - cons[2].date()).days > 20:
                        c["consents"].append(["marketing", cons[2] + timedelta(days=r.randint(5, (self.last_day - cons[2].date()).days - 2)), None])
            if r.random() < 0.3:
                c["consents"].append(["sms", registered, None])
            self.customers.append(c)

        # уровни лояльности по активности (только у владельцев карт)
        carded = sorted([c for c in self.customers if c["cards"]], key=lambda c: (-c["activity"], c["idx"]))
        n = len(carded)
        for k, c in enumerate(carded):
            q = k / n
            c["level"] = "platinum" if q < 0.04 else "gold" if q < 0.14 else "silver" if q < 0.39 else "basic"
        lo = self.win_start + timedelta(days=30)
        span = (self.last_day - lo).days
        order_lv = ["basic", "silver", "gold", "platinum"]
        for c in carded:
            if c["level"] != "platinum" and r.random() < 0.10:
                ts = local_dt(lo + timedelta(days=r.randint(0, span)), 3, 0, 3)
                if ts > c["registered"]:
                    c["events"].append((ts, "loyalty_level", order_lv[order_lv.index(c["level"]) + 1]))
        for c in self.customers:
            if r.random() < 0.02:
                ts = local_dt(lo + timedelta(days=r.randint(0, span)), 12, 0, 3)
                if ts > c["registered"]:
                    nreg = r.choice(list(REGIONS))
                    c["events"].append((ts, "move", (nreg, r.choice(REGIONS[nreg][4]))))
            c["events"].sort(key=lambda e: e[0])
        # «забывание»: ~1.2% клиентов
        for c in self.customers:
            if r.random() < 0.012 and c["registered"].date() < self.as_of - timedelta(days=90):
                lo_f = max(c["registered"].date() + timedelta(days=30), self.win_start)
                hi_f = self.as_of - timedelta(days=3)
                if lo_f < hi_f:
                    f = local_dt(lo_f + timedelta(days=r.randint(0, (hi_f - lo_f).days)), 15, 0, 3)
                    # события и согласия после забывания не происходят
                    if all(e[0] < f for e in c["events"]) and \
                       all(cs[1] < f and (cs[2] is None or cs[2] < f) for cs in c["consents"]) and \
                       all(cd["issued"] < f and (cd["closed"] is None or cd["closed"] < f) for cd in c["cards"]):
                        c["forget"] = f

        # пулы покупателей по регионам (отсортированы по дате, в которую клиент может платить картой)
        self.cust_pool = defaultdict(list)
        self.cust_all = []
        for c in self.customers:
            if c["cards"]:
                c["can_buy"] = c["cards"][0]["issued"]
                self.cust_pool[c["region"]].append(c)
                self.cust_all.append(c)
        for lst in list(self.cust_pool.values()) + [self.cust_all]:
            lst.sort(key=lambda c: (c["can_buy"], c["idx"]))

    def level_at(self, c, ts):
        lv = c["level"]
        # уровень в c["level"] - исходный; повышения применяются по событиям
        for ets, a, v in c["events"]:
            if a == "loyalty_level" and ets <= ts:
                lv = v
        return lv

    def pick_customer(self, region, ts):
        r = self.r
        pool = self.cust_pool[region] if r.random() < 0.85 and self.cust_pool[region] else self.cust_all
        cands = []
        for c in pool:
            if c["can_buy"] > ts:
                break
            if c["forget"] is not None and c["forget"] <= ts:
                continue
            cands.append(c)
        if not cands:
            return None
        return r.choices(cands, [c["activity"] for c in cands])[0]

    # =================================================================== prices
    def build_prices(self):
        r = self.r
        t0 = local_dt(self.warm_start - timedelta(days=30), 0, 0, 3)
        end = local_dt(self.as_of, 0, 0, 3)
        self.prices = []            # (sku_bk, scope, scope_bk, price, from, to)
        self.chain = {}             # sku_bk -> [(from, to, price)]
        self.regional = {}          # (sku_bk, region) -> [(from, to, price)]
        self.promo = {}             # (sku_bk, pharmacy) -> [(from, to, price)]
        far = ["RU-SA", "RU-SAK", "RU-KHA", "RU-PRI", "RU-MUR", "RU-ARK", "RU-BU", "RU-IRK", "RU-KYA", "RU-MOW"]
        for s in self.skus:
            vers, t, p = [], t0, s["price"]
            while True:
                nxt = t + timedelta(days=r.randint(60, 150))
                if nxt >= end:
                    vers.append((t, None, money(p)))
                    break
                vers.append((t, nxt, money(p)))
                t, p = nxt, p * r.uniform(0.97, 1.10)
            self.chain[s["bk"]] = vers
            if r.random() < 0.25:
                for reg in r.sample(far, r.randint(1, 3)):
                    k = 1.03 if reg == "RU-MOW" else r.uniform(1.05, 1.18)
                    start_i = r.randint(0, len(vers) - 1)
                    rv = [(f, to, money(float(pr) * k)) for f, to, pr in vers[start_i:]]
                    self.regional[(s["bk"], reg)] = rv
        # промо-цены в конкретных аптеках
        popular = sorted(self.skus, key=lambda s: s["rank"])[:80]
        for _ in range(60):
            s, ph = r.choice(popular), r.choice(self.pharmacies)
            key = (s["bk"], ph["bk"])
            if key in self.promo:
                continue
            f = local_dt(self.win_start + timedelta(days=r.randint(0, 330)), 0, 0, ph["off"])
            to = f + timedelta(days=r.randint(14, 30))
            if to >= end:
                continue
            base = self.price_at(s["bk"], ph, f)
            self.promo[key] = [(f, to, money(base * Decimal("0.85")))]
        for sku_bk, vers in self.chain.items():
            for f, to, p in vers:
                self.prices.append((sku_bk, "chain", "ALL", p, f, to))
        for (sku_bk, reg), vers in self.regional.items():
            for f, to, p in vers:
                self.prices.append((sku_bk, "region", reg, p, f, to))
        for (sku_bk, ph), vers in self.promo.items():
            for f, to, p in vers:
                self.prices.append((sku_bk, "pharmacy", ph, p, f, to))
        # предельная цена ЖНВЛП - не ниже любой версии
        maxp = defaultdict(Decimal)
        for sku_bk, _, _, p, _, _ in self.prices:
            maxp[sku_bk] = max(maxp[sku_bk], p)
        for s in self.skus:
            s["cap"] = money(math.ceil(float(maxp[s["bk"]]) * 1.05)) if s["vital"] else None

    @staticmethod
    def _find(vers, ts):
        for f, to, p in vers:
            if f <= ts and (to is None or ts < to):
                return p
        return None

    def price_at(self, sku_bk, ph, ts):
        for key, table in (((sku_bk, ph["bk"]), self.promo), ((sku_bk, ph["region"]), self.regional)):
            vers = table.get(key)
            if vers:
                p = self._find(vers, ts)
                if p is not None:
                    return p
        return self._find(self.chain[sku_bk], ts)

    # =================================================================== demand
    def build_demand(self):
        r = self.r
        days = [self.win_start + timedelta(days=i) for i in range((self.last_day - self.win_start).days + 1)]
        denom = 0.0
        for p in self.pharmacies:
            for d in days:
                if self.is_open(p, d):
                    denom += p["size"] * self.day_factor(d)
        self.base_rate = TARGET_SALES / denom
        avg_factor = sum(self.day_factor(d) for d in days) / len(days)
        lines_per_receipt, qty_per_line = 3.0, 1.22
        for p in self.pharmacies:
            n_ass = max(120, min(N_SKU, int(120 + 200 * p["size"])))
            scored = sorted(self.skus, key=lambda s: (-s["pop"] * r.uniform(0.4, 1.6), s["bk"]))
            ass = sorted(scored[:n_ass], key=lambda s: s["bk"])
            p["assort"] = [s["bk"] for s in ass]
            p["assort_w"] = [s["pop"] for s in ass]
            W = sum(p["assort_w"])
            lam = self.base_rate * p["size"] * avg_factor
            p["demand"] = {s["bk"]: lam * lines_per_receipt * qty_per_line * s["pop"] / W for s in ass}
        # спрос РЦ
        self.dc_demand = defaultdict(lambda: defaultdict(float))       # dc -> sku -> units/day
        for p in self.pharmacies:
            for sku, dm in p["demand"].items():
                self.dc_demand[p["dc"]][sku] += dm
        self.hub_demand = defaultdict(float)                            # DC-01: свой + магистраль
        for dc, dd in self.dc_demand.items():
            for sku, dm in dd.items():
                if dc == "DC-01" or (dc, sku) not in self.direct:
                    self.hub_demand[sku] += dm

    def is_open(self, p, d):
        return p["opened"] <= d and (p["closed"] is None or d < p["closed"])

    # =================================================================== warehouse
    def _stock_add(self, loc, b, qty):
        lst = self.stock[loc][b["sku"]]
        for item in lst:
            if item[0] is b:
                item[1] += qty
                return
        lst.append([b, qty])
        lst.sort(key=lambda it: (it[0]["expiry"], it[0]["seq"]))

    def _on_hand(self, loc, sku, min_expiry):
        return sum(q for b, q in self.stock[loc][sku] if q > 0 and b["expiry"] >= min_expiry)

    def _take_fefo(self, loc, sku, qty, min_expiry, single_batch=False):
        """Снять qty FEFO; вернуть [(batch, q)]."""
        out = []
        for item in self.stock[loc][sku]:
            b, have = item
            if have <= 0 or b["expiry"] < min_expiry:
                continue
            q = min(have, qty)
            item[1] -= q
            qty -= q
            out.append((b, q))
            if qty == 0 or single_batch:
                break
        self.stock[loc][sku] = [it for it in self.stock[loc][sku] if it[1] > 0]
        return out

    def _movement(self, mtype, b, qty, moved_at, src_type=None, src=None, dst_type=None, dst=None,
                  supplier=None, dispatched=None, reason=None):
        self.mv_seq += 1
        self.movements.append({
            "seq": self.mv_seq, "type": mtype, "batch": b["bk"], "qty": qty, "moved_at": moved_at,
            "dispatched": dispatched, "src_type": src_type, "src": src, "dst_type": dst_type, "dst": dst,
            "supplier": supplier, "reason": reason,
        })

    def _transfer(self, d, src_loc, src_off, dst_type, dst_loc, dst_off, sku, qty, min_expiry, transit_h):
        r = self.r
        taken = self._take_fefo(src_loc, sku, qty, min_expiry)
        if not taken:
            return 0
        dispatched = local_dt(d, 6, r.randint(0, 59), src_off)
        h = transit_h * r.uniform(0.8, 1.25)
        if r.random() < (0.2 if dst_loc in self.slow_dst else 0.07):
            h += r.choice([24, 48])
        moved = dispatched + timedelta(hours=h)
        if dst_type == "pharmacy":
            ld = moved.astimezone(tz(dst_off))
            avail = ld.date() if ld.hour < 21 else ld.date() + timedelta(days=1)
        else:
            avail = local_date(moved, dst_off) + timedelta(days=1)
        total = 0
        for b, q in taken:
            self._movement("transfer", b, q, moved, "dc" if src_loc.startswith("DC") else "pharmacy", src_loc,
                           dst_type, dst_loc, dispatched=dispatched)
            self.arrivals[avail].append((dst_loc, b, q))
            self.inbound[(dst_loc, sku)] += q
            total += q
        return total

    def _purchase(self, d, dc, supplier, lines):
        """lines: [(sku_bk, qty)] - заказ поставщику, приход через 2..6 (регион: 1..4) дня."""
        r = self.r
        off = DCS[dc][3]
        ordered = local_dt(d, 11, r.randint(0, 59), off)
        po_bk = f"PO-{ordered.astimezone(tz(off)):%Y%m%d}-{self.next_no(('PO', ordered.astimezone(tz(off)).date())):04d}"
        lead = r.randint(1, 4) if supplier in ("SUP-0011", "SUP-0012", "SUP-0013", "SUP-0014") else r.randint(2, 6)
        arr_day = d + timedelta(days=lead)
        po = {"bk": po_bk, "supplier": supplier, "dc": dc, "ordered": ordered, "lines": []}
        self.purchases.append(po)
        for no, (sku_bk, qty) in enumerate(lines, 1):
            s = self.sku_by_bk[sku_bk]
            line = {"no": no, "sku": sku_bk, "qty": qty,
                    "cost": money(float(self.chain[sku_bk][0][2]) * 0.62 * r.uniform(0.95, 1.06)),
                    "batch": None, "received": None}
            po["lines"].append(line)
            self.on_order[(dc, sku_bk)] += qty
            if arr_day <= self.last_day:
                self.pending_po[arr_day].append((po, line))

    def _receive(self, d, po, line):
        r = self.r
        dc, off = po["dc"], DCS[po["dc"]][3]
        s = self.sku_by_bk[line["sku"]]
        moved = local_dt(d, 10, r.randint(0, 59), off)
        year = moved.year
        self.batch_seq += 1
        mfd = d - timedelta(days=r.randint(15, 150))
        expiry = mfd + timedelta(days=s["shelf"])
        if expiry < d + timedelta(days=90):
            mfd = d - timedelta(days=15)
            expiry = mfd + timedelta(days=s["shelf"])
        b = {"bk": f"BATCH-{year}-{self.next_no(('BATCH', year)):05d}", "sku": s["bk"], "seq": self.batch_seq,
             "series": f"{chr(65 + self.batch_seq % 26)}{chr(65 + (self.batch_seq // 26) % 26)}{year % 100:02d}{self.batch_seq:05d}",
             "mfd": mfd, "expiry": expiry, "received": moved}
        self.batches.append(b)
        self.batch_index[b["bk"]] = b
        line["batch"], line["received"] = b["bk"], moved
        self.on_order[(dc, s["bk"])] -= line["qty"]
        self._movement("receipt", b, line["qty"], moved, "supplier", None, "dc", dc,
                       supplier=po["supplier"], dispatched=moved - timedelta(hours=r.randint(6, 40)))
        self.arrivals[d + timedelta(days=1)].append((dc, b, line["qty"]))
        self.inbound[(dc, s["bk"])] += line["qty"]
        # редкий брак партии: возврат части поставщику через 2 дня
        if r.random() < 0.015:
            self.dc_returns[d + timedelta(days=2)].append((dc, b, max(1, line["qty"] // 10), po["supplier"]))

    # =================================================================== simulate
    def simulate(self):
        r = self.r
        self.stock = defaultdict(lambda: defaultdict(list))
        self.arrivals = defaultdict(list)
        self.inbound = defaultdict(int)
        self.on_order = defaultdict(int)
        self.pending_po = defaultdict(list)
        self.dc_returns = defaultdict(list)
        self.refunds_due = defaultdict(list)
        self.movements, self.mv_seq = [], 0
        self.purchases, self.batches, self.batch_seq, self.batch_index = [], [], 0, {}
        self.receipts, self.shifts, self.prescriptions = [], {}, []
        self.slow_dst = {p["bk"] for p in self.pharmacies if p["region"] in ("RU-SAK", "RU-SA")}
        dc_off = {dc: v[3] for dc, v in DCS.items()}

        d = self.warm_start
        while d <= self.last_day:
            # 1. поступления, доступные с сегодняшнего дня
            for loc, b, q in self.arrivals.pop(d, []):
                self._stock_add(loc, b, q)
                self.inbound[(loc, b["sku"])] -= q
            # 2. списание просрочки (09:00 местного), только остаток на начало дня
            for loc, by_sku in self.stock.items():
                off = dc_off[loc] if loc.startswith("DC") else self.ph_by_bk[loc]["off"]
                for sku, lst in by_sku.items():
                    for item in lst:
                        b, q = item
                        if q > 0 and b["expiry"] < d:
                            self._movement("writeoff", b, q, local_dt(d, 9, 0, off), "dc" if loc.startswith("DC") else "pharmacy",
                                           loc, reason="expired")
                            item[1] = 0
                    by_sku[sku] = [it for it in lst if it[1] > 0]
            # 3. возвраты брака поставщику
            for dc, b, q, sup in self.dc_returns.pop(d, []):
                for item in self.stock[dc][b["sku"]]:
                    if item[0] is b and item[1] >= q:
                        item[1] -= q
                        self._movement("return", b, q, local_dt(d, 12, 0, dc_off[dc]), "dc", dc, supplier=sup)
                        break
            # 4. приход заказов поставщикам
            for po, line in self.pending_po.pop(d, []):
                self._receive(d, po, line)
            # 5. заказы: DC-01 по понедельникам (и в первый день разогрева), регионалы - по вторникам
            if d.weekday() == 0 or d == self.warm_start:
                by_sup = defaultdict(list)
                for s in self.skus:
                    dm = self.hub_demand.get(s["bk"], 0.0)
                    if dm <= 0:
                        continue
                    pos = self._on_hand("DC-01", s["bk"], d) + self.inbound[("DC-01", s["bk"])] + self.on_order[("DC-01", s["bk"])]
                    if pos < dm * 21:
                        qty = int(math.ceil(max(10, dm * 49 - pos) / 10.0) * 10)
                        by_sup[self.supplier_for(s, d)].append((s["bk"], qty))
                for sup in sorted(by_sup):
                    self._purchase(d, "DC-01", sup, by_sup[sup])
            if d.weekday() == 1 or d == self.warm_start:
                for sup in self.suppliers[10:]:
                    dc, lines = sup["dc"], []
                    for s in self.skus:
                        if self.direct.get((dc, s["bk"])) != sup["bk"]:
                            continue
                        dm = self.dc_demand[dc].get(s["bk"], 0.0)
                        if dm <= 0:
                            continue
                        pos = self._on_hand(dc, s["bk"], d) + self.inbound[(dc, s["bk"])] + self.on_order[(dc, s["bk"])]
                        if pos < dm * 14:
                            lines.append((s["bk"], int(math.ceil(max(10, dm * 35 - pos) / 10.0) * 10)))
                    if lines:
                        self._purchase(d, dc, sup["bk"], lines)
            # 6. магистраль DC-01 -> региональные РЦ (среда)
            if d.weekday() == 2:
                for dc, (_, _, _, off, transit) in DCS.items():
                    if dc == "DC-01":
                        continue
                    for s in self.skus:
                        if (dc, s["bk"]) in self.direct:
                            continue
                        dm = self.dc_demand[dc].get(s["bk"], 0.0)
                        if dm <= 0:
                            continue
                        pos = self._on_hand(dc, s["bk"], d) + self.inbound[(dc, s["bk"])]
                        if pos < dm * 14:
                            need = int(math.ceil(max(2, dm * 35 - pos)))
                            self._transfer(d, "DC-01", 3, "dc", dc, off, s["bk"], need,
                                           d + timedelta(days=75), transit)
            # 7. развоз РЦ -> аптеки (по графику аптеки; первичное наполнение - каждый будний день)
            for p in self.pharmacies:
                start_fill = p["opened"] - timedelta(days=4)
                if not (start_fill <= d and (p["closed"] is None or d < p["closed"] - timedelta(days=10))):
                    continue
                if d.weekday() not in p["repl_days"] and not (d < p["opened"] or d < self.win_start):
                    continue
                if d.weekday() >= 5:
                    continue
                for sku in p["assort"]:
                    dm = p["demand"][sku]
                    pos = self._on_hand(p["bk"], sku, d) + self.inbound[(p["bk"], sku)]
                    if pos < max(1.0, dm * 7):
                        need = int(math.ceil(max(2, dm * 18) - pos))
                        if need > 0:
                            self._transfer(d, p["dc"], dc_off[p["dc"]], "pharmacy", p["bk"], p["off"], sku, need,
                                           d + timedelta(days=45), p["transit"])
            # 8. поставки, пришедшие в аптеки сегодня же (отгружены утром) - до продаж
            for loc, b, q in self.arrivals.pop(d, []):
                self._stock_add(loc, b, q)
                self.inbound[(loc, b["sku"])] -= q
            # 9. продажи и возвраты
            if d >= self.win_start:
                sold = defaultdict(int)
                for p in self.pharmacies:
                    if self.is_open(p, d):
                        self._sales_day(p, d, sold)
                for parent in self.refunds_due.pop(d, []):
                    self._refund(parent, d)
                # 10. порча в аптеке (22:30) и дневное списание продаж (23:59)
                for p in self.pharmacies:
                    if self.is_open(p, d) and r.random() < 0.01:
                        skus = [k for k, v in self.stock[p["bk"]].items() if v]
                        if skus:
                            sku = r.choice(sorted(skus))
                            for b, q in self._take_fefo(p["bk"], sku, 1, date.min, single_batch=True):
                                self._movement("writeoff", b, q, local_dt(d, 22, 30, p["off"]), "pharmacy",
                                               p["bk"], reason="damaged")
                for (ph, bbk), q in sorted(sold.items()):
                    p = self.ph_by_bk[ph]
                    self._movement("sale_writeoff", self.batch_index[bbk], q, local_dt(d, 23, 59, p["off"]),
                                   "pharmacy", ph, "customer", None)
            # 11. закрытие аптеки: остатки возвращаются в РЦ
            for p in self.pharmacies:
                if p["closed"] == d:
                    for sku in sorted(self.stock[p["bk"]]):
                        for item in self.stock[p["bk"]][sku]:
                            b, q = item
                            if q > 0:
                                disp = local_dt(d, 10, 0, p["off"])
                                moved = disp + timedelta(hours=p["transit"])
                                self._movement("transfer", b, q, moved, "pharmacy", p["bk"], "dc", p["dc"],
                                               dispatched=disp)
                                self.arrivals[local_date(moved, dc_off[p["dc"]]) + timedelta(days=1)].append((p["dc"], b, q))
                                item[1] = 0
            d += timedelta(days=1)

    # ------------------------------------------------------------------ sales
    def _shift(self, p, reg_i, d):
        key = (p["bk"], reg_i, d)
        if key not in self.shifts:
            reg = p["registers"][reg_i]
            cashier = p["cashiers"][(d.toordinal() + reg_i) % len(p["cashiers"])]
            self.shifts[key] = {"bk": f"SHF-{p['num']:04d}-{reg_i + 1:02d}-{d:%Y%m%d}", "register": reg,
                                "cashier": cashier, "opened": local_dt(d, 8, 0, p["off"]),
                                "closed": local_dt(d, 22, 0, p["off"])}
        return self.shifts[key]["bk"]

    def _receipt_bk(self, d):
        return f"RCPT-{d:%Y%m%d}-{self.next_no(('RCPT', d)):06d}"

    def _prescription(self, d):
        issued = d - timedelta(days=self.r.randint(0, 20))
        bk = f"RX-{d:%Y%m%d}-{self.next_no(('RX', d)):06d}"
        self.prescriptions.append((bk, issued, issued + timedelta(days=60)))
        return bk

    def _payments(self, total, customer):
        r = self.r
        if customer is not None and r.random() < 0.25 and total > 100:
            bonus = money(min(float(total) * 0.3, r.uniform(30, 500)))
            rest = total - bonus
            if rest > 0:
                return [("bonus", bonus), ("card", rest)]
        if r.random() < 0.03 and total > 600:
            cert = Decimal("500.00")
            return [("certificate", cert), ("card", total - cert)]
        return [("card" if r.random() < 0.66 else "cash", total)]

    def _sales_day(self, p, d, sold):
        r = self.r
        lam = self.base_rate * p["size"] * self.day_factor(d)
        n = self.poisson(lam)
        hours = list(HOUR_W)
        hw = [HOUR_W[h] for h in hours]
        times = sorted((r.choices(hours, hw)[0], r.randint(0, 59), r.randint(0, 59)) for _ in range(n))
        for h, m, sec in times:
            ts = local_dt(d, h, m, p["off"], sec)
            customer = self.pick_customer(p["region"], ts) if r.random() < CARD_SHARE else None
            k = min(8, 1 + self.poisson(2.0))
            chosen, lines = set(), []
            for _ in range(k * 3):
                if len(lines) >= k:
                    break
                sku = r.choices(p["assort"], p["assort_w"])[0]
                if sku in chosen:
                    continue
                chosen.add(sku)
                s = self.sku_by_bk[sku]
                want = 1 if s["cat"] in ("device", "cosmetics") else r.choices([1, 2, 3], [78, 16, 6])[0]
                taken = self._take_fefo(p["bk"], sku, want, d, single_batch=True)
                if not taken:
                    continue
                b, q = taken[0]
                price = self.price_at(sku, p, ts)
                disc = Decimal("0.00")
                if customer is not None:
                    disc = money(q * price * LEVEL_DISCOUNT[self.level_at(customer, ts)])
                is_rx = self.attr_at(s, "category", ts) == "rx"
                lines.append({"sku": sku, "batch": b["bk"], "qty": q, "price": price, "disc": disc,
                              "amount": money(q * price - disc), "rx": is_rx,
                              "name": self.attr_at(s, "sku_name", ts), "expiry": b["expiry"],
                              "rx_bk": self._prescription(d) if is_rx else None})
                sold[(p["bk"], b["bk"])] += q
            if not lines:
                continue
            total = sum(l["amount"] for l in lines)
            rc = {"bk": self._receipt_bk(d), "shift": self._shift(p, r.randrange(len(p["registers"])), d),
                  "customer": customer["bk"] if customer else None, "ts": ts, "type": "sale", "parent": None,
                  "total": total, "discount": sum(l["disc"] for l in lines), "lines": lines,
                  "payments": self._payments(total, customer), "ph": p["bk"]}
            self.receipts.append(rc)
            if r.random() < REFUND_P:
                rd = d + timedelta(days=r.randint(1, 10))
                if rd <= self.last_day and self.is_open(p, rd):
                    self.refunds_due[rd].append(rc)

    def _refund(self, parent, d):
        r = self.r
        p = self.ph_by_bk[parent["ph"]]
        src = parent["lines"] if r.random() < 0.3 else [r.choice(parent["lines"])]
        lines = []
        for l in src:
            q = r.randint(1, l["qty"])
            disc = money(l["disc"] * q / l["qty"])
            lines.append(dict(l, qty=q, disc=disc, amount=money(q * l["price"] - disc)))
        total = sum(l["amount"] for l in lines)
        method = "card" if any(m == "card" for m, _ in parent["payments"]) else "cash"
        ts = local_dt(d, r.randint(9, 20), r.randint(0, 59), p["off"], r.randint(0, 59))
        self.receipts.append({
            "bk": self._receipt_bk(d), "shift": self._shift(p, 0, d), "customer": parent["customer"],
            "ts": ts, "type": "refund", "parent": parent["bk"], "total": total,
            "discount": sum(l["disc"] for l in lines), "lines": lines, "payments": [(method, total)],
            "ph": p["bk"]})

    # ------------------------------------------------------------------ finalize
    def finalize(self):
        """Присвоить BK движениям в хронологическом порядке."""
        self.movements.sort(key=lambda m: (m["moved_at"], m["seq"]))
        for m in self.movements:
            dt = m["moved_at"].astimezone(tz(3))
            m["bk"] = f"MOV-{dt:%Y%m%d}-{self.next_no(('MOV', dt.date())):06d}"

    def run(self):
        t = _time.time()
        self.build_catalog()
        self.build_network()
        self.build_customers()
        self.build_prices()
        self.build_demand()
        self.simulate()
        self.finalize()
        log(f"simulated in {_time.time() - t:.1f}s: receipts={len(self.receipts)}, "
            f"lines={sum(len(x['lines']) for x in self.receipts)}, batches={len(self.batches)}, "
            f"purchase_lines={sum(len(p['lines']) for p in self.purchases)}, movements={len(self.movements)}")


# ===========================================================================
# загрузка
# ===========================================================================
def _enc(v):
    if v is None:
        return r"\N"
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, (datetime, date)):
        return v.isoformat()
    return str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def stage(cur, name, cols, rows):
    cur.execute(f"CREATE TEMP TABLE {name} ({', '.join(c + ' text' for c in cols)}) ON COMMIT DROP")
    buf = io.StringIO()
    for row in rows:
        buf.write("\t".join(_enc(v) for v in row))
        buf.write("\n")
    buf.seek(0)
    cur.copy_expert(f"COPY {name} FROM STDIN", buf)


def connect(db):
    return psycopg2.connect(host=os.environ.get("SEED_DB_HOST", "localhost"),
                            port=int(os.environ.get("SEED_DB_PORT", "5000")),
                            user=os.environ.get("SEED_DB_USER", "postgres"),
                            password=os.environ.get("SEED_DB_PASSWORD", "postgres"),
                            dbname=db)


def already_applied(cur, run_key, kind):
    cur.execute("SELECT run_key FROM ref.seed_log WHERE kind = %s", (kind,))
    keys = [r[0] for r in cur.fetchall()]
    if run_key in keys:
        return True
    if kind == "base" and keys:
        raise SystemExit(f"база уже заполнена другим запуском ({keys[0]}); "
                         f"для новой базовой загрузки: docker compose down -v && up")
    return False


def with_db(db, run_key, kind, seed, as_of, details, fn):
    conn = connect(db)
    try:
        with conn.cursor() as cur:
            cur.execute("SET TimeZone = 'UTC'")
            cur.execute("SET app.backfill = 'on'")      # исторические updated_at (ADR-0010)
            if already_applied(cur, run_key, kind):
                log(f"{db}: {run_key} уже применён - пропускаем")
                conn.rollback()
                return
            t = _time.time()
            fn(cur)
            cur.execute("INSERT INTO ref.seed_log (run_key, kind, seed, as_of, details) VALUES (%s,%s,%s,%s,%s)",
                        (run_key, kind, seed, as_of, details))
        conn.commit()           # deferred-проверки I3 / I12 выполняются здесь
        log(f"{db}: loaded in {_time.time() - t:.1f}s")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------- catalog
def load_catalog(sim: Sim):
    def fn(cur):
        cr = sim.warm_start - timedelta(days=2000)
        stage(cur, "s_mfr", ["bk", "name", "country"], sim.manufacturers)
        cur.execute("""INSERT INTO catalog.manufacturer (manufacturer_bk, manufacturer_name, country_code, created_at, updated_at)
                       SELECT bk, name, country, %s, %s FROM s_mfr ON CONFLICT DO NOTHING""", (cr, cr))
        stage(cur, "s_form", ["code", "name"], DRUG_FORMS)
        cur.execute("""INSERT INTO catalog.drug_form (form_code, form_name, created_at, updated_at)
                       SELECT code, name, %s, %s FROM s_form ON CONFLICT DO NOTHING""", (cr, cr))
        stage(cur, "s_inn", ["bk", "name"], [(i[0], i[1]) for i in sim.inns])
        cur.execute("""INSERT INTO catalog.inn (inn_bk, inn_name, created_at, updated_at)
                       SELECT bk, name, %s, %s FROM s_inn ON CONFLICT DO NOTHING""", (cr, cr))
        stage(cur, "s_sku", ["bk", "name", "mfr", "form", "cat", "vital", "cap", "pack", "ts"],
              [(s["bk"], s["name"], s["mfr"], s["form"], s["cat"], s["vital"], s["cap"], s["pack"], s["created"])
               for s in sim.skus])
        cur.execute("""
            INSERT INTO catalog.sku (sku_bk, sku_name, manufacturer_id, drug_form_id, category, is_vital,
                                     vital_max_price, pack_qty, created_at, updated_at)
            SELECT s.bk, s.name, m.manufacturer_id, f.drug_form_id, s.cat, s.vital::boolean,
                   s.cap::numeric, s.pack::numeric, s.ts::timestamptz, s.ts::timestamptz
              FROM s_sku s
              JOIN catalog.manufacturer m ON m.manufacturer_bk = s.mfr
              LEFT JOIN catalog.drug_form f ON f.form_code = s.form
            ON CONFLICT DO NOTHING""")
        stage(cur, "s_sku_inn", ["sku", "inn", "ts"],
              [(s["bk"], i, s["created"]) for s in sim.skus for i in s["inns"]])
        cur.execute("""INSERT INTO catalog.sku_inn (sku_id, inn_id, created_at, updated_at)
                       SELECT s.sku_id, i.inn_id, x.ts::timestamptz, x.ts::timestamptz FROM s_sku_inn x
                         JOIN catalog.sku s ON s.sku_bk = x.sku JOIN catalog.inn i ON i.inn_bk = x.inn
                       ON CONFLICT DO NOTHING""")
        stage(cur, "s_price", ["sku", "scope", "scope_bk", "price", "vf", "vt"], sim.prices)
        cur.execute("""INSERT INTO catalog.price (sku_id, price_scope, scope_bk, price, valid_from, valid_to,
                                                  created_at, updated_at)
                       SELECT s.sku_id, x.scope, x.scope_bk, x.price::numeric, x.vf::timestamptz, x.vt::timestamptz,
                              x.vf::timestamptz, coalesce(x.vt::timestamptz, x.vf::timestamptz)
                         FROM s_price x JOIN catalog.sku s ON s.sku_bk = x.sku
                       ON CONFLICT DO NOTHING""")
        # смена категории / названия - настоящими UPDATE: пишется sku_history
        for s in sim.skus:
            for ts, attr, val in s["events"]:
                cur.execute(f"UPDATE catalog.sku SET {attr} = %s, updated_at = %s "
                            f"WHERE sku_bk = %s AND {attr} IS DISTINCT FROM %s", (val, ts, s["bk"], val))
    return fn


# ---------------------------------------------------------------- crm
def load_crm(sim: Sim):
    def fn(cur):
        cs = sim.customers
        stage(cur, "s_cust", ["bk", "birth", "sex", "city", "region", "level", "reg"],
              [(c["bk"], c["birth"], c["sex"], c["city"], c["region"], c["level"], c["registered"]) for c in cs])
        cur.execute("""INSERT INTO crm.customer (customer_bk, birth_date, sex, city, region_code, loyalty_level,
                                                 registered_at, created_at, updated_at)
                       SELECT bk, birth::date, sex, city, region, level, reg::timestamptz, reg::timestamptz, reg::timestamptz
                         FROM s_cust ON CONFLICT DO NOTHING""")
        stage(cur, "s_pii", ["bk", "name", "phone", "email", "reg"],
              [(c["bk"], c["full_name"], c["phone"], c["email"], c["registered"]) for c in cs])
        cur.execute("""INSERT INTO crm.customer_pii (customer_id, full_name, phone, email, created_at, updated_at)
                       SELECT c.customer_id, x.name, x.phone, x.email, x.reg::timestamptz, x.reg::timestamptz
                         FROM s_pii x JOIN crm.customer c ON c.customer_bk = x.bk ON CONFLICT DO NOTHING""")
        stage(cur, "s_card", ["bk", "cust", "issued", "closed", "status", "balance"],
              [(k["bk"], c["bk"], k["issued"], k["closed"], k["status"], k["balance"]) for c in cs for k in c["cards"]])
        cur.execute("""INSERT INTO crm.loyalty_card (card_bk, customer_id, issued_at, closed_at, status, bonus_balance,
                                                     created_at, updated_at)
                       SELECT x.bk, c.customer_id, x.issued::timestamptz, x.closed::timestamptz, x.status,
                              x.balance::numeric, x.issued::timestamptz, coalesce(x.closed, x.issued)::timestamptz
                         FROM s_card x JOIN crm.customer c ON c.customer_bk = x.cust
                       ON CONFLICT DO NOTHING""")
        stage(cur, "s_cons", ["cust", "type", "granted", "revoked"],
              [(c["bk"], t, g, rv) for c in cs for t, g, rv in c["consents"]])
        cur.execute("""INSERT INTO crm.consent (customer_id, consent_type, granted_at, revoked_at, created_at, updated_at)
                       SELECT c.customer_id, x.type, x.granted::timestamptz, x.revoked::timestamptz,
                              x.granted::timestamptz, coalesce(x.revoked, x.granted)::timestamptz
                         FROM s_cons x JOIN crm.customer c ON c.customer_bk = x.cust""")
        # события во времени: повышение уровня, переезд, «забывание» (триггеры пишут историю и обезличивают)
        events = []
        for c in cs:
            for ts, a, v in c["events"]:
                events.append((ts, c["idx"], c["bk"], a, v))
            if c["forget"]:
                events.append((c["forget"], c["idx"], c["bk"], "forget", None))
        events.sort(key=lambda e: (e[0], e[1]))
        for ts, _, bk, a, v in events:
            if a == "loyalty_level":
                cur.execute("UPDATE crm.customer SET loyalty_level = %s, updated_at = %s WHERE customer_bk = %s",
                            (v, ts, bk))
            elif a == "move":
                cur.execute("UPDATE crm.customer SET region_code = %s, city = %s, updated_at = %s WHERE customer_bk = %s",
                            (v[0], v[1], ts, bk))
            else:
                cur.execute("UPDATE crm.customer SET deleted_at = %s, updated_at = %s "
                            "WHERE customer_bk = %s AND deleted_at IS NULL", (ts, ts, bk))
    return fn


# ---------------------------------------------------------------- wms
def load_wms(sim: Sim):
    def fn(cur):
        cr = sim.warm_start - timedelta(days=900)
        stage(cur, "s_sup", ["bk", "name", "country", "deleted"],
              [(s["bk"], s["name"], s["country"], s["deleted"]) for s in sim.suppliers])
        cur.execute("""INSERT INTO wms.supplier (supplier_bk, supplier_name, country_code, created_at, updated_at, deleted_at)
                       SELECT bk, name, country, %s, coalesce(deleted::timestamptz, %s), deleted::timestamptz
                         FROM s_sup ON CONFLICT DO NOTHING""", (cr, cr))
        stage(cur, "s_dc", ["bk", "name", "region", "city", "tz"],
              [(bk, v[0], v[1], v[2], DC_IANA[bk]) for bk, v in DCS.items()])
        cur.execute("""INSERT INTO wms.distribution_center (dc_bk, dc_name, region_code, city, timezone, created_at, updated_at)
                       SELECT bk, name, region, city, tz, %s, %s FROM s_dc ON CONFLICT DO NOTHING""", (cr, cr))
        cur.execute("""INSERT INTO wms.location (location_type, location_bk, dc_id, created_at, updated_at)
                       SELECT 'dc', dc_bk, dc_id, created_at, updated_at FROM wms.distribution_center
                       ON CONFLICT DO NOTHING""")
        stage(cur, "s_loc", ["bk", "ts"],
              [(p["bk"], datetime.combine(min(p["opened"], sim.warm_start) - timedelta(days=10), time(9), tzinfo=tz(3)))
               for p in sim.pharmacies])
        cur.execute("""INSERT INTO wms.location (location_type, location_bk, created_at, updated_at)
                       SELECT 'pharmacy', bk, ts::timestamptz, ts::timestamptz FROM s_loc ON CONFLICT DO NOTHING""")
        stage(cur, "s_batch", ["bk", "sku", "series", "mfd", "exp", "rcv"],
              [(b["bk"], b["sku"], b["series"], b["mfd"], b["expiry"], b["received"]) for b in sim.batches])
        cur.execute("""INSERT INTO wms.batch (batch_bk, sku_bk, series_no, manufactured_date, expiry_date, received_at,
                                              created_at, updated_at)
                       SELECT bk, sku, series, mfd::date, exp::date, rcv::timestamptz, rcv::timestamptz, rcv::timestamptz
                         FROM s_batch ON CONFLICT DO NOTHING""")
        stage(cur, "s_po", ["bk", "sup", "dc", "ordered"],
              [(p["bk"], p["supplier"], p["dc"], p["ordered"]) for p in sim.purchases])
        cur.execute("""INSERT INTO wms.purchase (purchase_bk, supplier_id, dc_id, ordered_at, created_at, updated_at)
                       SELECT x.bk, s.supplier_id, d.dc_id, x.ordered::timestamptz, x.ordered::timestamptz, x.ordered::timestamptz
                         FROM s_po x JOIN wms.supplier s ON s.supplier_bk = x.sup
                         JOIN wms.distribution_center d ON d.dc_bk = x.dc ON CONFLICT DO NOTHING""")
        stage(cur, "s_pl", ["po", "no", "sku", "qty", "cost", "batch", "rcv", "ordered"],
              [(p["bk"], l["no"], l["sku"], l["qty"], l["cost"], l["batch"], l["received"], p["ordered"])
               for p in sim.purchases for l in p["lines"]])
        cur.execute("""INSERT INTO wms.purchase_line (purchase_id, line_no, sku_bk, quantity, unit_cost, batch_id,
                                                      received_at, created_at, updated_at)
                       SELECT p.purchase_id, x.no::int, x.sku, x.qty::numeric, x.cost::numeric, b.batch_id,
                              x.rcv::timestamptz, x.ordered::timestamptz, coalesce(x.rcv, x.ordered)::timestamptz
                         FROM s_pl x JOIN wms.purchase p ON p.purchase_bk = x.po
                         LEFT JOIN wms.batch b ON b.batch_bk = x.batch ON CONFLICT DO NOTHING""")
        stage(cur, "s_mv", ["ord", "bk", "type", "batch", "src_type", "src", "sup", "dst_type", "dst", "qty",
                            "disp", "moved", "reason"],
              [(i, m["bk"], m["type"], m["batch"], m["src_type"], m["src"], m["supplier"], m["dst_type"], m["dst"],
                m["qty"], m["dispatched"], m["moved_at"], m["reason"]) for i, m in enumerate(sim.movements)])
        # порядок вставки = хронология: триггер пересчитывает остаток и не даёт ему уйти в минус
        cur.execute("""INSERT INTO wms.movement (movement_bk, movement_type, batch_id, src_type, src_location_id,
                                                 supplier_id, dst_type, dst_location_id, qty, dispatched_at, moved_at,
                                                 writeoff_reason, created_at, updated_at)
                       SELECT x.bk, x.type, b.batch_id, x.src_type, sl.location_id, s.supplier_id, x.dst_type,
                              dl.location_id, x.qty::numeric, x.disp::timestamptz, x.moved::timestamptz, x.reason,
                              x.moved::timestamptz, x.moved::timestamptz
                         FROM s_mv x
                         JOIN wms.batch b ON b.batch_bk = x.batch
                         LEFT JOIN wms.location sl ON sl.location_bk = x.src AND sl.location_type = x.src_type
                         LEFT JOIN wms.location dl ON dl.location_bk = x.dst AND dl.location_type = x.dst_type
                         LEFT JOIN wms.supplier s ON s.supplier_bk = x.sup
                        ORDER BY x.ord::int
                       ON CONFLICT DO NOTHING""")
    return fn


# ---------------------------------------------------------------- pos
def load_pos(sim: Sim):
    def fn(cur):
        cr = sim.warm_start - timedelta(days=900)
        ph = sim.pharmacies
        stage(cur, "s_ph", ["bk", "name", "region", "city", "addr", "tz", "opened", "closed"],
              [(p["bk"], p["name"], p["region"], p["city"], p["address"], p["iana"], p["opened"], p["closed"]) for p in ph])
        cur.execute("""INSERT INTO pos.pharmacy (pharmacy_bk, pharmacy_name, region_code, city, address, timezone,
                                                 opened_at, closed_at, created_at, updated_at)
                       SELECT bk, name, region, city, addr, tz, opened::date, closed::date,
                              least(opened::timestamptz, %s), coalesce(closed::timestamptz, least(opened::timestamptz, %s))
                         FROM s_ph ON CONFLICT DO NOTHING""", (cr, cr))
        stage(cur, "s_reg", ["bk", "ph"], [(rg, p["bk"]) for p in ph for rg in p["registers"]])
        cur.execute("""INSERT INTO pos.register (register_bk, pharmacy_id, created_at, updated_at)
                       SELECT x.bk, p.pharmacy_id, p.created_at, p.created_at FROM s_reg x
                         JOIN pos.pharmacy p ON p.pharmacy_bk = x.ph ON CONFLICT DO NOTHING""")
        stage(cur, "s_csh", ["bk", "ph"], [(c, p["bk"]) for p in ph for c in p["cashiers"]])
        cur.execute("""INSERT INTO pos.cashier (cashier_bk, pharmacy_id, created_at, updated_at)
                       SELECT x.bk, p.pharmacy_id, p.created_at, p.created_at FROM s_csh x
                         JOIN pos.pharmacy p ON p.pharmacy_bk = x.ph ON CONFLICT DO NOTHING""")
        load_pos_docs(cur, sim.shifts.values(), sim.prescriptions, sim.receipts)
        # «забытые» клиенты: ссылки в чеках обнуляются (ADR-0008)
        for c in sorted((c for c in sim.customers if c["forget"]), key=lambda c: c["forget"]):
            cur.execute("UPDATE pos.receipt SET customer_bk = NULL, updated_at = %s WHERE customer_bk = %s",
                        (c["forget"], c["bk"]))
    return fn


def load_pos_docs(cur, shifts, prescriptions, receipts):
    stage(cur, "s_shift", ["bk", "reg", "csh", "opened", "closed"],
          [(s["bk"], s["register"], s["cashier"], s["opened"], s["closed"]) for s in shifts])
    cur.execute("""INSERT INTO pos.shift (shift_bk, register_id, cashier_id, opened_at, closed_at, created_at, updated_at)
                   SELECT x.bk, g.register_id, c.cashier_id, x.opened::timestamptz, x.closed::timestamptz,
                          x.opened::timestamptz, x.closed::timestamptz
                     FROM s_shift x JOIN pos.register g ON g.register_bk = x.reg
                     JOIN pos.cashier c ON c.cashier_bk = x.csh ON CONFLICT DO NOTHING""")
    stage(cur, "s_rx", ["bk", "issued", "valid"], prescriptions)
    cur.execute("""INSERT INTO pos.prescription (prescription_bk, issued_at, valid_until, created_at, updated_at)
                   SELECT bk, issued::date, valid::date, issued::timestamptz, issued::timestamptz FROM s_rx
                   ON CONFLICT DO NOTHING""")
    stage(cur, "s_rcpt", ["ord", "bk", "shift", "cust", "ts", "type", "parent", "total", "disc"],
          [(i, x["bk"], x["shift"], x["customer"], x["ts"], x["type"], x["parent"], x["total"], x["discount"])
           for i, x in enumerate(receipts)])
    for doc_type in ("sale", "refund"):      # возвраты после продаж: им нужен родитель
        cur.execute("""INSERT INTO pos.receipt (receipt_bk, shift_id, customer_bk, receipt_dt, doc_type, parent_receipt_id,
                                                total_amount, discount_amount, created_at, updated_at)
                       SELECT x.bk, s.shift_id, x.cust, x.ts::timestamptz, x.type, pr.receipt_id,
                              x.total::numeric, x.disc::numeric, x.ts::timestamptz, x.ts::timestamptz
                         FROM s_rcpt x JOIN pos.shift s ON s.shift_bk = x.shift
                         LEFT JOIN pos.receipt pr ON pr.receipt_bk = x.parent
                        WHERE x.type = %s ORDER BY x.ord::int ON CONFLICT DO NOTHING""", (doc_type,))
    stage(cur, "s_line", ["ord", "rcpt", "type", "no", "sku", "batch", "qty", "price", "disc", "amount", "name", "rx",
                          "exp", "rx_bk", "ts"],
          [(i, x["bk"], x["type"], n, l["sku"], l["batch"], l["qty"], l["price"], l["disc"], l["amount"], l["name"],
            l["rx"], l["expiry"], l["rx_bk"], x["ts"])
           for i, x in enumerate(receipts) for n, l in enumerate(x["lines"], 1)])
    for doc_type in ("sale", "refund"):
        cur.execute("""INSERT INTO pos.receipt_line (receipt_id, line_no, sku_bk, batch_bk, quantity, unit_price,
                                                     line_discount, line_amount, sku_name_snapshot, is_rx_snapshot,
                                                     expiry_date_snapshot, prescription_id, created_at, updated_at)
                       SELECT r.receipt_id, x.no::int, x.sku, x.batch, x.qty::numeric, x.price::numeric,
                              x.disc::numeric, x.amount::numeric, x.name, x.rx::boolean, x.exp::date,
                              p.prescription_id, x.ts::timestamptz, x.ts::timestamptz
                         FROM s_line x JOIN pos.receipt r ON r.receipt_bk = x.rcpt
                         LEFT JOIN pos.prescription p ON p.prescription_bk = x.rx_bk
                        WHERE x.type = %s ORDER BY x.ord::int, x.no::int ON CONFLICT DO NOTHING""", (doc_type,))
    stage(cur, "s_pay", ["rcpt", "no", "method", "amount", "ts"],
          [(x["bk"], n, m, a, x["ts"]) for x in receipts for n, (m, a) in enumerate(x["payments"], 1)])
    cur.execute("""INSERT INTO pos.payment (receipt_id, payment_no, payment_method, amount, created_at, updated_at)
                   SELECT r.receipt_id, x.no::int, x.method, x.amount::numeric, x.ts::timestamptz, x.ts::timestamptz
                     FROM s_pay x JOIN pos.receipt r ON r.receipt_bk = x.rcpt ON CONFLICT DO NOTHING""")


# ===========================================================================
# догенерация (--receipts N): N продаж за день --as-of поверх текущего состояния баз
# ===========================================================================
def run_delta(seed: int, as_of: date, n: int):
    r = random.Random(seed)
    run_key = f"delta:seed={seed}:as_of={as_of}:receipts={n}"
    # 1. читаем текущее состояние источников - как это делала бы касса
    with connect("pos_service_db") as c, c.cursor() as cur:
        cur.execute("SELECT 1 FROM ref.seed_log WHERE run_key = %s", (run_key,))
        if cur.fetchone():
            log(f"{run_key} уже применён - пропускаем")
            return
        cur.execute("""SELECT p.pharmacy_bk, p.region_code, p.timezone, g.register_bk,
                              (SELECT min(c.cashier_bk) FROM pos.cashier c WHERE c.pharmacy_id = p.pharmacy_id)
                         FROM pos.pharmacy p JOIN pos.register g USING (pharmacy_id)
                        WHERE p.closed_at IS NULL AND p.deleted_at IS NULL AND p.opened_at <= %s
                        ORDER BY 1, 4""", (as_of,))
        regs = cur.fetchall()
    with connect("wms_service_db") as c, c.cursor() as cur:
        cur.execute("""SELECT l.location_bk, b.sku_bk, b.batch_bk, b.expiry_date, s.qty_on_hand
                         FROM wms.stock s JOIN wms.location l USING (location_id) JOIN wms.batch b USING (batch_id)
                        WHERE l.location_type = 'pharmacy' AND s.qty_on_hand > 0 AND b.expiry_date >= %s
                        ORDER BY 1, 2, b.expiry_date, 3""", (as_of,))
        stock = defaultdict(list)
        for ph, sku, bbk, exp, q in cur.fetchall():
            stock[ph].append([sku, bbk, exp, int(q)])
    with connect("catalog_service_db") as c, c.cursor() as cur:
        cur.execute("SELECT sku, sku_name, is_rx FROM contract.v_sku")
        skus = {s: (nm, rx) for s, nm, rx in cur.fetchall()}
        cur.execute("SELECT sku, price_scope, scope_bk, price FROM contract.v_price WHERE valid_to IS NULL")
        prices = {(s, sc, sb): p for s, sc, sb, p in cur.fetchall()}
    with connect("crm_service_db") as c, c.cursor() as cur:
        cur.execute("""SELECT c.customer_bk, c.loyalty_level FROM contract.v_customer c
                        WHERE EXISTS (SELECT 1 FROM contract.v_loyalty_card k
                                       WHERE k.customer_bk = c.customer_bk AND k.status = 'active')
                        ORDER BY 1""")
        customers = cur.fetchall()

    tz_off = {v[1]: v[0] for v in REGIONS.values()}       # IANA -> смещение UTC
    by_ph = defaultdict(list)
    for ph, reg, iana, rg, csh in regs:
        if stock.get(ph):
            by_ph[ph].append((reg, iana, rg, csh))
    phs = sorted(by_ph)
    block = 500000 + (seed % 400) * 1000       # свой диапазон номеров для каждой догенерации
    receipts, shifts, rxs, sold = [], {}, [], defaultdict(int)
    k = 0
    while len(receipts) < n and k < n * 5:
        k += 1
        ph = r.choice(phs)
        reg, iana, rg, csh = r.choice(by_ph[ph])
        off = tz_off[iana]
        ts = local_dt(as_of, r.randint(8, 21), r.randint(0, 59), off, r.randint(0, 59))
        sh_bk = f"SHF-{rg[4:8]}-{rg[9:11]}-{as_of:%Y%m%d}"
        shifts[sh_bk] = {"bk": sh_bk, "register": rg, "cashier": csh,
                         "opened": local_dt(as_of, 8, 0, off), "closed": local_dt(as_of, 22, 0, off)}
        cust = r.choice(customers) if customers and r.random() < CARD_SHARE else None
        lines = []
        for item in r.sample(stock[ph], min(len(stock[ph]), r.randint(1, 4))):
            sku, bbk, exp, have = item
            if have <= 0 or sku not in skus:
                continue
            price = prices.get((sku, "pharmacy", ph)) or prices.get((sku, "region", reg)) or prices.get((sku, "chain", "ALL"))
            if price is None:
                continue
            item[3] -= 1
            disc = money(price * LEVEL_DISCOUNT.get(cust[1], Decimal("0.02"))) if cust else Decimal("0.00")
            nm, rx = skus[sku]
            rx_bk = None
            if rx:
                rx_bk = f"RX-{as_of:%Y%m%d}-{block + len(rxs) + 1:06d}"
                rxs.append((rx_bk, as_of - timedelta(days=3), as_of + timedelta(days=57)))
            lines.append({"sku": sku, "batch": bbk, "qty": 1, "price": price, "disc": disc,
                          "amount": money(price - disc), "rx": rx, "name": nm, "expiry": exp, "rx_bk": rx_bk})
            sold[(ph, bbk, off)] += 1
        if not lines:
            continue
        total = sum(l["amount"] for l in lines)
        receipts.append({"bk": f"RCPT-{as_of:%Y%m%d}-{block + len(receipts) + 1:06d}", "shift": sh_bk,
                         "customer": cust[0] if cust else None, "ts": ts, "type": "sale", "parent": None,
                         "total": total, "discount": sum(l["disc"] for l in lines), "lines": lines,
                         "payments": [("card" if r.random() < 0.66 else "cash", total)]})

    def pos_fn(cur):
        load_pos_docs(cur, shifts.values(), rxs, receipts)

    def wms_fn(cur):
        rows = []
        for i, ((ph, bbk, off), q) in enumerate(sorted(sold.items())):
            rows.append((f"MOV-{as_of:%Y%m%d}-{block + i + 1:06d}", bbk, ph, q, local_dt(as_of, 23, 59, off)))
        stage(cur, "s_dmv", ["bk", "batch", "ph", "qty", "moved"], rows)
        cur.execute("""INSERT INTO wms.movement (movement_bk, movement_type, batch_id, src_type, src_location_id,
                                                 dst_type, qty, moved_at, created_at, updated_at)
                       SELECT x.bk, 'sale_writeoff', b.batch_id, 'pharmacy', l.location_id, 'customer',
                              x.qty::numeric, x.moved::timestamptz, x.moved::timestamptz, x.moved::timestamptz
                         FROM s_dmv x JOIN wms.batch b ON b.batch_bk = x.batch
                         JOIN wms.location l ON l.location_type = 'pharmacy' AND l.location_bk = x.ph
                       ON CONFLICT DO NOTHING""")

    details = f"receipts={len(receipts)}"
    with_db("pos_service_db", run_key, "delta", seed, as_of, details, pos_fn)
    with_db("wms_service_db", run_key, "delta", seed, as_of, details, wms_fn)
    log(f"delta: +{len(receipts)} receipts, +{sum(len(x['lines']) for x in receipts)} lines on {as_of}")


# ===========================================================================
def main():
    ap = argparse.ArgumentParser(description="генератор данных Аптека 108")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--as-of", type=date.fromisoformat, default=None,
                    help="«сегодня» генератора (по умолчанию - текущая дата по Москве)")
    ap.add_argument("--receipts", type=int, default=None,
                    help="режим догенерации: добавить N чеков за день --as-of")
    a = ap.parse_args()
    as_of = a.as_of or datetime.now(tz(3)).date()

    if a.receipts is not None:
        run_delta(a.seed, as_of, a.receipts)
        return

    run_key = f"base:seed={a.seed}:as_of={as_of}"
    dbs = ("catalog_service_db", "crm_service_db", "wms_service_db", "pos_service_db")
    pending = []
    for db in dbs:
        conn = connect(db)
        try:
            with conn.cursor() as cur:
                if not already_applied(cur, run_key, "base"):
                    pending.append(db)
        finally:
            conn.close()
    if not pending:
        log(f"{run_key} уже применён во всех базах - ничего не делаем")
        return
    sim = Sim(a.seed, as_of)
    sim.run()
    details = f"receipts={len(sim.receipts)} movements={len(sim.movements)}"
    # порядок: справочники-владельцы BK раньше потребителей (логически; FK между базами нет)
    for db, loader in (("catalog_service_db", load_catalog), ("crm_service_db", load_crm),
                       ("wms_service_db", load_wms), ("pos_service_db", load_pos)):
        with_db(db, run_key, "base", a.seed, as_of, details, loader(sim))
    log("done")


if __name__ == "__main__":
    main()
