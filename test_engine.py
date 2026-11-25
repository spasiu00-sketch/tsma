"""Testy czystej logiki AuctionEngine i flow.py (bez sieci i GUI): pytest tests"""
import os, sys, math, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import AuctionEngine as ae
import flow

CFG = {"opp_pct": 20, "store_min_g": 0.5}


def test_aggregate_regular_and_commodity():
    auctions = [
        {"item": {"id": 1}, "quantity": 2, "buyout": 2000},        # 1000 / szt.
        {"item": {"id": 1}, "quantity": 3, "unit_price": 1500},    # commodity
        {"item": {"id": 2}, "quantity": 1, "buyout": 0},           # sama licytacja - pomijana
    ]
    out = ae.aggregate(auctions)
    assert 2 not in out
    mn, med, tot = out[1]
    assert mn == 1000 and tot == 5
    assert med == 1500           # mediana wazona iloscia (2 szt. po 1000, 3 po 1500)


def test_trailing_id_and_ruleset():
    assert ae.trailing_id("Horde Auction House - 113") == 113
    assert ae.trailing_id("42") == 42
    assert ae.trailing_id("brak") is None
    assert ae.parse_ruleset({"ruleset": "Normal - 2"}) == 2
    assert ae.parse_ruleset({"ruleset": "pvp"}) == 1


def test_thin_keeps_last_point():
    now = 1_000_000
    pts = [(now - i * 600, 100, 100) for i in range(30, -1, -1)]
    out = ae.thin(pts, now)
    assert out[-1] == pts[-1] and len(out) < len(pts)


def test_build_entries_flags_and_profit():
    now = 10 * 86400
    agg = {7: (100000, 100000, 2)}                     # min 10g, ilosc 2 -> flaga L (mala podaz)
    hist = {7: [(now - (7 - i) * 3600 * 5, 150000, 150000) for i in range(8)] + [(now, 100000, 100000)]}
    entries, deals = ae.build_entries(agg, hist, CFG, 5.0, now)
    e = entries[7]
    assert "L" in e["f"]
    assert e["p"] > 20 and "O" in e["f"]
    assert deals and deals[0][0] == "i:7"


def test_lua_output_is_wellformed():
    entries = {1: {"m": 10000, "d": 11000, "q": 3, "f": "L"}}
    txt = ae.lua_blizz(entries, [("i:1", 12.5)], 5.0, 123)
    assert txt.startswith("TsmAnalizeBlizz = {") and '["i:1"]={m=10000,d=11000,q=3' in txt
    assert txt.rstrip().endswith("} }")


def test_lua_output_with_flow_and_calib():
    entries = {1: {"m": 10000, "d": 11000, "q": 3, "f": "", "fl": 12.345, "fk": 7, "fd": 0.4}}
    txt = ae.lua_blizz(entries, [], 5.0, 123, {"zs": 1.2, "disp": 0.6})
    assert "calib = {disp=0.60,zs=1.200}" in txt
    assert ",fl=12.35,fk=7,fd=0.40}" in txt


def test_load_calib_needs_enough_samples(tmp_path):
    p = tmp_path / "c.json"
    p.write_text('{"zs": 1.3, "n_price": 100, "disp": 0.7, "n_flow": 500}')
    assert ae.load_calib(str(p)) == {"disp": 0.7}
    p.write_text('{"zs": 1.3, "n_price": 900}')
    assert ae.load_calib(str(p)) == {"zs": 1.3}


# ------------------------------------------------------------ przeplyw
def _auc(aid, item, qty, unit, tl="LONG"):
    return {"id": aid, "item": {"id": item}, "quantity": qty, "unit_price": unit, "time_left": tl}


