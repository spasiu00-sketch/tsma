# -*- coding: utf-8 -*-
"""
Prognozy cen TSMA liczone po stronie Pythona (AuctionEngine ma dane 24/7, addon tylko gdy grasz).

Dane:   tabela snap(t, item, m, d, q) z history_forever_*.sqlite (min, mediana, ilosc co eksport).
Model:  zmiana log(min) za h = 6 / 24 / 72 godz. -> kwantyle p10 / p50 / p90.
        LightGBM (regresja kwantylowa), gdy zainstalowany; inaczej ridge + skalowane kwantyle reszt (tylko numpy).
Cechy:  zwroty 1/6/24 h, odchylenie od sredniej 7 d, zmiennosc 24 h, spread mediana/min, ilosc i jej zmiana 24 h,
        godzina i dzien tygodnia (sin/cos), rynek jako calosc (mediana zwrotow 6 h i 24 h wszystkich przedmiotow).
Ocena:  walk-forward (rosnace okno, odstep = horyzont), pinball loss vs bazowe kwantyle bezwarunkowe.
        Horyzont trafia do eksportu TYLKO gdy skill >= MIN_SKILL i pokrycie p10/p90 jest sensowne.
Wynik:  BlizzForecast.lua (TsmAnalizeForecast), czytany przez Forecast.lua.
Uzycie: python forecast.py [history_forever_*.sqlite]   -> raport + zapis forecast_out.lua obok bazy
"""
import math
import os
import sqlite3
import sys
import time

import numpy as np

HORIZONS = (6, 24, 72)
QS = (0.1, 0.5, 0.9)
MAXGAP = 3                 # ffill: maks. luka w godzinach
MIN_SKILL = 0.02
COV_OK = (0.05, 0.17)      # dopuszczalny odsetek obserwacji ponizej p10 / powyzej p90 (nominalnie 0.10)
RETRAIN_S = 6 * 3600
FEATS = ["r1", "r6", "r24", "dev7", "vol24", "sp", "lq", "dq24", "hs", "hc", "ds", "dc", "mk6", "mk24", "dsr", "evn", "evp"]

try:
    import lightgbm as lgb
except Exception:           # brak biblioteki: model zapasowy
    lgb = None


