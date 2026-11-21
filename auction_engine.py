#!/usr/bin/env python3
"""AuctionEngine v2 - Blizzard AH -> BlizzData.lua + Import.lua + CSV (z ID i nazwa przedmiotu).

Uzycie:
    pip install requests
    python auction_engine.py            # jeden przebieg
    python auction_engine.py --loop     # co interval_min minut, bez konca
Przy pierwszym uruchomieniu pyta o Client ID/Secret, region, Connected Realm ID, namespace i folder dodatku.
Klucze: https://develop.battle.net
"""
import argparse
import csv
import json
import os
import shutil
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor

try:
    import requests
except ImportError:
    sys.exit("Brak modulu requests: pip install requests")

HERE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(HERE, "config.json")
HIST_PATH = os.path.join(HERE, "history.json")
NAMES_PATH = os.path.join(HERE, "names.json")
OUT_DIR = os.path.join(HERE, "out")

DEFAULTS = {
    "client_id": "",
    "client_secret": "",
    "region": "us",                       # us / eu / kr / tw
    "connected_realm_id": "",             # tryb classic
    "namespace": "dynamic-classic1x-us",  # np. dynamic-classic-us, dynamic-us (retail)
    "auction_house_id": "",               # puste = pierwszy dom z listy (lista wypisywana w konsoli)
    "mode": "classic",                    # classic = aukcje realmu, commodities = retail
    "locale": "en_US",                    # jezyk nazw przedmiotow (np. pl_PL nie istnieje w API; en_US/de_DE/fr_FR...)
    "addon_dir": "",                      # np. ...\_classic_\Interface\AddOns\TsmAnalize
    "cut": 5.0,                           # prowizja AH w %
    "hist_days": 14,
    "interval_min": 60,
    "min_price": 0,                       # w copper; ponizej pomijamy przedmiot
}
PROMPTS = [
    ("client_id", "Client ID"),
    ("client_secret", "Client Secret"),
    ("region", "Region (us/eu/kr/tw)"),
    ("connected_realm_id", "Connected Realm ID"),
    ("namespace", "Namespace (np. dynamic-classic1x-us)"),
    ("addon_dir", "Folder dodatku TsmAnalize (puste = tylko folder out)"),
]

SESSION = requests.Session()


# ----------------------------------------------------------------- pliki
def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def write_text(path, text, bom=False):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8-sig" if bom else "utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def load_config():
    cfg = dict(DEFAULTS)
    cfg.update(load_json(CFG_PATH, {}))
    need = not cfg["client_id"] or not cfg["client_secret"]
    need = need or (cfg["mode"] == "classic" and not str(cfg["connected_realm_id"]))
    if need:
        for key, label in PROMPTS:
            v = input(f"{label} [{cfg[key]}]: ").strip()
            if v:
                cfg[key] = v
        save_json(CFG_PATH, cfg)
    return cfg


# ----------------------------------------------------------------- API
def get_token(cfg):
    r = SESSION.post("https://oauth.battle.net/token", data={"grant_type": "client_credentials"},
                     auth=(cfg["client_id"], cfg["client_secret"]), timeout=30)
    r.raise_for_status()
    return r.json()["access_token"]


def api(cfg, token, path, namespace, params=None, tries=5):
    url = f"https://{cfg['region']}.api.blizzard.com{path}"
    q = {"namespace": namespace, "locale": cfg["locale"]}
    q.update(params or {})
    for i in range(tries):
        try:
            r = SESSION.get(url, params=q, headers={"Authorization": "Bearer " + token}, timeout=120)
        except requests.RequestException:
            time.sleep(2 * (i + 1))
            continue
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(2 * (i + 1))
            continue
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()
    raise RuntimeError("API nie odpowiada: " + url)


