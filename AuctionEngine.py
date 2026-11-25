#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AuctionEngine 2.3 - aplikacja desktopowa dla addonu TSMA (tylko WoW Forever)

* pobiera aukcje z Blizzard API Forever:
    /data/wow/ruleset/{ruleset}/auctions/{dom}          (zwykle aukcje, cena = buyout / ilosc)
    /data/wow/ruleset/{ruleset}/auctions/{dom}/commodities  (commodities, cena = unit_price)
  namespace dynamic-forever-<region> (eu albo us). Forever NIE ma connected-realm ani Realm ID.
* liczy statystyki (min, mediana, ilosc, wlasna mediana z historii, zmiana 24h, zysk, flagi)
* sledzi ID aukcji miedzy pobraniami (flow.py) i mierzy przeplyw rynku: fl = zejscia przy minimum (szt./dobe),
  fd = dyspersja dobowa, fk = liczba dni pokrycia; zapisuje tez zamkniecia dobowe do backtestu
* przycisk "Backtest" (albo python tests/backtest.py) liczy skale kwantyli ceny i dyspersje sprzedazy na historii
  -> calib.json -> BlizzData.lua (calib = { zs, disp }), czytane przez Risk.lua
* zapisuje BlizzData.lua (aktualna migawka), Import.lua (historia TSMA) i NOWE BlizzHist.lua (pelna historia punktow
  Blizzarda: t,min,mediana,ilosc) prosto w folderze addonu TsmAnalize (i kopie w %APPDATA%\\AuctionEngine\\out)
