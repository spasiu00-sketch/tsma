# -*- coding: utf-8 -*-
"""
Rozszerzenia AuctionEngine dla TSMA: drabina ofert, arbitraz miedzy domami aukcyjnymi, snajpowanie, prognozy.
Wszystko zwraca teksty Lua (BlizzForecast.lua, BlizzArb.lua, BlizzSnipe.lua) i pole "lad" do BlizzData.lua.
Zasady Forever: Horde <-> Alliance handluje sie TYLKO przez dom neutralny, wiec arbitraz dotyczy par, w ktorych
przynajmniej jeden dom jest neutralny (prowizja 15% przy sprzedazy w neutralnym).
"""
import sqlite3
import time

LEVELS = 8


def _unit(a):
    u = a.get("unit_price")
    if not u:
        b = a.get("buyout") or 0
        if b <= 0:
            return None
        u = b / (a.get("quantity", 1) or 1)
    u = int(round(u))
    return u if u > 0 else None


# ------------------------------------------------------------------ drabina
def house_ladder(auctions, levels=LEVELS):
    """{item: [(cena, ilosc), ...]} rosnaco, poziomy o tej samej cenie scalone, max `levels` poziomow."""
    per = {}
    for a in auctions:
        iid = (a.get("item") or {}).get("id")
        u = _unit(a)
        if iid and u:
            d = per.setdefault(iid, {})
            d[u] = d.get(u, 0) + int(a.get("quantity", 1) or 1)
    return {i: sorted(d.items())[:levels] for i, d in per.items()}


def ladder_cost(lad, n):
    """Koszt zakupu n sztuk idac po drabinie -> (koszt, kupione)."""
    cost, got = 0, 0
    for p, q in lad:
        take = min(q, n - got)
        cost += take * p
        got += take
        if got >= n:
            break
    return cost, got


def attach_ladders(entries, auctions, min_price=10000, max_items=1500):
    """Dopisuje e["lad"] = "cena:ilosc,..." do wpisow BlizzData (tylko drozsze przedmioty, limit rozmiaru pliku)."""
    lads = house_ladder(auctions)
    ids = [i for i, e in entries.items() if e["m"] >= min_price and i in lads]
    ids.sort(key=lambda i: -entries[i]["m"])
    for i in ids[:max_items]:
        entries[i]["lad"] = ",".join("%d:%d" % pq for pq in lads[i])
    return lads


# ------------------------------------------------------------------ arbitraz
def allowed(a, b):
    return a["neutral"] or b["neutral"]


def arbitrage(houses, min_profit=20000, max_units=40, haircut=0.02, margin_pct=8.0, min_price=5000, top=60):
    """houses = {id: {"name","cut","neutral","lad"}}. Kupno wg drabiny domu A, sprzedaz po min domu B
    (x (1-haircut): zapas na podcinanie), prowizja domu B. Bierzemy sztuki, dopoki marginalny zysk >= margin_pct."""
    rows = []
    for ia, A in houses.items():
        for ib, B in houses.items():
            if ia == ib or not allowed(A, B):
                continue
            keep = 1 - B["cut"] / 100.0
            for iid, la in A["lad"].items():
                lb = B["lad"].get(iid)
                if not lb:
                    continue
                sell = lb[0][0] * (1 - haircut)
                net_unit = sell * keep
                if net_unit < min_price * 0.5:
                    continue
                cost, n = 0, 0
                for p, q in la:
                    if net_unit / p - 1 < margin_pct / 100.0 or n >= max_units:
                        break
                    take = min(q, max_units - n)
                    cost += take * p
                    n += take
                if n <= 0:
                    continue
                profit = n * net_unit - cost
                if profit < min_profit:
                    continue
                rows.append({"s": "i:%d" % iid, "buyAH": ia, "sellAH": ib, "buy": cost / n, "sell": sell, "qty": n,
                             "cost": cost, "profit": int(round(profit)), "gain": (net_unit * n / cost - 1) * 100})
    rows.sort(key=lambda r: -r["profit"])
    return rows[:top]


def lua_arb(rows, houses, now):
    L = ["TsmAnalizeArb = { generated = %d, houses = {%s}, rows = {" % (
        now, ",".join('[%d]="%s"' % (i, h["name"].replace('"', "'")) for i, h in houses.items()))]
    for r in rows:
        L.append('{"%s",%d,%d,%.0f,%.0f,%d,%d,%.1f},' % (r["s"], r["buyAH"], r["sellAH"], r["buy"], r["sell"],
                                                       r["qty"], r["profit"], r["gain"]))
    L.append("} }")
    return "\n".join(L) + "\n"


# ------------------------------------------------------------------ snajpowanie
def load_live_ids(db_path):
    """ID aukcji z poprzedniego eksportu (wolac PRZED flow.update_flow, ktory nadpisuje tabele live)."""
    try:
        con = sqlite3.connect(db_path)
        try:
            return {r[0] for r in con.execute("SELECT id FROM live")}
        finally:
            con.close()
    except sqlite3.Error:
        return set()