def fetch_rows(cfg, token):
    """Zwraca liste (item_id, cena_za_sztuke_w_copper, ilosc)."""
    rows = []
    ns = cfg["namespace"]
    if cfg["mode"] == "commodities":
        j = api(cfg, token, "/data/wow/auctions/commodities", ns)
        for a in (j or {}).get("auctions", []):
            rows.append((a["item"]["id"], int(a["unit_price"]), int(a["quantity"])))
        return rows

    realm = cfg["connected_realm_id"]
    ah = str(cfg.get("auction_house_id") or "")
    if not ah:
        idx = api(cfg, token, f"/data/wow/connected-realm/{realm}/auctions/index", ns)
        houses = (idx or {}).get("auctions") or (idx or {}).get("auction_houses") or []
        if houses:
            for h in houses:
                print(f"  dom aukcyjny: id={h.get('id')}  {h.get('name')}")
            ah = str(houses[0]["id"])
            print(f"  uzywam id={ah} (zmienisz w config.json: auction_house_id)")
    path = f"/data/wow/connected-realm/{realm}/auctions" + (f"/{ah}" if ah else "")
    j = api(cfg, token, path, ns)
    if j is None:
        raise RuntimeError("Brak aukcji (404) - sprawdz connected_realm_id / namespace / auction_house_id")
    for a in j.get("auctions", []):
        qty = int(a.get("quantity") or 1)
        buyout = int(a.get("buyout") or 0)
        if buyout <= 0 or qty <= 0:
            continue
        rows.append((a["item"]["id"], buyout // qty, qty))
    return rows


def ensure_names(cfg, token, ids):
    """Nazwy przedmiotow z Game Data API (cache w names.json, pobieramy tylko brakujace)."""
    names = load_json(NAMES_PATH, {})
    missing = [i for i in ids if str(i) not in names]
    if missing:
        static_ns = cfg["namespace"].replace("dynamic", "static")
        print(f"  pobieram nazwy: {len(missing)} przedmiotow...")

        def one(i):
            j = api(cfg, token, f"/data/wow/item/{i}", static_ns)
            n = (j or {}).get("name")
            if isinstance(n, dict):
                n = n.get(cfg["locale"]) or next(iter(n.values()), None)
            return str(i), n or f"Item {i}"

        done = 0
        with ThreadPoolExecutor(max_workers=8) as ex:
            for k, n in ex.map(one, missing):
                names[k] = n
                done += 1
                if done % 500 == 0:
                    print(f"    {done}/{len(missing)}")
                    save_json(NAMES_PATH, names)
        save_json(NAMES_PATH, names)
    return names


# ----------------------------------------------------------------- statystyki
def wmedian(pairs):
    pairs = sorted(pairs)
    total = sum(q for _, q in pairs)
    acc = 0
    for u, q in pairs:
        acc += q
        if acc * 2 >= total:
            return u
    return pairs[-1][0]


def aggregate(rows, min_price):
    by = {}
    for iid, unit, qty in rows:
        by.setdefault(iid, []).append((unit, qty))
    cur = {}
    for iid, pairs in by.items():
        m = min(u for u, _ in pairs)
        if m < min_price:
            continue
        cur[iid] = (m, wmedian(pairs), sum(q for _, q in pairs))
    return cur


def update_history(hist, cur, now, cfg):
    for iid, (m, d, _q) in cur.items():
        pts = hist.setdefault(f"i:{iid}", [])
        if not pts or pts[-1][0] != now:
            pts.append([now, m, d])
    keep_from = now - cfg["hist_days"] * 86400
    fresh = now - 3 * 86400
    for s in list(hist):
        out, last = [], None
        for p in hist[s]:
            if p[0] < keep_from:
                continue
            if p[0] >= fresh:
                out.append(p)
            else:                      # starsze niz 3 dni: jeden punkt na ~2h
                b = p[0] // 7200
                if b != last:
                    out.append(p)
                    last = b
        if out:
            hist[s] = out
        else:
            del hist[s]


def build_entries(cur, hist, names, cut, now):
    entries = []
    for iid, (m, d, q) in cur.items():
        s = f"i:{iid}"
        pts = hist.get(s, [])
        ms = [p[1] for p in pts]
        n = len(ms)
        h = float(statistics.median(ms)) if ms else float(m)
        lo, hi = (min(ms), max(ms)) if ms else (m, m)

        c = None
        target = now - 86400
        cand = [p for p in pts if abs(p[0] - target) <= 3 * 3600]
        if cand:
            ref = min(cand, key=lambda p: abs(p[0] - target))
            if ref[1] > 0:
                c = (m / ref[1] - 1) * 100

        p = None
        if n >= 3 and m > 0:
            p = (h * (1 - cut / 100) / m - 1) * 100

        f = ""
        if p is not None and p >= 20:
            f += "O"
        if c is not None and c <= -20:
            f += "D"
        if q <= 3:
            f += "L"

        entries.append({"id": iid, "s": s, "name": names.get(str(iid), f"Item {iid}"),
                        "m": m, "d": d, "q": q, "h": h, "lo": lo, "hi": hi,
                        "c": c, "p": p, "f": f, "n": n})
    entries.sort(key=lambda e: -e["m"])
    return entries


# ----------------------------------------------------------------- zapis
def lua_str(x):
    return '"' + str(x).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", " ") + '"'


def fnum(v):
    return "nil" if v is None else "%.1f" % v


def write_blizzdata(entries, cut, now, path):
    lines = [f"TsmAnalizeBlizz = {{ generated = {now}, cut = {cut:.1f}, items = {{"]
    for e in entries:
        lines.append('[%s]={nm=%s,m=%d,d=%d,q=%d,h=%.1f,lo=%d,hi=%d,c=%s,p=%s,f="%s",n=%d},' % (
            lua_str(e["s"]), lua_str(e["name"]), e["m"], e["d"], e["q"], e["h"], e["lo"], e["hi"],
            fnum(e["c"]), fnum(e["p"]), e["f"], e["n"]))
    deals = sorted((e for e in entries if "O" in e["f"]), key=lambda e: -e["p"])[:30]
    lines.append("}, deals = {")
    for e in deals:
        lines.append("{%s,%.1f}," % (lua_str(e["s"]), e["p"]))
    lines.append("} }")
    write_text(path, "\n".join(lines) + "\n")


def write_import(hist, min_price, now, path):
    lines = [f"TsmAnalizeImport = {{ generated = {now}, items = {{"]
    rows = [(s, pts) for s, pts in hist.items() if pts and pts[-1][1] >= min_price]
    rows.sort(key=lambda r: -r[1][-1][1])
    for s, pts in rows:
        body = ",".join("{%d,%d,%d}" % (p[0], p[1], p[2]) for p in pts)
        lines.append('[%s]={%s},' % (lua_str(s), body))
    lines.append("} }")
    write_text(path, "\n".join(lines) + "\n")


def write_csv(entries, path):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["id", "nazwa", "min_copper", "mediana_copper", "ilosc",
                    "wlasna_mediana", "zmiana_24h_%", "zysk_wg_mediany_%", "flagi", "punkty"])
        for e in entries:
            w.writerow([e["id"], e["name"], e["m"], e["d"], e["q"], round(e["h"], 1),
                        "" if e["c"] is None else round(e["c"], 1),
                        "" if e["p"] is None else round(e["p"], 1), e["f"], e["n"]])


# ----------------------------------------------------------------- przebieg
def run_once(cfg):
    now = int(time.time())
    print(time.strftime("[%H:%M:%S]"), "pobieram aukcje...")
    token = get_token(cfg)
    rows = fetch_rows(cfg, token)
    cur = aggregate(rows, int(cfg["min_price"]))
    print(f"  aukcji: {len(rows)}, przedmiotow: {len(cur)}")
    if not cur:
        print("  brak danych - pomijam zapis")
        return

    names = ensure_names(cfg, token, list(cur))
    hist = load_json(HIST_PATH, {})
    update_history(hist, cur, now, cfg)
    save_json(HIST_PATH, hist)

    entries = build_entries(cur, hist, names, float(cfg["cut"]), now)
    os.makedirs(OUT_DIR, exist_ok=True)
    p_blizz = os.path.join(OUT_DIR, "BlizzData.lua")
    p_imp = os.path.join(OUT_DIR, "Import.lua")
    p_csv = os.path.join(OUT_DIR, "przedmioty.csv")
    write_blizzdata(entries, float(cfg["cut"]), now, p_blizz)
    write_import(hist, int(cfg["min_price"]), now, p_imp)
    write_csv(entries, p_csv)

    addon = cfg.get("addon_dir")
    if addon:
        if os.path.isdir(addon):
            shutil.copy2(p_blizz, os.path.join(addon, "BlizzData.lua"))
            shutil.copy2(p_imp, os.path.join(addon, "Import.lua"))
            print("  skopiowano do:", addon)
        else:
            print("  UWAGA: folder dodatku nie istnieje:", addon)
    print(f"  gotowe: {len(entries)} przedmiotow (out/BlizzData.lua, out/Import.lua, out/przedmioty.csv). W grze: /reload")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--loop", action="store_true", help="powtarzaj co interval_min minut")
    args = ap.parse_args()
    cfg = load_config()
    while True:
        try:
            run_once(cfg)
        except Exception as e:  # noqa: BLE001
            print("BLAD:", e)
            if not args.loop:
                raise
        if not args.loop:
            break
        time.sleep(max(5, int(cfg["interval_min"])) * 60)


if __name__ == "__main__":
    main()
