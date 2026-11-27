"""Testy forecast.py i engine_ext.py: pytest tests"""
import math, os, random, sqlite3, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import numpy as np
import forecast
import engine_ext as ext


def make_db(path, n_items=60, days=21, seed=3):
    rnd = np.random.default_rng(seed)
    steps = days * 48
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE snap(t INTEGER, item INTEGER, m INTEGER, d INTEGER, q INTEGER)")
    mk = np.zeros(steps)
    for t in range(1, steps):
        mk[t] = 0.995 * mk[t - 1] + rnd.normal(0, 0.004)
    t0 = 1_800_000_000 // 3600 * 3600
    rows = []
    for it in range(n_items):
        x = 0.0
        base = 20000 + it * 700
        for t in range(steps):
            x = 0.985 * x + rnd.normal(0, 0.012)           # powrot do sredniej (godzinowy ~ pol-godzinowy)
            hour = ((t // 2) % 24)
            lp = math.log(base) + x + mk[t] + 0.02 * math.sin(2 * math.pi * hour / 24)
            m = int(math.exp(lp))
            rows.append((t0 + t * 1800, 1000 + it, m, int(m * 1.05), int(50 + rnd.integers(0, 20))))
    con.executemany("INSERT INTO snap VALUES(?,?,?,?,?)", rows)
    con.commit(); con.close()
    return t0 + steps * 1800


def test_forecast_beats_baseline(tmp_path):
    db = str(tmp_path / "h.sqlite")
    now = make_db(db)
    text, rep = forecast.run(db, now=now, backend="ridge", force=True)
    assert text.startswith("TsmAnalizeForecast")
    assert any("EKSPORT" in l for l in rep), rep
    assert '["i:1000"]={f' in text


def test_forecast_too_little_data(tmp_path):
    db = str(tmp_path / "h.sqlite")
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE snap(t INTEGER, item INTEGER, m INTEGER, d INTEGER, q INTEGER)")
    con.execute("INSERT INTO snap VALUES(1800000000,1,20000,21000,5)")
    con.commit(); con.close()
    text, rep = forecast.run(db, now=1800000100, force=True)
    assert "za malo" in rep[0]


def A(aid, item, qty, unit):
    return {"id": aid, "item": {"id": item}, "quantity": qty, "unit_price": unit}


def test_ladder_and_cost():
    lad = ext.house_ladder([A(1, 5, 3, 100), A(2, 5, 2, 100), A(3, 5, 4, 150)], levels=5)
    assert lad[5] == [(100, 5), (150, 4)]
    cost, filled = ext.ladder_cost(lad[5], 7)
    assert filled == 7 and cost == 5 * 100 + 2 * 150


def test_arbitrage_needs_neutral_and_nets_fee():
    cheap = {5: [(10000, 10), (12000, 10)]}
    dear = {5: [(20000, 3)]}
    houses = {113: {"name": "Horde", "cut": 5.0, "neutral": False, "lad": cheap},
              114: {"name": "Alliance", "cut": 5.0, "neutral": False, "lad": dear},
              116: {"name": "Neutral", "cut": 15.0, "neutral": True, "lad": dear}}
    rows = ext.arbitrage(houses, min_profit=0, max_units=15, haircut=0.0, margin_pct=5)
    assert rows and all(r["buyAH"] == 113 and r["sellAH"] == 116 for r in rows)   # Horde<->Alliance niemozliwe
    r = rows[0]
    assert r["qty"] == 15 and abs(r["sell"] - 20000) < 1
    # 15 szt.: 10 po 10000 + 5 po 12000; sprzedaz 20000*0.85 = 17000 -> marginalna 12000 nadal oplacalna
    assert r["profit"] == 15 * 17000 - (10 * 10000 + 5 * 12000)


def test_snipes():
    entries = {5: {"m": 10000, "d": 20000, "q": 5, "h": 20000.0, "n": 10}}
    auctions = [A(1, 5, 2, 10000), A(2, 5, 1, 19000)]
    out = ext.find_snipes({2}, auctions, entries, cut=5.0, thr=0.25, min_profit=0)
    assert [r["s"] for r in out] == ["i:5"] and out[0]["qty"] == 2
    assert ext.find_snipes(set(), auctions, entries, cut=5.0) == []     # pierwszy eksport: brak punktu odniesienia


def test_events_and_reset_features(tmp_path):
    db = str(tmp_path / "h.sqlite")
    now = make_db(db, n_items=20, days=10)
    ev = ext.parse_events("2026-01-15, zle, 2026-01-17")
    assert len(ev) == 2
    ids, b0, LM, SP, LQ = forecast.load_matrix(db)
    F = forecast.features(LM, SP, LQ, b0, reset_dow=3, events=[b0 * 3600 + 5 * 86400])
    assert np.nanmin(F["dsr"]) >= 0 and np.nanmax(F["dsr"]) <= 1
    assert F["evn"].min() < 1 and F["evp"].min() < 1
    text, rep = forecast.run(db, now=now, backend="ridge", force=True, events=[b0 * 3600 + 5 * 86400])
    assert text.startswith("TsmAnalizeForecast")