* odswieza sie automatycznie co N minut (pomija pobranie, gdy Last-Modified sie nie zmienil); w grze /reload
Ceny w API sa w copper. To ceny WYSTAWIEN, nie potwierdzone sprzedaze.
"""
import os, sys, re, json, time, glob, queue, string, sqlite3, itertools, statistics, threading, traceback

import requests

try:
    import flow
except ImportError:      # brak flow.py obok programu: dziala bez pomiaru przeplywu
    flow = None

try:
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
except ImportError:      # srodowisko bez GUI (testy)
    tk = None

APP = "AuctionEngine"
DATA_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), APP)
OUT_DIR = os.path.join(DATA_DIR, "out")
CFG_PATH = os.path.join(DATA_DIR, "config.json")
STATE_PATH = os.path.join(DATA_DIR, "state.json")
CALIB_PATH = os.path.join(DATA_DIR, "calib.json")
os.makedirs(OUT_DIR, exist_ok=True)

RULESETS = [(1, "PvP"), (2, "Normal"), (3, "Roleplay"), (15, "Roleplay PvP")]
NEUTRAL_HOUSES = {116, 117, 118, 121, 125}     # Blackwater (neutralny, prowizja 15%)
DEFAULT_HOUSE = 113                            # EU / Normal / Horde

DEFAULTS = {
    "client_id": "", "client_secret": "",
    "region": "eu",                       # eu albo us
    "ruleset": "Normal - 2",              # PvP - 1, Normal - 2, Roleplay - 3, Roleplay PvP - 15
    "ah": "Horde Auction House - 113",    # "nazwa - ID domu"; puste = 113 jesli jest, inaczej pierwszy frakcyjny
    "namespace": "",                      # puste = auto (dynamic-forever-<region>)
    "addon_dir": "",
    "interval_min": 30,
    "history_days": 14,
    "store_min_g": 0.5,     # od jakiej ceny zapisujemy historie (zloto)
    "import_min_g": 0.5,    # od jakiej ceny przedmiot trafia do Import.lua i BlizzHist.lua
    "import_max_items": 1500,
    "blizzhist_max_items": 600,   # max przedmiotow w BlizzHist.lua (najdrozsze pierwsze)
    "opp_pct": 20,          # prog flagi "okazja" (zysk wg wlasnej mediany, %)
    "flow_days": 7,         # okno pomiaru przeplywu rynku (dni)
    "auto_start": False,
}

class ApiError(Exception):
    pass

def load_cfg():
    cfg = dict(DEFAULTS)
    try:
        with open(CFG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except Exception:
        pass
    if cfg.get("region") not in ("eu", "us"):      # stare ustawienia (kr/tw/classic) nie dotycza Forever
        cfg["region"] = "eu"
    if str(cfg.get("namespace", "")).strip().startswith("dynamic-classic"):
        cfg["namespace"] = ""
    return cfg

def save_cfg(cfg):
    tmp = CFG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, CFG_PATH)

def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def save_state(st):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_PATH)

def load_calib(path=None):
    """Kalibracja z backtestu (calib.json) -> {'zs':..., 'disp':...} albo None, gdy za malo probek."""
    try:
        with open(path or CALIB_PATH, encoding="utf-8") as f:
            c = json.load(f)
    except Exception:
        return None
    if not isinstance(c, dict):
        return None
    out = {}
    try:
        if c.get("zs") and c.get("n_price", 0) >= 300:
            out["zs"] = round(float(c["zs"]), 3)
        if c.get("disp") is not None and c.get("n_flow", 0) >= 200:
            out["disp"] = round(float(c["disp"]), 2)
    except (TypeError, ValueError):
        return None
    return out or None

def nm(v):
    if isinstance(v, dict):
        return v.get("en_US") or v.get("en_GB") or next(iter(v.values()), "")
    return v or ""

def trailing_id(txt):
    m = re.search(r"-\s*(\d+)\s*$", txt or "") or re.match(r"^\s*(\d+)\s*$", txt or "")
    return int(m.group(1)) if m else None

def ruleset_labels():
    return ["%s - %d" % (n, i) for i, n in RULESETS]

def parse_ruleset(cfg):
    txt = str(cfg.get("ruleset", "")).strip()
    rid = trailing_id(txt)
    if rid is None:
        low = txt.lower()
        rid = next((i for i, n in RULESETS if n.lower() == low), None)
    if rid is None:
        raise ApiError("Nie rozumiem rulesetu '%s'. Wybierz z listy (np. Normal - 2)." % txt)
    return rid

def hint(code):
    return {
        401: "zly token / klucz",
        403: "zly region albo namespace (dla Forever: dynamic-forever-eu / dynamic-forever-us)",
        404: "zly ruleset lub dom aukcyjny (adres musi miec /index przy liscie domow)",
        429: "limit zapytan",
    }.get(code, "blad serwera")

def find_list(j):
    """Pierwsza lista slownikow z polem 'id' w odpowiedzi (nazwa klucza zalezy od endpointu)."""
    if isinstance(j, dict):
        for k in ("auctions", "auction_houses", "houses"):
            v = j.get(k)
            if isinstance(v, list) and v and isinstance(v[0], dict) and "id" in v[0]:
                return v
        for v in j.values():
            if isinstance(v, list) and v and isinstance(v[0], dict) and "id" in v[0]:
                return v
    return []

# ---------------------------------------------------------------- Blizzard API
class Blizz:
    def __init__(self, cid, secret, region):
        self.cid, self.secret, self.region = cid.strip(), secret.strip(), region.strip().lower()
        if self.region not in ("eu", "us"):
            raise ApiError("Forever jest tylko w regionach eu i us (wybrano '%s')." % self.region)
        self.s = requests.Session()
        self.s.headers["User-Agent"] = "AuctionEngine/2.3"
        self.tok, self.exp = None, 0

    def namespace(self, forced=""):
        return (forced or "").strip() or ("dynamic-forever-" + self.region)

    def _token(self, force=False):
        if self.tok and not force and time.time() < self.exp - 120:
            return self.tok
        if not self.cid or not self.secret:
            raise ApiError("Brak Client ID / Client Secret.")
        try:
            r = self.s.post("https://oauth.battle.net/token", data={"grant_type": "client_credentials"},
                            auth=(self.cid, self.secret), timeout=30)
        except requests.RequestException as e:
            raise ApiError("Brak polaczenia z oauth.battle.net: %s" % e)
        if r.status_code != 200:
            raise ApiError("Logowanie do Blizzard API nieudane (HTTP %d). Sprawdz Client ID i Secret." % r.status_code)
        j = r.json()
        self.tok, self.exp = j["access_token"], time.time() + j.get("expires_in", 3600)
        return self.tok

    def get(self, path, ns):
        url = "https://%s.api.blizzard.com%s" % (self.region, path)
        for attempt in range(4):
            try:
                r = self.s.get(url, params={"namespace": ns},
                               headers={"Authorization": "Bearer " + self._token()}, timeout=180)
            except requests.RequestException as e:
                if attempt == 3:
                    raise ApiError("Blad sieci: %s" % e)
                time.sleep(2)
                continue
            if r.status_code == 401 and attempt < 3:
                self._token(True)
                continue
            if r.status_code == 429 or r.status_code >= 500:
                if attempt < 3:
                    time.sleep(3 * (attempt + 1))
                    continue
            return r
        raise ApiError("Zbyt wiele nieudanych prob: " + path)

    def list_ah(self, rs, ns):
        r = self.get("/data/wow/ruleset/%d/auctions/index" % rs, ns)
        if r.status_code != 200:
            raise ApiError("Lista domow aukcyjnych: HTTP %d (%s)" % (r.status_code, hint(r.status_code)))
        out = [(a["id"], nm(a.get("name")) or ("AH %s" % a["id"])) for a in find_list(r.json())]
        if not out:
            raise ApiError("Indeks domow aukcyjnych jest pusty (ruleset %d)." % rs)
        return sorted(out)

    def fetch_auctions(self, rs, ns, ah, log=None):
        """-> (lista rekordow, znacznik Last-Modified). Brak tablicy 'auctions' = pusty dom, nie blad."""
        base = "/data/wow/ruleset/%d/auctions/%d" % (rs, ah)
        r = self.get(base, ns)
        if r.status_code != 200:
            raise ApiError("Pobieranie aukcji: HTTP %d (%s)" % (r.status_code, hint(r.status_code)))
        regular = r.json().get("auctions") or []
        stamp = r.headers.get("Last-Modified", "")
        r2 = self.get(base + "/commodities", ns)
        commodities = []
        if r2.status_code == 200:
            commodities = r2.json().get("auctions") or []
            stamp += "|" + r2.headers.get("Last-Modified", "")
        elif log:
            log("UWAGA: commodities HTTP %d (%s) - biore tylko zwykle aukcje." % (r2.status_code, hint(r2.status_code)))
        if log:
            log("Zwykle aukcje: %d, commodities: %d." % (len(regular), len(commodities)))
        return regular + commodities, stamp

# ---------------------------------------------------------------- przetwarzanie
def aggregate(auctions):
    per = {}
    for a in auctions:
        iid = (a.get("item") or {}).get("id")
        qty = a.get("quantity", 1) or 1
        if not iid:
            continue
        if a.get("unit_price"):
            unit = a["unit_price"]          # commodities
        else:
            b = a.get("buyout") or 0
            if b <= 0:
                continue                    # same licytacje bez ceny kup-teraz pomijamy
            unit = b / qty
        unit = int(round(unit))
        if unit > 0:
            per.setdefault(iid, []).append((unit, qty))
    out = {}
    for iid, l in per.items():
        l.sort()
        tot = sum(q for _, q in l)
        acc, med = 0, l[-1][0]
        for u, q in l:
            acc += q
            if acc >= tot / 2:
                med = u
                break
        out[iid] = (l[0][0], med, tot)    # min, mediana wazona iloscia, laczna ilosc
    return out

def store_and_load(agg, cfg, now, db_path):
    """Zapisuje migawke i zwraca (hist, histq):
    hist  = {item: [(t, min, mediana), ...]}        - dla statystyk, Import.lua
    histq = {item: [(t, min, mediana, ilosc), ...]} - dla BlizzHist.lua (historia wykresu Blizzarda)"""
    days = int(cfg["history_days"])
    store_min = int(float(cfg["store_min_g"]) * 10000)
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS snap(t INTEGER, item INTEGER, m INTEGER, d INTEGER, q INTEGER)")
    cur.execute("CREATE INDEX IF NOT EXISTS ix_snap ON snap(item, t)")
    cur.execute("DELETE FROM snap WHERE t < ?", (now - days * 86400,))
    cur.execute("DELETE FROM snap WHERE t = ?", (now,))
    cur.executemany("INSERT INTO snap VALUES(?,?,?,?,?)",
                    [(now, i, m, d, q) for i, (m, d, q) in agg.items() if m >= store_min])
    con.commit()
    hist, histq = {}, {}
    for item, grp in itertools.groupby(cur.execute("SELECT item, t, m, d, q FROM snap ORDER BY item, t"),
                                       key=lambda r: r[0]):
        if item in agg:
            rows = list(grp)
            hist[item] = [(r[1], r[2], r[3]) for r in rows]
            histq[item] = [(r[1], r[2], r[3], r[4] or 0) for r in rows]
    con.close()
    return hist, histq

def build_entries(agg, hist, cfg, cut, now, flow_res=None):
    keep = 1 - cut / 100.0
    opp = float(cfg["opp_pct"])
    store_min = int(float(cfg["store_min_g"]) * 10000)
    fitems = (flow_res or {}).get("items", {})
    fdays = (flow_res or {}).get("days", 0)
    entries, deals = {}, []
    for iid, (m, d, q) in agg.items():
        e = {"m": m, "d": d, "q": q, "f": ""}
        h = hist.get(iid, [])
        n = len(h)
        flags = ""
        if q <= 3:
            flags += "L"
        if n >= 2:
            ms = [x[1] for x in h]
            e["h"] = float(statistics.median(ms))
            e["lo"], e["hi"], e["n"] = min(ms), max(ms), n
            prev = [x for x in h if x[0] <= now - 20 * 3600]
            if prev:
                ref = min(prev, key=lambda x: abs(x[0] - (now - 86400)))[1]
                if ref > 0:
                    e["c"] = round((m / ref - 1) * 100, 1)
                    if e["c"] <= -25:
                        flags += "D"
            if n >= 3 and m > 0:
                e["p"] = round((e["h"] * keep / m - 1) * 100, 1)
                if n >= 6 and e["p"] >= opp and m >= store_min:
                    flags += "O"
                    deals.append(("i:%d" % iid, e["p"]))
        e["f"] = flags
        if fdays >= 2:                         # przeplyw zmierzony: brak zejsc = 0, nie "brak danych"
            fe = fitems.get(iid)
            e["fl"] = fe["fl"] if fe else 0.0
            e["fk"] = fdays
            if fe and "fd" in fe:
                e["fd"] = fe["fd"]
        entries[iid] = e
    deals.sort(key=lambda x: -x[1])
    return entries, deals[:20]

def lua_blizz(entries, deals, cut, now, calib=None):
    head = "TsmAnalizeBlizz = { generated = %d, cut = %.1f, " % (now, cut)
    if calib:
        head += "calib = {%s}, " % ",".join("%s=%s" % (k, ("%.3f" if k == "zs" else "%.2f") % v) for k, v in sorted(calib.items()))
    L = [head + "items = {"]
    for iid, e in sorted(entries.items(), key=lambda kv: -kv[1]["m"]):
        s = '["i:%d"]={m=%d,d=%d,q=%d' % (iid, e["m"], e["d"], e["q"])
        if "h" in e:
            s += ",h=%.1f,lo=%d,hi=%d" % (e["h"], e["lo"], e["hi"])
        if "c" in e:
            s += ",c=%.1f" % e["c"]
        if "p" in e:
            s += ",p=%.1f" % e["p"]
        s += ',f="%s"' % e["f"]
        if "n" in e:
            s += ",n=%d" % e["n"]
        if "fl" in e:
            s += ",fl=%.2f,fk=%d" % (e["fl"], e["fk"])
        if "fd" in e:
            s += ",fd=%.2f" % e["fd"]
        L.append(s + "},")
    L.append("}, deals = {")
    for s, p in deals:
        L.append('{"%s",%.1f},' % (s, p))
    L.append("} }")
    return "\n".join(L) + "\n"

def thin(points, now):
    """Przerzedza punkty (krotki dowolnej dlugosci, pierwszy element = czas): ostatnie 3 dni co godzine, starsze co 4 h."""
    out, last = [], None
    for p in points:
        t = p[0]
        gap = 3600 if t >= now - 3 * 86400 else 4 * 3600
        if last is None or t - last >= gap:
            out.append(p)
            last = t
    if points and out[-1][0] != points[-1][0]:
        out.append(points[-1])
    return out

def lua_import(entries, hist, cfg, now):
    mn = int(float(cfg["import_min_g"]) * 10000)
    ids = [i for i, e in entries.items() if e["m"] >= mn and i in hist]
    ids.sort(key=lambda i: -entries[i]["m"])
    ids = ids[:int(cfg["import_max_items"])]
    L = ["TsmAnalizeImport = { generated = %d, items = {" % now]
    for i in ids:
        pts = ",".join("{%d,%d,%d}" % p for p in thin(hist[i], now))
        L.append('["i:%d"]={%s},' % (i, pts))
    L.append("} }")
    return "\n".join(L) + "\n", len(ids)

def lua_blizzhist(entries, histq, cfg, now):
    """Pelna historia punktow Blizzarda dla addonu (Source.lua scala ja z db.blizzHist).
    Kazdy przedmiot = JEDEN napis "t,min,mediana,ilosc;t,min,..." (zamiast tysiecy liczb w tabelach, zeby nie
    przekroczyc limitu stalych funkcji w Lua 5.1)."""
    mn = int(float(cfg["import_min_g"]) * 10000)
    ids = [i for i, e in entries.items() if e["m"] >= mn and histq.get(i)]
    ids.sort(key=lambda i: -entries[i]["m"])
    ids = ids[:int(float(cfg.get("blizzhist_max_items", 600)))]
    L = ["TsmAnalizeBlizzHist = { generated = %d, items = {" % now]
    for i in ids:
        pts = ";".join("%d,%d,%d,%d" % p for p in thin(histq[i], now))
        L.append('["i:%d"]="%s",' % (i, pts))
    L.append("} }")
    return "\n".join(L) + "\n", len(ids)

def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)

TOC_FILES = ("BlizzData.lua", "BlizzHist.lua", "Blizz.lua")

def ensure_toc(addon_dir, log):
    toc = os.path.join(addon_dir, "TsmAnalize.toc")
    if not os.path.exists(toc):
        log("UWAGA: brak TsmAnalize.toc w %s - to na pewno folder addonu?" % addon_dir)
        return
    with open(toc, encoding="utf-8") as f:
        lines = f.read().splitlines()
    names = [l.strip() for l in lines]
    need = [n for n in TOC_FILES if n not in names]
    if "Blizz.lua" in need and not os.path.exists(os.path.join(addon_dir, "Blizz.lua")):
        log("UWAGA: brak pliku Blizz.lua w folderze addonu - skopiuj go tam (to on wyswietla dane w tooltipie).")
        need.remove("Blizz.lua")
    if not need:
        return
    idx = names.index("Import.lua") + 1 if "Import.lua" in names else len(lines)
    lines[idx:idx] = need
    write_atomic(toc, "\n".join(lines) + "\n")
    log("Dopisano do TsmAnalize.toc: %s (nowe pliki w .toc wymagaja PELNEGO restartu gry, nie /reload)" % ", ".join(need))

def write_outputs(entries, deals, cfg, cut, now, log):
    b = lua_blizz(entries, deals, cut, now, cfg.get("_calib"))
    imp, n_imp = lua_import(entries, cfg["_hist"], cfg, now)
    bh, n_bh = lua_blizzhist(entries, cfg["_histq"], cfg, now)
    targets = [OUT_DIR]
    ad = cfg.get("addon_dir", "").strip()
    if ad:
        if os.path.isdir(ad):
            targets.append(ad)
        else:
            log("UWAGA: folder addonu nie istnieje: %s (zapis tylko do %s)" % (ad, OUT_DIR))
    for t in targets:
        write_atomic(os.path.join(t, "BlizzData.lua"), b)
        write_atomic(os.path.join(t, "Import.lua"), imp)
        write_atomic(os.path.join(t, "BlizzHist.lua"), bh)
    if ad and os.path.isdir(ad):
        ensure_toc(ad, log)
    return targets, n_imp, n_bh, len(b), len(imp), len(bh)

def pick_ah(ahs, sel, log):
    ids = {i: n for i, n in ahs}
    want = trailing_id(sel)
    if want in ids:
        return want, ids[want]
    if want is not None:
        log("UWAGA: dom %d nie istnieje w indeksie (dostepne: %s) - wybieram automatycznie." %
            (want, ", ".join(str(i) for i in sorted(ids))))
    if DEFAULT_HOUSE in ids:
        return DEFAULT_HOUSE, ids[DEFAULT_HOUSE]
    for i, n in ahs:
        if i not in NEUTRAL_HOUSES and "neutral" not in n.lower() and "blackwater" not in n.lower():
            return i, n
    return ahs[0]

def run_once(cfg, log, set_ui, api=None, force=True):
    t0 = time.time()
    api = api or Blizz(cfg["client_id"], cfg["client_secret"], cfg["region"])
    ns = api.namespace(cfg.get("namespace", ""))
    rs = parse_ruleset(cfg)
    ahs = api.list_ah(rs, ns)
    set_ui("ah_values", ["%s - %d" % (n, i) for i, n in ahs])
    aid, aname = pick_ah(ahs, cfg.get("ah", ""), log)
    set_ui("ah", "%s - %d" % (aname, aid))
    neutral = aid in NEUTRAL_HOUSES or "neutral" in aname.lower() or "blackwater" in aname.lower()
    cut = 15.0 if neutral else 5.0
    log("Forever %s | ruleset %d | namespace %s | AH: %s (%d) | prowizja %.0f%%" %
        (api.region.upper(), rs, ns, aname, aid, cut))
    log("Pobieram aukcje...")
    auctions, stamp = api.fetch_auctions(rs, ns, aid, log)
    if not auctions:
        log("Dom zwrocil 0 aukcji (pusty dom albo zly ruleset/dom) - nie nadpisuje plikow.")
        return
    key = "%s|%d|%d" % (api.region, rs, aid)
    state = load_state()
    if not force and stamp.strip("|") and state.get(key) == stamp:
        log("Last-Modified bez zmian - brak nowych danych, pomijam zapis.")
        return
    log("Pobrano %d aukcji, licze statystyki..." % len(auctions))
    now = int(time.time())
    agg = aggregate(auctions)
    db_path = os.path.join(DATA_DIR, "history_forever_%s_%d_%d.sqlite" % (api.region, rs, aid))
    flow_res = None
    if flow is not None:
        try:
            flow_res = flow.update_flow(db_path, auctions, now, int(cfg.get("flow_days", 7)), log, agg=agg,
                                        store_min=int(float(cfg["store_min_g"]) * 10000))
        except Exception as e:
            log("UWAGA: przeplyw rynku nie policzony: %s" % e)
    hist, histq = store_and_load(agg, cfg, now, db_path)
    entries, deals = build_entries(agg, hist, cfg, cut, now, flow_res)
    cfg = dict(cfg, _hist=hist, _histq=histq, _calib=load_calib())
    targets, n_imp, n_bh, sb, si, sh = write_outputs(entries, deals, cfg, cut, now, log)
    state[key] = stamp
    save_state(state)
    log("OK: %d przedmiotow (okazji: %d), Import.lua: %d, BlizzHist.lua: %d przedmiotow, pliki %.1f + %.1f + %.1f MB, %.1f s." %
        (len(entries), len(deals), n_imp, n_bh, sb / 1048576, si / 1048576, sh / 1048576, time.time() - t0))
    log("Zapisano w: %s  ->  w grze wpisz /reload" % " ; ".join(targets))

# ---------------------------------------------------------------- wykrywanie folderu addonu
def detect_addon_dirs():
    found = []
    roots = []
    for d in string.ascii_uppercase:
        drv = d + ":\\"
        if os.path.exists(drv):
            for sub in ("World of Warcraft", "Program Files (x86)\\World of Warcraft", "Program Files\\World of Warcraft",
                        "Games\\World of Warcraft", "Gry\\World of Warcraft"):
                roots.append(os.path.join(drv, sub))
    for r in roots:
        found += glob.glob(os.path.join(r, "_*_", "Interface", "AddOns", "TsmAnalize"))
    return sorted(set(found), key=lambda p: ("forever" not in p.lower(), p))

# ---------------------------------------------------------------- GUI
class App(tk.Tk if tk else object):
    def __init__(self):
        super().__init__()
        self.title("AuctionEngine - TSMA (WoW Forever)")
        self.geometry("860x720")
        self.cfg = load_cfg()
        self.q = queue.Queue()
        self.busy = False
        self.auto = False
        self.after_id = None
        self.next_t = None
        self.v = {}
        self.build()
        self.after(100, self.poll)
        self.after(1000, self.tick_status)
        if self.cfg.get("auto_start") and self.cfg.get("client_id"):
            self.after(1500, self.toggle_auto)

    def field(self, parent, row, label, key, width=44, show=None, values=None):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=6, pady=3)
        var = tk.StringVar(value=str(self.cfg.get(key, "")))
        self.v[key] = var
        if values is not None:
            w = ttk.Combobox(parent, textvariable=var, width=width, values=values)
        else:
            w = ttk.Entry(parent, textvariable=var, width=width, show=show)
        w.grid(row=row, column=1, sticky="we", padx=6, pady=3)
        return w

    def build(self):
        pad = {"padx": 8, "pady": 5}
        f1 = ttk.LabelFrame(self, text="1. Konto Blizzard API (develop.battle.net)")
        f1.pack(fill="x", **pad)
        f1.columnconfigure(1, weight=1)
        self.field(f1, 0, "Client ID", "client_id")
        self.field(f1, 1, "Client Secret", "client_secret", show="*")
        self.field(f1, 2, "Region (Forever: eu / us)", "region", width=8, values=["eu", "us"])

        f2 = ttk.LabelFrame(self, text="2. Ruleset i dom aukcyjny (bez Realm ID - Forever go nie uzywa)")
        f2.pack(fill="x", **pad)
        f2.columnconfigure(1, weight=1)
        self.field(f2, 0, "Ruleset", "ruleset", width=20, values=ruleset_labels())
        self.ah_box = self.field(f2, 1, "Dom aukcyjny", "ah", values=[])
        ttk.Button(f2, text="Wczytaj domy / sprawdz", command=self.test).grid(row=1, column=2, padx=6)

        f3 = ttk.LabelFrame(self, text="3. Folder addonu TsmAnalize")
        f3.pack(fill="x", **pad)
        f3.columnconfigure(1, weight=1)
        self.field(f3, 0, "Folder", "addon_dir")
        bf = ttk.Frame(f3)
        bf.grid(row=0, column=2)
        ttk.Button(bf, text="Wybierz...", command=self.pick_dir).pack(side="left", padx=2)
        ttk.Button(bf, text="Wykryj", command=self.detect).pack(side="left", padx=2)

        f4 = ttk.LabelFrame(self, text="Opcje")
        f4.pack(fill="x", **pad)
        f4.columnconfigure(1, weight=1)
        f4.columnconfigure(3, weight=1)
        opts = [("Odswiezanie co (min)", "interval_min"), ("Historia (dni)", "history_days"),
                ("Min. cena historii (g)", "store_min_g"), ("Min. cena w Import/BlizzHist (g)", "import_min_g"),
                ("Max przedmiotow w Import.lua", "import_max_items"), ("Prog okazji (%)", "opp_pct"),
                ("Max przedmiotow w BlizzHist.lua", "blizzhist_max_items")]
        for i, (lbl, key) in enumerate(opts):
            r, c = divmod(i, 2)
            ttk.Label(f4, text=lbl).grid(row=r, column=c * 2, sticky="w", padx=6, pady=2)
            var = tk.StringVar(value=str(self.cfg[key]))
            self.v[key] = var
            ttk.Entry(f4, textvariable=var, width=10).grid(row=r, column=c * 2 + 1, sticky="w", padx=6, pady=2)
        ttk.Label(f4, text="Namespace (puste = auto)").grid(row=4, column=0, sticky="w", padx=6, pady=2)
        self.v["namespace"] = tk.StringVar(value=self.cfg["namespace"])
        ttk.Entry(f4, textvariable=self.v["namespace"], width=30).grid(row=4, column=1, columnspan=2, sticky="w", padx=6)
        self.v["auto_start"] = tk.BooleanVar(value=bool(self.cfg["auto_start"]))
        ttk.Checkbutton(f4, text="Uruchom auto-odswiezanie przy starcie programu",
                        variable=self.v["auto_start"]).grid(row=5, column=0, columnspan=4, sticky="w", padx=6, pady=2)

        bar = ttk.Frame(self)
        bar.pack(fill="x", **pad)
        self.btn_run = ttk.Button(bar, text="Pobierz teraz", command=self.start_run)
        self.btn_run.pack(side="left", padx=4)
        self.btn_auto = ttk.Button(bar, text="Start auto-odswiezania", command=self.toggle_auto)
        self.btn_auto.pack(side="left", padx=4)
        ttk.Button(bar, text="Backtest", command=self.backtest).pack(side="left", padx=4)
        ttk.Button(bar, text="Otworz folder wynikow", command=lambda: os.startfile(OUT_DIR) if os.name == "nt" else None).pack(side="left", padx=4)
        self.status = ttk.Label(bar, text="Gotowy.")
        self.status.pack(side="right", padx=6)

        self.logw = tk.Text(self, height=14, wrap="word", state="disabled", font=("Consolas", 9))
        self.logw.pack(fill="both", expand=True, **pad)
        self.log("Client ID/Secret + region -> 'Wczytaj domy / sprawdz' -> wybierz dom (EU Normal Horde = 113) -> 'Pobierz teraz'.")
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    # --- pomocnicze
    def collect(self):
        cfg = dict(self.cfg)
        for k, var in self.v.items():
            val = var.get()
            if isinstance(val, str):
                val = val.strip()
            cfg[k] = val
        try:
            cfg["interval_min"] = max(5, int(float(cfg["interval_min"])))
            cfg["history_days"] = max(1, min(30, int(float(cfg["history_days"]))))
            cfg["import_max_items"] = max(0, int(float(cfg["import_max_items"])))
            cfg["blizzhist_max_items"] = max(0, int(float(cfg["blizzhist_max_items"])))
            cfg["store_min_g"] = float(str(cfg["store_min_g"]).replace(",", "."))
            cfg["import_min_g"] = float(str(cfg["import_min_g"]).replace(",", "."))
            cfg["opp_pct"] = float(str(cfg["opp_pct"]).replace(",", "."))
        except ValueError:
            raise ApiError("Opcje liczbowe zawieraja niepoprawna wartosc.")
        return cfg

    def log(self, msg):
        self.q.put(("log", msg))

    def set_ui(self, key, val):
        self.q.put(("set", key, val))

    def poll(self):
        try:
            while True:
                it = self.q.get_nowait()
                if it[0] == "log":
                    self.logw.config(state="normal")
                    self.logw.insert("end", "[%s] %s\n" % (time.strftime("%H:%M:%S"), it[1]))
                    self.logw.see("end")
                    self.logw.config(state="disabled")
                elif it[0] == "set":
                    k, val = it[1], it[2]
                    if k == "ah":
                        self.v["ah"].set(val)
                    elif k == "ah_values":
                        self.ah_box["values"] = val
                elif it[0] == "done":
                    self.busy = False
                    self.btn_run.config(state="normal")
        except queue.Empty:
            pass
        self.after(100, self.poll)

    def tick_status(self):
        if self.busy:
            self.status.config(text="Pracuje...")
        elif self.auto and self.next_t:
            self.status.config(text="Auto: nastepne za %d min" % max(0, int((self.next_t - time.time()) / 60) + 1))
        else:
            self.status.config(text="Gotowy.")
        self.after(1000, self.tick_status)

    def pick_dir(self):
        d = filedialog.askdirectory(title="Folder addonu TsmAnalize")
        if d:
            self.v["addon_dir"].set(os.path.normpath(d))

    def detect(self):
        found = detect_addon_dirs()
        if not found:
            self.log("Nie znaleziono folderu TsmAnalize automatycznie - wybierz recznie.")
        else:
            self.v["addon_dir"].set(found[0])
            self.log("Wykryto: " + " | ".join(found))

    def worker(self, fn):
        def wrap():
            try:
                fn()
            except ApiError as e:
                self.log("BLAD: %s" % e)
            except Exception:
                self.log("BLAD (nieoczekiwany):\n" + traceback.format_exc())
            finally:
                self.q.put(("done",))
        self.busy = True
        self.btn_run.config(state="disabled")
        threading.Thread(target=wrap, daemon=True).start()

    # --- akcje
    def test(self):
        if self.busy:
            return
        try:
            cfg = self.collect()
        except ApiError as e:
            return self.log("BLAD: %s" % e)

        def job():
            api = Blizz(cfg["client_id"], cfg["client_secret"], cfg["region"])
            ns = api.namespace(cfg.get("namespace", ""))
            rs = parse_ruleset(cfg)
            ahs = api.list_ah(rs, ns)
            self.set_ui("ah_values", ["%s - %d" % (n, i) for i, n in ahs])
            self.log("Polaczenie OK. Namespace: %s, ruleset %d. Domy aukcyjne: %s" %
                     (ns, rs, ", ".join("%s (%d)" % (n, i) for i, n in ahs)))
            self.log("Uwaga: ten sam dom moze zwracac te same dane przez rozne rulesety (znany dziwny przypadek: 116) - porownaj ceny z gra.")
        self.worker(job)

    def backtest(self):
        if self.busy:
            return
        if flow is None:
            return self.log("BLAD: brak flow.py obok AuctionEngine.py.")

        def job():
            files = sorted(glob.glob(os.path.join(DATA_DIR, "history_forever_*.sqlite")), key=os.path.getmtime)
            if not files:
                raise ApiError("Brak bazy historii - najpierw pobierz dane (kilka dni auto-odswiezania).")
            self.log("Backtest na: %s (moze potrwac minute)..." % os.path.basename(files[-1]))
            calib, rep = flow.run_backtest(files[-1])
            for line in rep:
                self.log(line)
            if "zs" in calib or "disp" in calib:
                write_atomic(CALIB_PATH, json.dumps(calib, indent=2))
                self.log("Zapisano calib.json - trafi do BlizzData.lua przy nastepnym eksporcie.")
            else:
                self.log("Za malo danych na kalibracje - calib.json bez zmian.")
        self.worker(job)

    def start_run(self, force=True):
        if self.busy:
            return self.log("Pobieranie juz trwa - pomijam.")
        try:
            cfg = self.collect()
        except ApiError as e:
            return self.log("BLAD: %s" % e)
        self.cfg = {k: v for k, v in cfg.items() if not k.startswith("_")}
        save_cfg(self.cfg)
        self.worker(lambda: run_once(cfg, self.log, self.set_ui, force=force))

    def toggle_auto(self):
        self.auto = not self.auto
        if self.auto:
            self.btn_auto.config(text="Zatrzymaj auto-odswiezanie")
            self.auto_tick()
        else:
            self.btn_auto.config(text="Start auto-odswiezania")
            if self.after_id:
                self.after_cancel(self.after_id)
            self.next_t = None

    def auto_tick(self):
        if not self.auto:
            return
        self.start_run(force=False)
        try:
            iv = max(5, int(float(self.v["interval_min"].get()))) * 60
        except ValueError:
            iv = 1800
        self.next_t = time.time() + iv
        self.after_id = self.after(iv * 1000, self.auto_tick)

    def on_close(self):
        try:
            self.cfg.update(self.collect())
            save_cfg({k: v for k, v in self.cfg.items() if not k.startswith("_")})
        except Exception:
            pass
        self.destroy()

if __name__ == "__main__":
    if tk is None:
        print("Brak tkinter - zainstaluj Pythona z modulem tcl/tk.")
        sys.exit(1)
    App().mainloop()