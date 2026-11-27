# Zmiany w istniejących plikach (ręcznie, każda mała)

## Hub.lua — naprawa drabiny dla Risk.lua
Zamień `local live = {}               -- [itemID] = zywe oferty z AH` na:
```lua
local live = {}               -- [itemID] = zywe oferty z AH
ns.live = live                -- Risk.lua (LadderAhead) czyta ns.live
```

## TsmAnalize.toc — kolejność (zastępuje wcześniejsze wpisy)
```
Profit.lua
Pipeline.lua
Forecast.lua
Online.lua
Weekly.lua
Ladder.lua
AnalyzeCache.lua
...
Exposure.lua
Tracker.lua
Todo.lua
```
`Pipeline.lua` zaraz po `Profit.lua` (zapamiętuje rdzeń Analyze). Forecast i Ladder rejestrują się jako etapy (`ns.AddStage`), więc ich kolejność względem siebie nie ma znaczenia. `Online.lua` przed `Weekly.lua` (Weekly opakowuje `ns.FcFor`). Podgląd: `/tsma stages`.

## Harness (tests/harness.lua) — nowe moduły
W tablicy `FILES` ustaw kolejność jak w .toc (obecna lista jest nieaktualna) i dopisz `"Pipeline","Forecast","Online","Weekly","Ladder","Tracker","Todo"` po `"Profit"`/na końcu wg powyższego. Do listy `cmds`: `"data","flip","flow","size","online","weekly","todo","arb","fc","stages"`.
Osobny test logiki nowych modułów: `pytest tests/test_new_modules.py` (ustaw `TSMA_ADDON`, jeśli folder addonu jest gdzie indziej).

## TsmAnalize.toc — pliki danych silnika
Kody (po `Profit.lua`, przed `AnalyzeCache.lua`; kolejność ma znaczenie):
```
Profit.lua
Forecast.lua
Weekly.lua
Ladder.lua
AnalyzeCache.lua
```
Na końcu listy: `Todo.lua`. Pliki danych (`BlizzForecast.lua`, `BlizzArb.lua`, `BlizzSnipe.lua`) dopisze `ensure_toc` po zmianie niżej.
Nowe pliki w .toc wymagają PEŁNEGO restartu gry, nie /reload.

## Hub.lua — zakładka „Co teraz" (5 małych zmian)
1. W `TABS` dodaj linię po `{ "gaps", "Luki cenowe" },`:
```lua
    { "gaps", "Luki cenowe" },
    { "todo", "Co teraz" },
```
(przed `{ "watch", "Lista / zakupy", embed = "TsmAnalizeWatch" },`; strona powstaje sama w pętli budującej `pages`)
2. W `BuildHub`, po `BuildGaps(pages.gaps)`:
```lua
    if ns.BuildTodo then ns.BuildTodo(pages.todo) end
    wheel.todo = function(delta) if ns.TodoWheel then ns.TodoWheel(delta) end end
```
3. W `RefreshHub`, po gałęzi `elseif view == "gaps" then RefreshGaps()`:
```lua
    elseif view == "todo" then
        if ns.RefreshTodo then ns.RefreshTodo() end
```
4. W `HubCommand`, w tabeli `map` po `lista = "watch",` dopisz `todo = "todo", teraz = "todo",`.
Zakładka otwiera się też przez `/tsma hub todo`. `Todo.lua` musi być w `.toc` (wystarczy gdziekolwiek: strona jest budowana przy ADDON_LOADED).

## UI.lua — prognoza w zakładce Rynek (po linii `market[#market + 1] = { "Sr. sprzedazy (region)", ns.Money(d.regionSale) }`)
```lua
    if r.fc then
        for _, h in ipairs({ 6, 24, 72 }) do
            local l = ns.FcLine(r.fc, h)
            if l then market[#market + 1] = { "Prognoza min +" .. h .. "h", l } end
        end
    end
```
(STAT_ROWS = 12 może uciąć wiersze; podnieś do 15.)

## AuctionEngine.py
1. Importy (obok `import flow`):
```python
try:
    import engine_ext as ext
except ImportError:
    ext = None
```
2. `TOC_FILES = ("BlizzData.lua", "BlizzHist.lua", "BlizzForecast.lua", "BlizzArb.lua", "BlizzSnipe.lua", "Blizz.lua")`
3. `lua_blizz`: po bloku `if "fd" in e:` dodaj
```python
        if e.get("lad"):
            s += ',lad="%s"' % e["lad"]
```
4. `write_outputs`: po pętli zapisu `for t in targets:` dodaj do jej ciała
```python
        for fname, text in (cfg.get("_extra") or {}).items():
            write_atomic(os.path.join(t, fname), text)
```
5. `run_once`: PRZED `flow.update_flow` (tabela `live` jest tam nadpisywana):
```python
    prev_ids = ext.load_live_ids(db_path) if ext else set()
```
a `db_path` musi być zdefiniowane wcześniej (już jest). Po `entries, deals = build_entries(...)`:
```python
    extra = {}
    if ext:
        ext.attach_ladders(entries, auctions, int(float(cfg["import_min_g"]) * 10000))
        neutral_fn = lambda i, n: i in NEUTRAL_HOUSES or "neutral" in n.lower() or "blackwater" in n.lower()
        extra = ext.build_extras(cfg, api, rs, ns, aid, aname, ahs, auctions, entries, cut, now, db_path,
                                 prev_ids, neutral_fn, log)
    cfg = dict(cfg, _hist=hist, _histq=histq, _calib=load_calib(), _extra=extra)
```
(zastępuje istniejącą linię `cfg = dict(cfg, ...)`).
6. `DEFAULTS`: `"history_days": 21` (prognoza 72 h potrzebuje ≥ 14 dni), plus
`"reset_dow": 3` (dzień resetu tygodnia, 0=niedz; EU = środa), `"events": ""` (daty patchy/nowej zawartości, np. "2026-12-01, 2026-12-15"; cecha prognozy), `"arb_on": True, "arb_min_g": 2, "arb_units": 40, "arb_max_houses": 3, "snipe_pct": 25, "snipe_min_g": 5`.
7. W `collect()` limit historii: `min(30, ...)` zostaje.
`pip install numpy lightgbm` (lightgbm opcjonalny; bez niego działa model ridge).
Dodaj `numpy` do requirements.txt; przy PyInstallerze `--collect-all lightgbm` jeśli używasz.

## Bezpieczeństwo
Client Secret z config.json trafił do czatu: wygeneruj nowy na develop.battle.net.
