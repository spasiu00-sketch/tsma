# -*- coding: utf-8 -*-
"""
Przeplyw rynku i backtest modeli ryzyka TSMA (bez sieci i GUI).

1) PRZEPLYW: aukcje maja ID. Miedzy dwoma kolejnymi pobraniami (odstep <= 6 h):
     * aukcja zniknela            -> zejscie calej ilosci
     * ilosc spadla (commodities) -> zejscie roznicy
   Zejscia policzone jako "przy minimum" (cena <= 1.25 x min poprzedniego pobrania) i bez aukcji, ktore znikly
   ze statusem SHORT (prawdopodobnie wygasly) przyblizaja SPRZEDAZ; pozostale (wysoka cena) to raczej anulowania.
   To estymata, nie fakt: anulowanie przy minimum jest nieodroznialne od sprzedazy.
   Z dobowych sum (dni z pokryciem >= 75%) liczymy srednia (fl, szt./dobe) i dyspersje (fd): Var = mu + fd * mu^2.
2) BACKTEST (run_backtest):
   a) cena: dla kazdego przedmiotu i dnia z historii dobowej (tabela daily) przewidujemy kwantyle zmiany h-dobowej tym
      samym modelem co Risk.lua (EWMA sigma, AR(1), kwantyle empiryczne), liczymy pokrycie kwantyli 5% / 95% i skale zs
      (zs > 1: model zanizal ryzyko) -> BlizzData.lua: calib.zs
   b) przeplyw: prognoza sum 2-dobowych z sredniej z poprzednich dni, dopasowanie dyspersji NB (max log-wiarygodnosci)
      i kontrola pokrycia przedzialu 80% (PIT) -> calib.disp
"""
import math
import random
import sqlite3
import statistics

GAP_MAX = 6 * 3600          # dluzsza przerwa miedzy pobraniami: nie liczymy zejsc z tego odcinka
NEAR = 1.25                 # "przy minimum": cena <= NEAR x min poprzedniego pobrania
KEEP_DAYS = 30              # retencja zejsc i uruchomien
DAILY_KEEP = 120            # retencja zamkniec dobowych (do backtestu)
ZQ_N = 16
EMP_MIN = 25
ND = statistics.NormalDist()


def unit_price(a):
    if a.get("unit_price"):
        u = a["unit_price"]
    else:
        b = a.get("buyout") or 0
        if b <= 0:
            return None
        u = b / (a.get("quantity", 1) or 1)
    u = int(round(u))
    return u if u > 0 else None


def _con(db_path):
    con = sqlite3.connect(db_path)
    con.execute("CREATE TABLE IF NOT EXISTS live(id INTEGER PRIMARY KEY, item INTEGER, qty INTEGER, unit INTEGER, tl TEXT)")
    con.execute("CREATE TABLE IF NOT EXISTS gone(t INTEGER, item INTEGER, qty INTEGER, near INTEGER)")
    con.execute("CREATE INDEX IF NOT EXISTS ix_gone ON gone(item, t)")
    con.execute("CREATE TABLE IF NOT EXISTS runs(t INTEGER PRIMARY KEY, cov INTEGER)")
    con.execute("CREATE TABLE IF NOT EXISTS daily(item INTEGER, day INTEGER, close INTEGER, PRIMARY KEY(item, day))")
    return con


