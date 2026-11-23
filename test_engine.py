"""Testy czystej logiki AuctionEngine (bez sieci i GUI): pytest tests"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import AuctionEngine as ae

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