def test_update_flow_counts_gone_and_partial(tmp_path):
    db = str(tmp_path / "f.sqlite")
    t = 100 * 86400
    base = [_auc(1, 5, 10, 100), _auc(2, 5, 20, 100), _auc(3, 5, 5, 500), _auc(4, 5, 7, 100, "SHORT")]
    flow.update_flow(db, base, t)                                   # pierwsze pobranie: bez zejsc
    nxt = [_auc(2, 5, 12, 100), _auc(3, 5, 5, 500)]                 # 1 zniknela (10), 2 czesciowo (-8), 4 SHORT zniknela
    flow.update_flow(db, nxt, t + 1800)
    con = flow._con(db)
    rows = sorted(con.execute("SELECT qty, near FROM gone").fetchall())
    assert rows == [(8, 1), (10, 1)]                                # SHORT pominieta
    con.execute("DELETE FROM gone"); con.commit(); con.close()
    # aukcja drozsza niz 1.25 x min nie jest "przy minimum"
    flow.update_flow(db, [_auc(2, 5, 12, 100)], t + 3600)           # zniknela 3 (cena 500, min 100)
    con = flow._con(db)
    assert con.execute("SELECT qty, near FROM gone").fetchall() == [(5, 0)]
    con.close()


def test_update_flow_gap_not_counted(tmp_path):
    db = str(tmp_path / "f.sqlite")
    t = 100 * 86400
    flow.update_flow(db, [_auc(1, 5, 10, 100)], t)
    flow.update_flow(db, [_auc(2, 5, 3, 100)], t + 10 * 3600)       # przerwa > 6 h
    con = flow._con(db)
    assert con.execute("SELECT COUNT(*) FROM gone").fetchone()[0] == 0
    con.close()


def _simulate_flow(db, days, mean_day, seed=1):
    """Co 30 min: nowe aukcje, czesc znika; liczy sprzedane szt. wg zalozonej dyspersji (dzien losuje mnoznik)."""
    rnd = random.Random(seed)
    t0 = 100 * 86400
    live, nid, owed = {}, 1, 0.0
    for step in range(days * 48 + 1):
        t = t0 + step * 1800
        if step % 48 == 0:
            mult = rnd.gammavariate(2.0, 0.5)                       # sredniej 1, Var = 0.5 -> phi ~ 0.5
        owed += mean_day * mult / 48                                # dlug sprzedazy przenosi sie miedzy krokami
        while owed > 0 and live:
            aid = min(live, key=lambda k: live[k][1])
            owed -= live.pop(aid)[0]
        while len(live) < 30:
            live[nid] = (rnd.randint(1, 5), 100 + rnd.randint(0, 5))
            nid += 1
        auctions = [_auc(aid, 9, q, u) for aid, (q, u) in live.items()]
        flow.update_flow(db, auctions, t, days=7, agg={9: (min(u for _, u in live.values()), 100, 50)})
    return t0 + days * 48 * 1800


def test_flow_stats_and_backtest_run(tmp_path):
    db = str(tmp_path / "f.sqlite")
    now = _simulate_flow(db, 12, 40)
    con = flow._con(db)
    st = flow.flow_stats(con, now, 7)
    con.close()
    assert st["days"] >= 5
    fl = st["items"][9]["fl"]
    assert 20 < fl < 80
    assert "fd" in st["items"][9]
    calib, rep = flow.run_backtest(db, now=now)
    assert any("PRZEPLYW" in l for l in rep)


def test_best_disp_recovers_overdispersion():
    rnd = random.Random(2)
    samples = []
    for _ in range(800):
        mu = rnd.uniform(5, 40)
        lam = rnd.gammavariate(2.0, mu / 2.0)                        # NB z phi = 0.5
        y = 0
        L, p = math.exp(-lam), 1.0
        while True:                                                 # Poisson(lam)
            p *= rnd.random()
            if p <= L:
                break
            y += 1
        samples.append((y, mu))
    phi = flow.best_disp(samples)
    assert 0.3 <= phi <= 0.8


def test_price_quantiles_centered_and_scaled():
    rnd = random.Random(4)
    by, v = {}, 1000.0
    for d in range(60):
        v *= math.exp(rnd.gauss(0, 0.04))
        by[d] = v
    zq, sig = flow.price_quantiles(by, 2)
    assert len(zq) == 16 and zq == sorted(zq)
    assert abs(sum(math.exp(z) for z in zq) / 16 - 1) < 1e-9
    zq2, sig2 = flow.price_quantiles(by, 2, zs=1.5)
    assert abs(sig2 / sig - 1.5) < 1e-9