# ---------------------------------------------------------------- przeplyw
def update_flow(db_path, auctions, now, days=7, log=None, agg=None, store_min=0):
    """Aktualizuje stan, zapisuje zejscia i zamkniecia dobowe. Zwraca {"days": n, "items": {iid: {fl, fk, fd?}}}."""
    cur = {}
    for a in auctions:
        aid = a.get("id")
        iid = (a.get("item") or {}).get("id")
        if aid is None or not iid:
            continue
        u = unit_price(a)
        if not u:
            continue
        cur[aid] = (iid, int(a.get("quantity", 1) or 1), u, str(a.get("time_left", "") or ""))
    if not cur:
        if log:
            log("Przeplyw: aukcje nie maja pola 'id' - pomijam sledzenie zejsc.")
        return {"days": 0, "items": {}}

    con = _con(db_path)
    try:
        prev = {r[0]: r[1:] for r in con.execute("SELECT id, item, qty, unit, tl FROM live")}
        last_run = con.execute("SELECT MAX(t) FROM runs").fetchone()[0]
        covered = bool(prev) and last_run is not None and 0 < now - last_run <= GAP_MAX
        n_gone = 0
        if covered:
            mins = {}
            for iid, q, u, tl in prev.values():
                m = mins.get(iid)
                mins[iid] = u if m is None or u < m else m
            rows = []
            for aid, (iid, q, u, tl) in prev.items():
                c = cur.get(aid)
                lost = q if c is None else max(0, q - c[1])
                if lost <= 0:
                    continue
                if c is None and tl.upper() == "SHORT":
                    continue                        # prawdopodobnie wygasla
                rows.append((now, iid, lost, 1 if u <= NEAR * mins[iid] else 0))
            con.executemany("INSERT INTO gone VALUES(?,?,?,?)", rows)
            n_gone = len(rows)
        con.execute("DELETE FROM live")
        con.executemany("INSERT INTO live VALUES(?,?,?,?,?)",
                        [(aid, v[0], v[1], v[2], v[3]) for aid, v in cur.items()])
        con.execute("INSERT OR REPLACE INTO runs VALUES(?,?)", (now, 1 if covered else 0))
        if agg:
            day = now // 86400
            con.executemany("INSERT OR REPLACE INTO daily VALUES(?,?,?)",
                            [(i, day, m) for i, (m, d, q) in agg.items() if m >= store_min])
        con.execute("DELETE FROM gone WHERE t < ?", (now - KEEP_DAYS * 86400,))
        con.execute("DELETE FROM runs WHERE t < ?", (now - KEEP_DAYS * 86400,))
        con.execute("DELETE FROM daily WHERE day < ?", (now // 86400 - DAILY_KEEP,))
        con.commit()
        res = flow_stats(con, now, days)
        if log:
            log("Przeplyw: %s, zejsc zapisanych %d, dni z pokryciem w oknie: %d." %
                ("odcinek pokryty" if covered else "pierwsze pobranie / przerwa > 6 h (bez zejsc)", n_gone, res["days"]))
        return res
    finally:
        con.close()


def _coverage(con, since):
    """{dzien: sekundy pokrycia} tylko dla dni z pokryciem >= 75%."""
    cov, prev_t = {}, None
    for t, c in con.execute("SELECT t, cov FROM runs ORDER BY t"):
        if c and prev_t is not None:
            a, b = max(prev_t, since), t
            while a < b:
                d = int(a // 86400)
                end = min(b, (d + 1) * 86400)
                cov[d] = cov.get(d, 0) + (end - a)
                a = end
        prev_t = t
    return {d: s for d, s in cov.items() if s >= 0.75 * 86400}


def _counts(con, since, full):
    cnt = {}
    for iid, t, q in con.execute("SELECT item, t, qty FROM gone WHERE t >= ? AND near = 1", (since,)):
        d = int(t // 86400)
        if d in full:
            dd = cnt.setdefault(iid, {})
            dd[d] = dd.get(d, 0) + q
    return cnt


def flow_stats(con, now, days=7):
    since = now - days * 86400
    full = _coverage(con, since)
    full = {d: s for d, s in full.items() if d * 86400 + 86400 > since}
    nd = len(full)
    out = {}
    if nd >= 2:
        ds = sorted(full)
        for iid, dd in _counts(con, since, full).items():
            xs = [dd.get(d, 0) / (full[d] / 86400.0) for d in ds]
            mean = sum(xs) / nd
            e = {"fl": mean, "fk": nd}
            if nd >= 5 and mean > 0:
                var = sum((x - mean) ** 2 for x in xs) / (nd - 1)
                e["fd"] = max(0.0, min(3.0, (var - mean) / (mean * mean)))
            out[iid] = e
    return {"days": nd, "items": out}


# ---------------------------------------------------------------- rozklad NB
def nb_logpmf(y, mu, phi):
    if mu <= 0:
        return 0.0 if y == 0 else -1e9
    if phi < 0.01:
        return y * math.log(mu) - mu - math.lgamma(y + 1)
    r = 1.0 / phi
    return (math.lgamma(y + r) - math.lgamma(r) - math.lgamma(y + 1)
            + r * math.log(r / (r + mu)) + y * math.log(mu / (r + mu)))


def nb_pit(y, mu, phi):
    """Srodkowy PIT: P(N<y) + 0.5 P(N=y)."""
    if mu > 200 or y > 400:
        var = mu * (1 + phi * mu)
        return ND.cdf((y - mu) / math.sqrt(max(var, 1e-9)))
    cdf = 0.0
    for k in range(0, y):
        cdf += math.exp(nb_logpmf(k, mu, phi))
    return min(1.0, cdf + 0.5 * math.exp(nb_logpmf(y, mu, phi)))


def best_disp(samples, grid=None):
    grid = grid or [i * 0.05 for i in range(0, 61)]
    best, bl = 0.0, None
    for phi in grid:
        ll = sum(nb_logpmf(y, mu, phi) for y, mu in samples)
        if bl is None or ll > bl:
            best, bl = phi, ll
    return best


def backtest_flow(con, now):
    since = now - KEEP_DAYS * 86400
    full = _coverage(con, since)
    ds = sorted(full)
    samples = []
    for iid, dd in _counts(con, since, full).items():
        xs = {d: dd.get(d, 0) / (full[d] / 86400.0) for d in ds}
        for i in range(len(ds) - 1):
            d0, d1 = ds[i], ds[i + 1]
            if d1 != d0 + 1:
                continue
            prior = [xs[d] for d in ds if d0 - 7 <= d < d0]
            if len(prior) < 4:
                continue
            mu = 2 * sum(prior) / len(prior)
            if mu < 0.5:
                continue
            samples.append((int(round(xs[d0] + xs[d1])), mu))
    return samples


# ---------------------------------------------------------------- model ceny (zgodny z Risk.lua)
def _q(sorted_list, p):
    n = len(sorted_list)
    pos = max(0.0, min(1.0, p)) * (n - 1)
    lo = int(math.floor(pos))
    hi = min(n - 1, lo + 1)
    return sorted_list[lo] + (sorted_list[hi] - sorted_list[lo]) * (pos - lo)


def price_quantiles(byday, h, floor_day=0.02, fallback_sig=None, zs=1.0):
    """byday: {dzien: zamkniecie}. Zwraca (zq[16], sigma_h): kwantyle zmiany log-ceny w h dni, E[exp(z)] = 1."""
    days = sorted(byday)
    rets = []
    for a, b in zip(days, days[1:]):
        gap = b - a
        if 1 <= gap <= 3:
            rets.append(math.log(byday[b] / byday[a]) / math.sqrt(gap))
    sig = None
    if len(rets) >= 6:
        m = statistics.median(rets)
        mad = 1.4826 * statistics.median([abs(r - m) for r in rets])
        sig = mad
        if len(rets) >= 10:
            clip = 4 * mad if mad > 0 else float("inf")
            cl = [max(-clip, min(clip, r)) for r in rets]
            n0 = min(10, len(cl))
            var = sum(c * c for c in cl[:n0]) / n0
            for c in cl:
                var = 0.94 * var + 0.06 * c * c
            sig = math.sqrt(var)
    if sig is None and fallback_sig:
        sig = fallback_sig
    phi = None
    if len(days) >= 16:
        ys = [math.log(byday[d]) for d in days]
        mu = statistics.median(ys)
        num = den = 0.0
        pairs = 0
        for i in range(1, len(days)):
            if days[i] - days[i - 1] == 1:
                a, b = ys[i - 1] - mu, ys[i] - mu
                num, den, pairs = num + a * b, den + a * a, pairs + 1
        if pairs >= 15 and den > 0:
            phi = max(0.05, min(0.995, num / den))
    vf = h if (not phi or phi >= 0.999) else (1 - phi ** h) / (1 - phi)
    sig_model = sig * math.sqrt(vf) if sig is not None else None
    floor_h = floor_day * math.sqrt(h)
    emp = sorted(math.log(byday[d + h] / byday[d]) for d in days if (d + h) in byday)
    sig_emp = (_q(emp, 0.8413) - _q(emp, 0.1587)) / 2 if len(emp) >= EMP_MIN else None
    if sig_emp is not None and sig_emp >= floor_h:
        med = _q(emp, 0.5)
        zq = [_q(emp, (i + 0.5) / ZQ_N) - med for i in range(ZQ_N)]
        sig_h = sig_emp
    else:
        sig_h = max(sig_model or 0.0, floor_h)
        zq = [sig_h * ND.inv_cdf((i + 0.5) / ZQ_N) for i in range(ZQ_N)]
    if zs != 1.0:
        zq = [z * zs for z in zq]
        sig_h *= zs
    shift = math.log(sum(math.exp(z) for z in zq) / ZQ_N)
    return [z - shift for z in zq], sig_h


def _interp(zq, p):
    pts = [(i + 0.5) / len(zq) for i in range(len(zq))]
    if p <= pts[0]:
        return zq[0]
    if p >= pts[-1]:
        return zq[-1]
    for i in range(1, len(pts)):
        if p <= pts[i]:
            f = (p - pts[i - 1]) / (pts[i] - pts[i - 1])
            return zq[i - 1] + f * (zq[i] - zq[i - 1])
    return zq[-1]


def backtest_price(con, hs=(1, 2, 3), max_items=400, seed=1, min_train=20):
    byitem = {}
    for iid, day, close in con.execute("SELECT item, day, close FROM daily ORDER BY item, day"):
        byitem.setdefault(iid, {})[day] = close
    ids = [i for i, d in byitem.items() if len(d) >= min_train + max(hs) + 3]
    random.Random(seed).shuffle(ids)
    recs = []                                   # (h, z, sigma_h, q05, q95)
    for iid in ids[:max_items]:
        full = byitem[iid]
        days = sorted(full)
        for idx in range(min_train - 1, len(days)):
            d0 = days[idx]
            train = {d: full[d] for d in days[max(0, idx - 59):idx + 1]}
            for h in hs:
                if (d0 + h) not in full:
                    continue
                zq, sig = price_quantiles(train, h)
                z = math.log(full[d0 + h] / full[d0])
                recs.append((h, z, sig, _interp(zq, 0.05), _interp(zq, 0.95)))
    return recs, len(ids)


def run_backtest(db_path, max_items=400, now=None):
    """-> (calib dict, lista linii raportu)."""
    import time
    now = now or int(time.time())
    con = _con(db_path)
    rep, calib = [], {"generated": now}
    try:
        recs, n_items = backtest_price(con, max_items=max_items)
        ndays = con.execute("SELECT COUNT(DISTINCT day) FROM daily").fetchone()[0]
        rep.append("== CENA (kwantyle zmiany h-dobowej) ==")
        if len(recs) < 100:
            rep.append("Za malo danych: %d prognoz (dni w historii dobowej: %d, potrzeba ok. 30+; %d przedmiotow z dosc dluga seria)."
                       % (len(recs), ndays, n_items))
        else:
            for h in sorted({r[0] for r in recs}):
                rr = [r for r in recs if r[0] == h]
                lo = sum(1 for r in rr if r[1] < r[3]) / len(rr)
                hi = sum(1 for r in rr if r[1] > r[4]) / len(rr)
                rep.append("h=%d d: n=%d, spadek poza kwantylem 5%%: %.1f%% (cel 5), wzrost poza 95%%: %.1f%% (cel 5)"
                           % (h, len(rr), lo * 100, hi * 100))
            u = sorted(r[1] / r[2] for r in recs if r[2] > 0)
            s_lo = -_q(u, 0.05) / 1.645
            s_hi = _q(u, 0.95) / 1.645
            zs = max(0.7, min(2.0, s_lo))
            rep.append("Skala dolnego ogona: %.2f, gornego: %.2f -> zs = %.2f (zs > 1: model zanizal ryzyko spadku)"
                       % (s_lo, s_hi, zs))
            calib["zs"], calib["n_price"] = round(zs, 3), len(recs)
        samples = backtest_flow(con, now)
        rep.append("== PRZEPLYW (sumy 2-dobowe vs srednia z poprzednich dni) ==")
        if len(samples) < 50:
            rep.append("Za malo danych: %d prognoz (potrzeba kilku dni ciaglego auto-odswiezania)." % len(samples))
        else:
            phi = best_disp(samples)
            for name, ph in (("Poisson", 0.0), ("NB dopasowany", phi)):
                pit = [nb_pit(y, mu, ph) for y, mu in samples[:3000]]
                cov = sum(1 for p in pit if 0.1 <= p <= 0.9) / len(pit)
                rep.append("%s (dyspersja %.2f): pokrycie przedzialu 80%%: %.0f%%" % (name, ph, cov * 100))
            rep.append("Najlepsza dyspersja (max wiarygodnosci): %.2f (n=%d) -> calib.disp" % (phi, len(samples)))
            calib["disp"], calib["n_flow"] = round(phi, 2), len(samples)
    finally:
        con.close()
    return calib, rep