def find_snipes(prev_ids, auctions, entries, cut=5.0, thr=0.25, min_profit=50000, top=50):
    """Nowe aukcje (nie bylo ich w poprzednim eksporcie) wyraznie ponizej mediany. Odniesienie: wlasna mediana
    z historii (h, gdy n >= 6), inaczej biezaca mediana rynku (d)."""
    if not prev_ids:
        return []
    keep = 1 - cut / 100.0
    out = {}
    for a in auctions:
        aid = a.get("id")
        if aid is None or aid in prev_ids:
            continue
        iid = (a.get("item") or {}).get("id")
        e = entries.get(iid)
        u = _unit(a)
        if not (e and u):
            continue
        ref = e["h"] if ("h" in e and e.get("n", 0) >= 6) else e["d"]
        if u > ref * (1 - thr):
            continue
        qty = int(a.get("quantity", 1) or 1)
        r = out.setdefault(iid, {"s": "i:%d" % iid, "unit": u, "qty": 0, "ref": ref, "profit": 0})
        r["unit"] = min(r["unit"], u)
        r["qty"] += qty
        r["profit"] += int(round(ref * keep - u)) * qty
    rows = [r for r in out.values() if r["profit"] >= min_profit]
    rows.sort(key=lambda r: -r["profit"])
    return rows[:top]


def lua_snipe(rows, now):
    L = ["TsmAnalizeSnipe = { generated = %d, rows = {" % now]
    for r in rows:
        L.append('{"%s",%d,%d,%.0f,%d},' % (r["s"], r["unit"], r["qty"], r["ref"], r["profit"]))
    L.append("} }")
    return "\n".join(L) + "\n"


def parse_events(txt):
    """"2026-12-01, 2026-12-15" -> lista znacznikow UTC (patche, nowa zawartosc: cechy prognozy)."""
    import calendar
    out = []
    for p in str(txt or "").replace(";", ",").split(","):
        p = p.strip()
        try:
            y, m, d = (int(x) for x in p.split("-"))
            out.append(calendar.timegm((y, m, d, 0, 0, 0)))
        except ValueError:
            continue
    return out


# ------------------------------------------------------------------ calosc
def build_extras(cfg, api, rs, ns, aid, aname, ahs, auctions, entries, cut, now, db_path, prev_ids, neutral_fn, log):
    """-> {nazwa_pliku: tekst}. Kazda czesc w osobnym try: blad jednej nie psuje reszty (pliki zawsze powstaja)."""
    out = {"BlizzForecast.lua": "TsmAnalizeForecast = { generated = 0, skill = {}, items = {} }\n",
           "BlizzArb.lua": "TsmAnalizeArb = { generated = 0, houses = {}, rows = {} }\n",
           "BlizzSnipe.lua": "TsmAnalizeSnipe = { generated = 0, rows = {} }\n"}
    own = house_ladder(auctions, 12)
    try:
        rows = find_snipes(prev_ids, auctions, entries, cut, float(cfg.get("snipe_pct", 25)) / 100,
                           int(float(cfg.get("snipe_min_g", 5)) * 10000))
        out["BlizzSnipe.lua"] = lua_snipe(rows, now)
        for r in rows[:5]:
            log("SNIPE i:%s: %d szt. od %.2fg (ref %.2fg), zysk ~%.1fg" % (
                r["s"][2:], r["qty"], r["unit"] / 1e4, r["ref"] / 1e4, r["profit"] / 1e4))
        if rows:
            try:
                import winsound
                winsound.MessageBeep()
            except Exception:
                pass
    except Exception as e:
        log("UWAGA: snajpowanie: %s" % e)
    if cfg.get("arb_on", True) and ahs:
        try:
            houses = {aid: {"name": aname, "cut": cut, "neutral": neutral_fn(aid, aname), "lad": own}}
            for i, n in ahs:
                if i == aid or not neutral_fn(i, n) or len(houses) > int(cfg.get("arb_max_houses", 3)):
                    continue
                recs, _ = api.fetch_auctions(rs, ns, i)
                houses[i] = {"name": n, "cut": 15.0, "neutral": True, "lad": house_ladder(recs, 12)}
            if len(houses) > 1 and not houses[aid]["neutral"]:
                rows = arbitrage(houses, int(float(cfg.get("arb_min_g", 2)) * 10000), int(cfg.get("arb_units", 40)))
                out["BlizzArb.lua"] = lua_arb(rows, houses, now)
                log("Arbitraz: %d okazji miedzy %d domami." % (len(rows), len(houses)))
        except Exception as e:
            log("UWAGA: arbitraz: %s" % e)
    try:
        import forecast
        text, rep = forecast.run(db_path, now=now, reset_dow=int(cfg.get("reset_dow", 3)),
                                 events=parse_events(cfg.get("events", "")))
        out["BlizzForecast.lua"] = text
        for l in rep:
            log(l)
    except Exception as e:
        log("UWAGA: prognoza: %s" % e)
    return out