# ------------------------------------------------------------------ dane
def load_matrix(db_path, min_price=5000, max_items=800):
    """-> (ids, B0, LM, SP, LQ): macierze (przedmioty x godziny) log(min), log(mediana/min), log(1+ilosc); NaN = brak."""
    con = sqlite3.connect(db_path)
    try:
        rows = con.execute(
            "SELECT item,t,m,d,q FROM snap WHERE item IN (SELECT item FROM snap GROUP BY item "
            "HAVING AVG(m)>=? ORDER BY AVG(m) DESC LIMIT ?) AND m>0 ORDER BY item,t", (min_price, max_items)).fetchall()
    finally:
        con.close()
    if not rows:
        return [], 0, None, None, None
    a = np.array(rows, dtype=np.float64)
    b = (a[:, 1] // 3600).astype(np.int64)
    b0, b1 = int(b.min()), int(b.max())
    G = b1 - b0 + 1
    ids, start = np.unique(a[:, 0].astype(np.int64), return_index=True)
    n = len(ids)
    LM = np.full((n, G), np.nan)
    SP = np.full((n, G), np.nan)
    LQ = np.full((n, G), np.nan)
    bounds = list(start) + [len(a)]
    for k in range(n):
        s, e = bounds[k], bounds[k + 1]
        g = b[s:e] - b0                              # rosnace; pozniejszy punkt tej godziny nadpisuje
        m, d, q = a[s:e, 2], a[s:e, 3], a[s:e, 4]
        LM[k, g] = np.log(m)
        SP[k, g] = np.log(np.maximum(d, 1) / m)
        LQ[k, g] = np.log1p(np.maximum(q, 0))
    for M in (LM, SP, LQ):
        for k in range(n):
            M[k] = ffill(M[k], MAXGAP)
    return [int(i) for i in ids], b0, LM, SP, LQ


def ffill(x, limit):
    ok = ~np.isnan(x)
    ar = np.arange(len(x))
    idx = np.where(ok, ar, 0)
    np.maximum.accumulate(idx, out=idx)
    out = x[idx]
    out[(ar - idx) > limit] = np.nan
    out[:idx[ok].min() if ok.any() else len(x)] = np.nan
    return out


def sh(x, k):
    """sh(x,k)[g] = x[g-k] (k<0 = przyszlosc)."""
    out = np.full_like(x, np.nan)
    if k == 0:
        return x.copy()
    if k > 0:
        out[k:] = x[:-k]
    else:
        out[:k] = x[-k:]
    return out


def rollmean(x, w):
    ok = ~np.isnan(x)
    c = np.cumsum(np.where(ok, x, 0.0))
    n = np.cumsum(ok.astype(float))
    cs = c - sh(c, w)
    ns = n - sh(n, w)
    cs[:w] = c[:w]
    ns[:w] = n[:w]
    with np.errstate(invalid="ignore", divide="ignore"):
        out = cs / ns
    out[ns < max(3, w // 4)] = np.nan
    return out


def features(LM, SP, LQ, b0, reset_dow=3, events=()):
    """-> dict nazwa -> macierz (n x G). reset_dow: dzien resetu tygodnia (0=niedz..6; EU = sroda = 3);
    events: znaczniki czasu (UTC) patchy / nowej zawartosci -> cechy czasu do/od najblizszego zdarzenia (max 72 h)."""
    n, G = LM.shape
    t = (b0 + np.arange(G)) * 3600
    hour = (t // 3600) % 24
    dow = (t // 86400 + 4) % 7
    hs, hc = np.sin(2 * np.pi * hour / 24), np.cos(2 * np.pi * hour / 24)
    ds, dc = np.sin(2 * np.pi * dow / 7), np.cos(2 * np.pi * dow / 7)
    dsr = ((((t // 86400) + 4 - reset_dow) % 7) * 24 + hour) / 168.0     # czas od resetu tygodnia (0-1)
    evn = np.ones(G)
    evp = np.ones(G)
    ev = sorted(events or ())
    if ev:
        e = np.array(ev, dtype=np.float64)
        for g in range(G):
            nxt = e[e >= t[g]]
            prv = e[e < t[g]]
            evn[g] = min(72.0, (nxt[0] - t[g]) / 3600.0) / 72.0 if len(nxt) else 1.0
            evp[g] = min(72.0, (t[g] - prv[-1]) / 3600.0) / 72.0 if len(prv) else 1.0
    F = {k: np.full((n, G), np.nan) for k in FEATS}
    with np.errstate(all="ignore"):
        r6all = LM - np.array([sh(r, 6) for r in LM])
        r24all = LM - np.array([sh(r, 24) for r in LM])
        mk6 = np.nanmedian(r6all, axis=0)
        mk24 = np.nanmedian(r24all, axis=0)
    for i in range(n):
        lm = LM[i]
        r1 = lm - sh(lm, 1)
        F["r1"][i] = r1
        F["r6"][i] = r6all[i]
        F["r24"][i] = r24all[i]
        F["dev7"][i] = lm - rollmean(lm, 168)
        with np.errstate(all="ignore"):
            F["vol24"][i] = np.sqrt(rollmean(r1 * r1, 24))
        F["sp"][i] = SP[i]
        F["lq"][i] = LQ[i]
        F["dq24"][i] = LQ[i] - sh(LQ[i], 24)
        F["hs"][i], F["hc"][i], F["ds"][i], F["dc"][i] = hs, hc, ds, dc
        F["mk6"][i], F["mk24"][i] = mk6, mk24
        F["dsr"][i], F["evn"][i], F["evp"][i] = dsr, evn, evp
    return F


def stack(F, LM, h=None):
    """-> X (N x F), y (N) lub None, bucket (N), item (N), ze wszystkich komorek z kompletnymi cechami (i targetem)."""
    n, G = LM.shape
    X = np.stack([F[k] for k in FEATS], axis=-1)            # n x G x F
    ok = ~np.isnan(X).any(axis=-1)
    y = None
    if h is not None:
        Y = np.array([sh(LM[i], -h) for i in range(n)]) - LM
        ok &= ~np.isnan(Y)
        y = np.clip(Y[ok], -1.0, 1.0)
    ii, gg = np.nonzero(ok)
    return X[ok], y, gg, ii


# ------------------------------------------------------------------ modele
class Ridge:
    """Model zapasowy: ridge na sredniej + kwantyle reszt standaryzowanych zmiennoscia."""
    def __init__(self, h):
        self.h = h

    def _scale(self, X):
        return np.maximum(X[:, FEATS.index("vol24")] * math.sqrt(self.h), 0.01)

    def fit(self, X, y):
        self.mu, self.sd = X.mean(0), X.std(0) + 1e-9
        Z = np.hstack([np.ones((len(X), 1)), (X - self.mu) / self.sd])
        A = Z.T @ Z + 3.0 * np.eye(Z.shape[1])
        A[0, 0] -= 3.0
        self.w = np.linalg.solve(A, Z.T @ y)
        res = (y - Z @ self.w) / self._scale(X)
        self.zq = np.quantile(res, QS)
        return self

    def predict(self, X):
        Z = np.hstack([np.ones((len(X), 1)), (X - self.mu) / self.sd])
        mean = Z @ self.w
        s = self._scale(X)
        return np.sort(np.stack([mean + s * z for z in self.zq], axis=1), axis=1)


class GBM:
    def __init__(self, h):
        self.h = h

    def fit(self, X, y):
        self.m = [lgb.LGBMRegressor(objective="quantile", alpha=q, n_estimators=250, learning_rate=0.04,
                                    num_leaves=31, min_child_samples=200, subsample=0.8, subsample_freq=1,
                                    colsample_bytree=0.8, verbose=-1).fit(X, y) for q in QS]
        return self

    def predict(self, X):
        return np.sort(np.stack([m.predict(X) for m in self.m], axis=1), axis=1)


def make(h, backend=None):
    use = backend or ("gbm" if lgb is not None else "ridge")
    return (GBM if use == "gbm" else Ridge)(h)


def pinball(y, P):
    return float(np.mean([np.mean(np.maximum(q * (y - P[:, k]), (q - 1) * (y - P[:, k]))) for k, q in enumerate(QS)]))


def walk_forward(X, y, bucket, h, backend=None, cuts=(0.55, 0.7, 0.85, 1.0)):
    """-> {skill, cov_lo, cov_hi, mae_gain, n, folds}. Odstep treningu od testu = h godzin (bez przecieku)."""
    lo_b, hi_b = bucket.min(), bucket.max()
    span = hi_b - lo_b + 1
    edges = [lo_b + int(span * c) for c in (0.0,) + tuple(cuts)]
    sk, cl, ch, mg, n = [], [], [], [], 0
    for f in range(1, len(edges) - 1):
        tr = bucket < edges[f] - h
        te = (bucket >= edges[f]) & (bucket < edges[f + 1] + (1 if f == len(edges) - 2 else 0))
        if tr.sum() < 500 or te.sum() < 200:
            continue
        mdl = make(h, backend).fit(X[tr], y[tr])
        P = mdl.predict(X[te])
        base = np.tile(np.quantile(y[tr], QS), (te.sum(), 1))
        lm, lb = pinball(y[te], P), pinball(y[te], base)
        sk.append((1 - lm / lb) * te.sum())
        cl.append(float(np.mean(y[te] < P[:, 0])) * te.sum())
        ch.append(float(np.mean(y[te] > P[:, 2])) * te.sum())
        mg.append((float(np.mean(np.abs(y[te]))) - float(np.mean(np.abs(y[te] - P[:, 1])))) * te.sum())
        n += te.sum()
    if n == 0:
        return None
    return {"skill": sum(sk) / n, "cov_lo": sum(cl) / n, "cov_hi": sum(ch) / n, "mae_gain": sum(mg) / n, "n": int(n),
            "folds": len(sk)}


# ------------------------------------------------------------------ pipeline
_CACHE = {"t": 0, "models": {}, "eval": {}, "backend": None}


def run(db_path, now=None, min_price=5000, max_items=800, force=False, backend=None, log=None, reset_dow=3, events=()):
    """-> (tekst Lua, linie raportu). Modele sa trenowane co RETRAIN_S, predykcje liczone przy kazdym wywolaniu."""
    now = now or int(time.time())
    say = log or (lambda s: None)
    rep = []
    ids, b0, LM, SP, LQ = load_matrix(db_path, min_price, max_items)
    if not ids or LM.shape[1] < 24 * 4:
        rep.append("Prognoza: za malo historii (potrzeba >= 4 dni; ustaw history_days 21-30).")
        return lua({}, {}, now), rep
    F = features(LM, SP, LQ, b0, reset_dow, events)
    use = backend or ("gbm" if lgb is not None else "ridge")
    if force or now - _CACHE["t"] > RETRAIN_S or _CACHE["backend"] != use:
        _CACHE.update(models={}, eval={}, backend=use, t=now)
        for h in HORIZONS:
            X, y, g, _ = stack(F, LM, h)
            if len(y) < 1500:
                rep.append("h=%dh: za malo probek (%d)" % (h, len(y)))
                continue
            ev = walk_forward(X, y, g, h, use)
            _CACHE["eval"][h] = ev
            if ev:
                _CACHE["models"][h] = make(h, use).fit(X, y)
            say("Prognoza h=%d: %s" % (h, ev))
    skill = {}
    rep.append("== PROGNOZA CENY (backend: %s, %d przedmiotow, %d godz.) ==" % (use, len(ids), LM.shape[1]))
    for h in HORIZONS:
        ev = _CACHE["eval"].get(h)
        if not ev:
            continue
        ok = ev["skill"] >= MIN_SKILL and COV_OK[0] <= ev["cov_lo"] <= COV_OK[1] and COV_OK[0] <= ev["cov_hi"] <= COV_OK[1]
        rep.append("h=%2dh: skill %+.1f%% vs bazowy, p10 pokrycie %.1f%%, p90 %.1f%%, zysk MAE %.2f pp, n=%d -> %s" % (
            h, ev["skill"] * 100, ev["cov_lo"] * 100, ev["cov_hi"] * 100, ev["mae_gain"] * 100, ev["n"],
            "EKSPORT" if ok else "POMINIETY (brak przewagi albo zla kalibracja)"))
        if ok:
            skill[h] = ev["skill"]
    preds = {}
    G = LM.shape[1]
    if skill:
        X, _, g, ii = stack(F, LM, None)
        last = g == G - 1                               # tylko przedmioty z aktualnym pomiarem
        X, ii = X[last], ii[last]
        for h in skill:
            P = _CACHE["models"][h].predict(X)
            for k, i in enumerate(ii):
                preds.setdefault(ids[i], {})[h] = [round((math.exp(max(-3, min(3, z))) - 1) * 100, 1) for z in P[k]]
    rep.append("Eksport: %d przedmiotow, horyzonty %s" % (len(preds), sorted(skill) or "brak"))
    return lua(preds, skill, now), rep


def lua(preds, skill, now):
    L = ["TsmAnalizeForecast = { generated = %d, skill = {%s}, items = {" % (
        now, ",".join("[%d]=%.3f" % (h, s) for h, s in sorted(skill.items())))]
    for iid in sorted(preds):
        L.append('["i:%d"]={%s},' % (iid, ",".join("f%d={%s}" % (h, ",".join("%.1f" % v for v in p))
                                                    for h, p in sorted(preds[iid].items()))))
    L.append("} }")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    import glob
    if len(sys.argv) > 1:
        db = sys.argv[1]
    else:
        d = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "AuctionEngine")
        fs = sorted(glob.glob(os.path.join(d, "history_forever_*.sqlite")), key=os.path.getmtime)
        if not fs:
            sys.exit("Brak bazy historii")
        db = fs[-1]
    text, rep = run(db, force=True, log=print)
    print("\n".join(rep))
    out = os.path.join(os.path.dirname(os.path.abspath(db)), "forecast_out.lua")
    open(out, "w", encoding="utf-8", newline="\n").write(text)
    print("Zapisano", out)
