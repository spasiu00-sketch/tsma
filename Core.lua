local ADDON, ns = ...

ns.cache = {}          -- ostatnie dane z TSM per przedmiot
ns.alertState = {}     -- stan alertow (zeby nie spamowac)

-- Skroty klawiszowe (Bindings.xml): naglowek i nazwy w menu Key Bindings
BINDING_HEADER_TSMA = "TSM Analize"
BINDING_NAME_TSMA_TOGGLE = "Pokaz/ukryj HUD"
BINDING_NAME_TSMA_PANEL = "Pokaz/ukryj panel (okazje, dziennik)"
BINDING_NAME_TSMA_CHART = "Duzy wykres"

-- Start ekonomii WoW Forever (4.11.2026 00:00 UTC). Zmienisz: /tsma start RRRR-MM-DD albo /tsma start off
local FOREVER_START = 1793750400

local DEFAULTS = {
    refreshMin    = 15,     -- co ile minut odswiezac dane z TSM
    house         = "faction", -- "faction" (cut = cut) albo "neutral" (cut = cutNeutral)
    cut           = 5,      -- prowizja frakcyjnego domu aukcyjnego w %
    cutNeutral    = 15,     -- prowizja neutralnego domu w %
    margin        = 10,     -- minimalny oczekiwany zysk netto w %
    undercut      = 1,      -- o ile copper podbijac konkurencje w dol
    minSaleRate   = 0.02,   -- ponizej tego sprzedaz uznajemy za wolna
    histEveryMin  = 30,     -- co ile minut zapisujemy punkt do historii
    histDays      = 14,     -- ile dni historii trzymamy
    perDayDiv     = 1,      -- dzielnik dla DBRegionSoldPerDay (sprawdz /tsma debug)
    scale         = 1,      -- skala HUD
    scanMinPrice  = 10000,  -- skaner: ignoruj przedmioty tansze niz 1g
    depositMin    = 100,    -- minimalny depozyt za aukcje (1s; po hotfixie moze byc 1c)
    depositPct    = 20,     -- depozyt jako % ceny u NPC (zalezy od dlugosci aukcji; sprawdz w grze)
    stackSize     = 1,      -- typowy rozmiar stosu przy wystawianiu (do minimalnego depozytu)
    capital       = 0,      -- kapital w copper (0 = nie licz limitu zakupu)
    exposurePct   = 5,      -- max % kapitalu w jednym przedmiocie
    stopLoss      = 10,     -- % ponizej break-even, przy ktorym alarmujemy
    predHours     = 24,     -- po ilu godzinach oceniamy trafnosc werdyktu
    economyStart  = FOREVER_START,
    refFormula    = "",     -- wzor TSM ceny odniesienia sprzedazy (puste = DBMarket z fallbackami)
    tooltip       = true,   -- werdykt w tooltipie
    alertBuy      = true,   -- alert gdy obserwowany przedmiot staje sie okazja
    alertUndercut = true,   -- alert gdy ktos podbil Twoja aukcje
    warnPost      = true,   -- ostrzezenie przy wystawieniu ponizej break-even / progu zysku / podejrzanie nisko
    mailLog       = true,   -- realny przychod z faktur AH na poczcie (nieprzeczytane maile "Auction successful")
    minimapShow   = true,   -- przycisk przy minimapie
    minimap       = { angle = 215 },
    logCharOnly   = false,  -- panel dziennika: tylko wpisy biezacej postaci
    useAvgBuy     = false,  -- uzyj sr. zakupu z TSM Accounting jako ceny zakupu
    youngMode     = true,   -- tryb mlodego rynku (mniejsza waga DBMarket)
    scanSkipHigh  = true,   -- skaner pomija przedmioty o wysokim ryzyku
    scanRequireRate = true, -- skaner pomija przedmioty bez sale rate
    scanSortDay   = false,  -- skaner: sortuj wg zysku na dobe zamiast wg % zysku
    autoLog       = true,   -- dziennik automatycznie z komunikatow AH (sprzedaz/wygasniecie) i hooka wystawiania
    watch         = {},     -- lista obserwowanych (itemString)
    items         = {},     -- historia: [itemString] = { hist = { {t, minbuy, market}, ... } }
    buyPrice      = {},     -- [itemString] = zapisana cena zakupu (copper / szt.)
    alerts        = {},     -- [itemString] = prog alertu (copper)
    lots          = {},     -- [itemString] = { qty, cost } - biezacy stan zakupow
    log           = {},     -- dziennik transakcji
    preds         = {},     -- zapisane prognozy werdyktow (do oceny trafnosci)
    predLast      = {},     -- [itemString] = czas ostatniej prognozy
    accAgg        = {},     -- zagregowana trafnosc ocenionych prognoz: [werdykt] = { n, ok, okMargin, chg }
    totals        = { profit = 0, spent = 0, sells = 0, lost = 0 }, -- sumy ze starych wpisow dziennika (po obcieciu do 300)
    openPosts     = {},     -- [itemString] = { {t, qty, price}, ... } - wystawione aukcje czekajace na sprzedaz/wygasniecie
    depositReal   = {},     -- [itemString] = realny depozyt za szt. (odczytany z AH przy wystawianiu)
    depCal        = { n = 0, sum = 0 }, -- srednia relacja depozytu do ceny NPC (kalibracja depositPct)
    selected      = nil,
    pos           = nil,
    shown         = true,
    panelShown    = false,
}

-- Pola ustawien: wspolne dla okna ustawien i komendy /tsma set (kind: num / money / text)
ns.FIELDS = {
    { key = "refreshMin",   label = "Odswiezanie (min)",            kind = "num",   min = 1,   max = 240, int = true },
    { key = "cut",          label = "Prowizja frakcyjna (%)",       kind = "num",   min = 0,   max = 99 },
    { key = "cutNeutral",   label = "Prowizja neutralna (%)",       kind = "num",   min = 0,   max = 99 },
    { key = "margin",       label = "Min. zysk (%)",                kind = "num",   min = 0,   max = 1000 },
    { key = "undercut",     label = "Undercut (wpisz 1c; '1' = 1g)", kind = "money", min = 0,   max = 1e9 },
    { key = "minSaleRate",  label = "Min. sale rate (0-1)",         kind = "num",   min = 0,   max = 1 },
    { key = "histEveryMin", label = "Zapis historii co (min)",      kind = "num",   min = 5,   max = 240, int = true },
    { key = "histDays",     label = "Historia (dni, 1-30)",         kind = "num",   min = 1,   max = 30,  int = true },
    { key = "predHours",    label = "Ocena prognozy po (h)",        kind = "num",   min = 1,   max = 168, int = true },
    { key = "perDayDiv",    label = "Dzielnik SoldPerDay",          kind = "num",   min = 0.01, max = 1e6 },
    { key = "scale",        label = "Skala HUD (0.6-1.5)",          kind = "num",   min = 0.6, max = 1.5 },
    { key = "depositMin",   label = "Min. depozyt (np. 1s)",        kind = "money", min = 0,   max = 1e9 },
    { key = "depositPct",   label = "Depozyt (% ceny NPC)",         kind = "num",   min = 0,   max = 100 },
    { key = "stackSize",    label = "Typowy stos przy wystawianiu", kind = "num",   min = 1,   max = 1000, int = true },
    { key = "capital",      label = "Kapital (np. 500g, 0 = brak)", kind = "money", min = 0,   max = 1e11 },
    { key = "exposurePct",  label = "Max % kapitalu na przedmiot",  kind = "num",   min = 0,   max = 100 },
    { key = "stopLoss",     label = "Stop-loss (% pod break-even)", kind = "num",   min = 0,   max = 90 },
    { key = "scanMinPrice", label = "Skaner: min. cena (np. 1g)",   kind = "money", min = 0,   max = 1e10 },
    { key = "refFormula",   label = "Wzor ref. TSM (puste = auto)", kind = "text" },
}

ns.TOGGLES = {
    { key = "tooltip",        label = "Werdykt w tooltipie przedmiotu" },
    { key = "alertBuy",       label = "Alert gdy obserwowany = nowa okazja" },
    { key = "alertUndercut",  label = "Alert gdy ktos podbil moja aukcje" },
    { key = "warnPost",       label = "Ostrzegaj przy wystawieniu za nisko" },
    { key = "youngMode",      label = "Tryb mlodego rynku (mniej wagi DBMarket)" },
    { key = "scanSkipHigh",   label = "Skaner: pomijaj wysokie ryzyko" },
    { key = "scanRequireRate",label = "Skaner: wymagaj sale rate" },
    { key = "scanSortDay",    label = "Skaner: sortuj wg zysku/dobe" },
    { key = "autoLog",        label = "Auto-dziennik z czatu AH" },
    { key = "mailLog",        label = "Realny przychod z poczty (faktury AH)" },
    { key = "useAvgBuy",      label = "Cena zakupu = sr. zakup z TSM (gdy brak wlasnej)" },
    { key = "minimapShow",    label = "Przycisk przy minimapie",
      set = function(v)
          ns.db.minimapShow = v
          if ns.ApplyMinimap then ns.ApplyMinimap() end
      end },
    { key = "house", label = "Neutralny dom aukcyjny (wyzsza prowizja)",
      get = function() return ns.db.house == "neutral" end,
      set = function(v) ns.db.house = v and "neutral" or "faction" end },
}

------------------------------------------------------------------
-- Pomocnicze
------------------------------------------------------------------
function ns.Print(msg)
    print("|cff33aaffTSMA|r: " .. tostring(msg))
end

local errShown = {}
ns.errors = {}   -- [tag] = { n, msg, t } - podglad: /tsma errors
-- Wywoluje funkcje bezpiecznie; blad pokazuje na czacie tylko raz na tag, ale zapamietuje wszystkie
function ns.Safe(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local e = ns.errors[tag]
        if not e then e = { n = 0 }; ns.errors[tag] = e end
        e.n = e.n + 1
        e.msg = tostring(err)
        e.t = time()
        if not errShown[tag] then
            errShown[tag] = true
            ns.Print("Blad (" .. tag .. "): " .. tostring(err) .. "  (wszystkie: /tsma errors)")
        end
    end
    return ok
end

function ns.Cut()
    local db = ns.db
    if db.house == "neutral" then return db.cutNeutral end
    return db.cut
end

-- nazwa biezacej postaci (do wpisow dziennika)
function ns.Who()
    return UnitName("player") or "?"
end

-- Czas UTC z daty (niezalezny od strefy lokalnej; algorytm days-from-civil)
function ns.UTCTime(y, m, d, hh)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + (hh or 0) * 3600
end

------------------------------------------------------------------
-- Pieniadze w formacie WoW: 1g 1s 1c
------------------------------------------------------------------
local GOLD, SILVER, COPPER = "|cffffd700", "|cffc7c7cf", "|cffeda55f"

local function commas(n)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

function ns.Money(c)
    if c == nil then return "|cff888888--|r" end
    local neg = c < 0
    c = math.floor(math.abs(c) + 0.5)
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local cc = c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = GOLD .. commas(g) .. "g|r" end
    if g > 0 or s > 0 then parts[#parts + 1] = SILVER .. s .. "s|r" end
    parts[#parts + 1] = COPPER .. cc .. "c|r"
    local out = table.concat(parts, " ")
    if neg then out = "|cffff4040-|r" .. out end
    return out
end

-- bez kolorow, do pol tekstowych: "12g 50s 3c"
function ns.MoneyPlain(c)
    if not c then return "" end
    c = math.floor(math.abs(c) + 0.5)
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local cc = c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "g" end
    if g > 0 or s > 0 then t[#t + 1] = s .. "s" end
    t[#t + 1] = cc .. "c"
    return table.concat(t, " ")
end

-- "12g 50s 3c", "12.5g", "50s", "12" (czyli 12 zlota)
function ns.ParseMoney(str)
    if not str or str:match("^%s*$") then return nil end
    str = str:lower():gsub(",", "")
    local total, found = 0, false
    for num, unit in str:gmatch("([%d%.]+)%s*([gsc])") do
        local n = tonumber(num)
        if n then
            found = true
            total = total + n * (unit == "g" and 10000 or (unit == "s" and 100 or 1))
        end
    end
    if found then return math.floor(total + 0.5) end
    local n = tonumber(str:match("^%s*([%d%.]+)%s*$"))
    if n then return math.floor(n * 10000 + 0.5) end
    return nil
end

function ns.ProfitStr(net, pct)
    if net == nil then return "" end
    if net >= 0 then
        return "|cff33dd66+|r" .. ns.Money(net) .. string.format(" |cff33dd66(%+.1f%%)|r", pct)
    end
    return ns.Money(net) .. string.format(" |cffff4040(%+.1f%%)|r", pct)
end

ns.VERDICT = {
    BUY      = "|cff33dd66OPLACA SIE - KUP|r",
    MARGINAL = "|cffffcc33GRANICZNIE / RYZYKOWNE|r",
    NO       = "|cffff4040NIE OPLACA SIE|r",
    NODATA   = "|cff999999BRAK DANYCH Z TSM|r",
}
ns.VERDICT_SHORT = {
    BUY      = "|cff33dd66KUP|r",
    MARGINAL = "|cffffcc33GRANICZNIE|r",
    NO       = "|cffff4040NIE|r",
    NODATA   = "|cff999999brak danych|r",
}
ns.RISK_TEXT = {
    LOW  = "|cff33dd66NISKIE|r",
    MED  = "|cffffcc33SREDNIE|r",
    HIGH = "|cffff4040WYSOKIE|r",
}
ns.RISK_LETTER = {
    LOW  = "|cff33dd66N|r",
    MED  = "|cffffcc33S|r",
    HIGH = "|cffff4040W|r",
}

------------------------------------------------------------------
-- TSM Addon API
------------------------------------------------------------------
function ns.HasTSM()
    return type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function"
end

-- surowa wartosc (do /tsma debug)
function ns.RawTSM(src, itemString)
    if not ns.HasTSM() then return false, "TSM_API brak" end
    return pcall(TSM_API.GetCustomPriceValue, src, itemString)
end

local function tsmValue(src, itemString)
    if not ns.HasTSM() then return nil end
    local ok, v = pcall(TSM_API.GetCustomPriceValue, src, itemString)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil
end

function ns.FetchTSM(itemString)
    return {
        minbuy       = tsmValue("DBMinBuyout", itemString),       -- aktualna najnizsza cena
        market       = tsmValue("DBMarket", itemString),          -- wazona srednia 14 dni
        recent       = tsmValue("DBRecent", itemString),          -- ostatnio widziana
        historical   = tsmValue("DBHistorical", itemString),
        regionMarket = tsmValue("DBRegionMarketAvg", itemString),
        regionSale   = tsmValue("DBRegionSaleAvg", itemString),   -- srednia cena sprzedazy
        saleRate     = tsmValue("DBRegionSaleRate", itemString),
        perDay       = tsmValue("DBRegionSoldPerDay", itemString),
        crafting     = tsmValue("Crafting", itemString),          -- koszt wytworzenia (jesli masz recepte)
        avgBuy       = tsmValue("avgBuy", itemString),            -- Twoj sr. zakup z TSM Accounting
        vendorSell   = tsmValue("vendorSell", itemString),        -- cena u NPC (do depozytu)
    }
end

------------------------------------------------------------------
-- Przedmioty
------------------------------------------------------------------
local function itemIDOf(itemString)
    return tonumber((itemString or ""):match("^i:(%d+)"))
end

-- link / "i:123" / ID / nazwa -> itemString
function ns.ResolveItem(text)
    if not text then return nil end
    text = strtrim(text)
    if text == "" then return nil end

    local id = text:match("item:(%d+)")
    if id then
        if ns.HasTSM() and TSM_API.ToItemString then
            local ok, r = pcall(TSM_API.ToItemString, text)
            if ok and r then return r end
        end
        return "i:" .. id
    end

    local direct = text:match("^(i:[%w:]+)")
    if direct then return direct end

    local n = tonumber(text)
    if n then return "i:" .. n end

    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if getInstant then
        local itemID = getInstant(text)
        if itemID then return "i:" .. itemID end
    end
    return nil
end

function ns.ItemName(itemString)
    if ns.HasTSM() and TSM_API.GetItemName then
        local ok, n = pcall(TSM_API.GetItemName, itemString)
        if ok and n then return n end
    end
    local id = itemIDOf(itemString)
    if id and C_Item and C_Item.GetItemNameByID then
        local n = C_Item.GetItemNameByID(id)
        if n then return n end
    end
    return itemString
end

function ns.ItemIcon(itemString)
    local id = itemIDOf(itemString)
    if id then
        if C_Item and C_Item.GetItemIconByID then
            return C_Item.GetItemIconByID(id) or 134400
        end
        if GetItemIcon then return GetItemIcon(id) end
    end
    return 134400
end

function ns.ItemLink(itemString)
    if ns.HasTSM() and TSM_API.GetItemLink then
        local ok, l = pcall(TSM_API.GetItemLink, itemString)
        if ok and l then return l end
    end
    return ns.ItemName(itemString)
end

------------------------------------------------------------------
-- Historia (wlasne snapshoty, bo TSM API nie daje min/max z 14 dni)
------------------------------------------------------------------
local function getRec(itemString)
    local rec = ns.db.items[itemString]
    if not rec then
        rec = { hist = {} }
        ns.db.items[itemString] = rec
    end
    return rec
end

-- Punkty starsze niz 3 dni zostawiamy co ~2h (mniejszy plik SavedVariables, szybszy login)
local COMPACT_AGE, COMPACT_STEP = 3 * 86400, 7200
local function compactHist(h, now)
    local limit = now - COMPACT_AGE
    if not (h[1] and h[1][1] < limit) then return end
    local out, lastB = {}, nil
    for _, p in ipairs(h) do
        if p[1] >= limit then
            out[#out + 1] = p
        else
            local b = math.floor(p[1] / COMPACT_STEP)
            if b ~= lastB then out[#out + 1] = p; lastB = b end
        end
    end
    if #out < #h then
        for i = #h, 1, -1 do h[i] = nil end
        for i, p in ipairs(out) do h[i] = p end
    end
end

function ns.Record(itemString, d)
    local db = ns.db
    local rec = getRec(itemString)
    local h = rec.hist
    local now = time()
    local last = h[#h]
    if (not last) or (now - last[1] >= db.histEveryMin * 60) then
        if d.minbuy or d.market then
            h[#h + 1] = { now, d.minbuy or 0, d.market or 0 }
        end
    end
    local cutoff = now - db.histDays * 86400
    while h[1] and h[1][1] < cutoff do table.remove(h, 1) end
    if now - (rec.compactT or 0) > 3600 then
        rec.compactT = now
        compactHist(h, now)
    end
end

local function medianOf(vals)
    local n = #vals
    if n == 0 then return nil end
    local sorted = {}
    for i, v in ipairs(vals) do sorted[i] = v end
    table.sort(sorted)
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- Mediana "aktualnej min" z ostatnich N sekund -> mediana, liczba punktow
function ns.HistMedianSince(itemString, seconds)
    local rec = ns.db.items[itemString]
    if not rec then return nil, 0 end
    local cutoff = time() - seconds
    local vals = {}
    for _, p in ipairs(rec.hist) do
        if p[1] >= cutoff and p[2] and p[2] > 0 then vals[#vals + 1] = p[2] end
    end
    return medianOf(vals), #vals
end

-- Zakres (min, max, liczba punktow) serii "aktualna min" z ostatnich N sekund
function ns.HistRange(itemString, seconds)
    local rec = ns.db.items[itemString]
    if not rec then return nil end
    local cutoff = time() - seconds
    local lo, hi, n = nil, nil, 0
    for _, p in ipairs(rec.hist) do
        local v = p[2]
        if p[1] >= cutoff and v and v > 0 then
            lo = lo and math.min(lo, v) or v
            hi = hi and math.max(hi, v) or v
            n = n + 1
        end
    end
    return lo, hi, n
end

-- Statystyki z serii "aktualna min": min/max/srednia/mediana/zmiennosc/trend/rozpietosc
function ns.HistStats(itemString)
    local rec = ns.db.items[itemString]
    if not rec then return nil end

    local pts, vals = {}, {}
    for _, p in ipairs(rec.hist) do
        local v = p[2]
        if v and v > 0 then
            pts[#pts + 1] = { p[1], v }
            vals[#vals + 1] = v
        end
    end
    local n = #vals
    if n == 0 then return nil end

    local sum, mn, mx = 0, vals[1], vals[1]
    for _, v in ipairs(vals) do
        sum = sum + v
        if v < mn then mn = v end
        if v > mx then mx = v end
    end
    local avg = sum / n
    local median = medianOf(vals)

    local var = 0
    for _, v in ipairs(vals) do var = var + (v - avg) ^ 2 end
    local stdevPct = math.sqrt(var / n) / avg * 100

    -- trend: regresja liniowa, nachylenie w % sredniej na dobe
    local trend
    local span = pts[n][1] - pts[1][1]
    if n >= 4 and span >= 43200 then
        local t1 = pts[1][1]
        local mxd, myd = 0, 0
        for _, p in ipairs(pts) do
            mxd = mxd + (p[1] - t1) / 86400
            myd = myd + p[2]
        end
        mxd, myd = mxd / n, myd / n
        local num, den = 0, 0
        for _, p in ipairs(pts) do
            local x = (p[1] - t1) / 86400
            num = num + (x - mxd) * (p[2] - myd)
            den = den + (x - mxd) ^ 2
        end
        if den > 0 then trend = (num / den) / avg * 100 end
    end

    return { min = mn, max = mx, avg = avg, median = median, stdevPct = stdevPct,
             trend = trend, n = n, spanDays = span / 86400 }
end

-- Import historii z pliku Import.lua (generowany skryptem tsm_history.py)
-- Zaimportowane punkty maja 4. element = 1 (do cofniecia: /tsma import undo)
function ns.MergeImport(itemString)
    local imp = _G.TsmAnalizeImport
    if type(imp) ~= "table" or type(imp.items) ~= "table" then return 0 end
    if ns.db.importOff ~= nil and ns.db.importOff == imp.generated then return 0 end
    local src = imp.items[itemString]
    if type(src) ~= "table" then return 0 end

    local rec = getRec(itemString)
    if rec.importStamp and rec.importStamp == imp.generated then return 0 end

    local have = {}
    for _, p in ipairs(rec.hist) do have[p[1]] = true end
    local cutoff = time() - ns.db.histDays * 86400
    local added = 0
    for _, p in ipairs(src) do
        local t = p[1]
        if type(t) == "number" and t >= cutoff and not have[t] then
            rec.hist[#rec.hist + 1] = { t, p[2] or 0, p[3] or 0, 1 }
            have[t] = true
            added = added + 1
        end
    end
    table.sort(rec.hist, function(a, b) return a[1] < b[1] end)
    rec.importStamp = imp.generated
    return added
end

-- Cofniecie importu: usuwa punkty oznaczone jako zaimportowane i blokuje ponowny import tego pliku
function ns.UndoImport()
    local imp = _G.TsmAnalizeImport
    local removed = 0
    for _, rec in pairs(ns.db.items) do
        local h, out = rec.hist, {}
        for _, p in ipairs(h) do
            if p[4] then removed = removed + 1 else out[#out + 1] = p end
        end
        if #out < #h then
            for i = #h, 1, -1 do h[i] = nil end
            for i, p in ipairs(out) do h[i] = p end
        end
        rec.importStamp = nil
    end
    ns.db.importOff = (type(imp) == "table" and imp.generated) or 0
    return removed
end

function ns.RedoImport()
    ns.db.importOff = nil
    local added = 0
    for s in pairs(ns.db.items) do added = added + ns.MergeImport(s) end
    return added
end

------------------------------------------------------------------
-- Cena zakupu: zapisana > TSM avgBuy (opcja) > aktualna min
------------------------------------------------------------------
function ns.EffectiveBuy(itemString, d)
    local db = ns.db
    if db.buyPrice[itemString] then return db.buyPrice[itemString], "zapisana" end
    if db.useAvgBuy and d and d.avgBuy then return d.avgBuy, "TSM sr. zakup" end
    return nil, "akt. min"
end

------------------------------------------------------------------
-- Mlody rynek, depozyt, ryzyko, limit zakupu
------------------------------------------------------------------
-- Ile ufamy DBMarket (0.25-1), na podstawie wieku ekonomii wzgledem okna historii
function ns.EconomyTrust()
    local db = ns.db
    local start = db.economyStart or 0
    if start <= 0 then return 1, nil end
    local age = (time() - start) / 86400
    if age >= db.histDays then return 1, age end
    if age < 0 then age = 0 end
    return math.max(0.25, age / db.histDays), age
end

-- Depozyt za 1 szt. przy aukcji, ktora wygasnie (zwracany tylko gdy sie sprzeda).
-- Kolejnosc: realny depozyt z AH dla tego przedmiotu > skalibrowany % ceny NPC > ustawienie depositPct
function ns.DepositPerUnit(d, itemString)
    local db = ns.db
    d = d or {}
    local real = itemString and db.depositReal and db.depositReal[itemString]
    if real then return real end
    local stack = math.max(1, db.stackSize or 1)
    local cal = db.depCal
    local pct = (cal and cal.n >= 3) and (cal.sum / cal.n * 100) or db.depositPct
    local byPct = (d.vendorSell or 0) * (pct / 100)
    return math.max((db.depositMin or 0) / stack, byPct)
end

function ns.RiskScore(itemString, d, hs)
    local db = ns.db
    local score, why = 0, {}
    local function add(n, txt)
        score = score + n
        why[#why + 1] = txt
    end

    if not d.saleRate then
        add(30, "brak danych o sprzedazy")
    elseif d.saleRate < db.minSaleRate then
        add(30, "wolna sprzedaz")
    elseif d.saleRate < db.minSaleRate * 2 then
        add(10, "sprzedaz ponizej sredniej")
    end

    if not hs or hs.n < 8 then
        add(15, "malo wlasnych danych")
    else
        if hs.stdevPct > 40 then add(25, "bardzo duza zmiennosc")
        elseif hs.stdevPct > 25 then add(15, "duza zmiennosc")
        elseif hs.stdevPct > 12 then add(5, "umiarkowana zmiennosc") end
        if hs.trend then
            if hs.trend <= -3 then add(20, "cena spada")
            elseif hs.trend <= -1.5 then add(8, "cena lekko spada") end
        end
    end

    if d.minbuy and d.market then
        if d.minbuy > d.market * 1.25 then add(10, "cena nad rynkiem")
        elseif d.minbuy < d.market * 0.5 then add(10, "cena podejrzanie niska") end
    end

    local trust = ns.EconomyTrust()
    if trust < 1 then add(math.floor((1 - trust) * 20), "mlody rynek") end

    score = math.min(100, score)
    local level = (score < 25 and "LOW") or (score < 50 and "MED") or "HIGH"
    -- p = SZACUNKOWE prawdopodobienstwo sprzedazy (heurystyka z ryzyka),
    -- zastapione wlasna statystyka z dziennika (sprzedane / (sprzedane + wygasle)), gdy jest >= 10 rozliczonych sztuk
    local p = math.max(0.25, math.min(0.9, 0.9 - score / 100 * 0.6))
    local pOwn, nOwn
    if ns.OwnSellProb then
        local po, n = ns.OwnSellProb(itemString)
        if po and n >= 10 then
            p = math.max(0.05, math.min(0.95, po))
            pOwn, nOwn = true, n
        end
    end
    return { score = score, level = level, p = p, why = why, pOwn = pOwn, nOwn = nOwn }
end

-- Ile sztuk mozna kupic w ramach limitu ekspozycji (nil gdy kapital nie ustawiony)
function ns.MaxUnits(itemString, r)
    local db = ns.db
    if not db.capital or db.capital <= 0 or not r.buy or r.buy <= 0 then return nil end
    local frac = ({ LOW = 1, MED = 0.5, HIGH = 0.2 })[r.risk.level] or 0.2
    local cap = db.capital * (db.exposurePct / 100) * frac
    local lot = db.lots[itemString]
    local held = lot and lot.cost or 0
    local room = cap - held
    if room <= 0 then return 0 end
    return math.floor(room / r.buy)
end

------------------------------------------------------------------
-- Analiza oplacalnosci
------------------------------------------------------------------
function ns.Analyze(itemString, d, buy)
    local db = ns.db
    local keep = 1 - ns.Cut() / 100
    local hs = ns.HistStats(itemString)
    local r = { d = d, notes = {}, hs = hs }

    -- cena odniesienia sprzedazy (w mlodym rynku konserwatywnie); opcjonalnie wlasny wzor TSM
    local base = d.market or d.recent or d.regionSale or d.minbuy
    local formulaFailed = false
    if db.refFormula and db.refFormula ~= "" then
        local fv = tsmValue(db.refFormula, itemString)
        if fv then
            base = fv
            r.formulaUsed = true
        else
            formulaFailed = true
        end
    end
    r.marketRaw = base
    local ref = base
    local trust, age = ns.EconomyTrust()
    r.trust, r.age = trust, age
    if db.youngMode and trust < 1 and base then
        local med, n = ns.HistMedianSince(itemString, 72 * 3600)
        local alt = (n >= 6 and med) or d.recent
        if alt then
            ref = math.min(base, trust * base + (1 - trust) * alt)
            r.youngAdj = true
        end
    end
    r.sellRef = ref

    r.risk = ns.RiskScore(itemString, d, hs)
    r.deposit = ns.DepositPerUnit(d, itemString)
    local p = r.risk.p

    -- maksymalna cena kupna: najwyzsza cena, przy ktorej zysk wg ref. spelnia margines i zysk oczekiwany > 0
    if r.sellRef then
        local byMargin = r.sellRef * keep / (1 + db.margin / 100)
        local byExp = r.sellRef * keep - (1 - p) / p * r.deposit
        local mb = math.floor(math.min(byMargin, byExp))
        if mb > 0 then r.maxBuy = mb end
    end

    -- crafting: zysk ze sprzedazy po cenie odniesienia
    if d.crafting and r.sellRef then
        r.craftCost = d.crafting
        r.craftProfit = r.sellRef * keep - d.crafting
        r.craftPct = r.craftProfit / d.crafting * 100
        r.craftExpectedPct = (p * r.craftProfit - (1 - p) * r.deposit) / d.crafting * 100
    end

    r.buy = buy or d.minbuy
    r.buyIsOwn = buy ~= nil
    if not r.buy or not r.sellRef then
        r.verdict = "NODATA"
        return r
    end

    -- Twoja aukcja: najnizsza (wtedy DBMinBuyout to prawdopodobnie Ty) albo podbita
    local own = ns.OwnLowest and ns.OwnLowest(itemString)
    r.own = own
    r.ownLowest = (own and d.minbuy and own <= d.minbuy) and true or false

    local function profit(P)
        local net = P * keep - r.buy
        return net, net / r.buy * 100
    end

    r.breakEven = math.ceil(r.buy / keep)
    r.minList = math.ceil(r.buy * (1 + db.margin / 100) / keep)
    r.target = r.sellRef
    r.targetProfit, r.targetPct = profit(r.target)

    -- "szybka" cena = undercut minimum; gdy minimum to Twoja oferta, nie podbijamy samych siebie
    if d.minbuy and not r.ownLowest then
        r.fast = math.max(d.minbuy - db.undercut, 1)
        r.fastProfit, r.fastPct = profit(r.fast)
    end

    -- proponowana cena: konkurencyjna, ale nigdy ponizej progu zysku
    local competitive = r.fast and math.min(r.fast, r.target) or r.target
    r.suggest = math.max(r.minList, competitive)
    r.suggestProfit, r.suggestPct = profit(r.suggest)

    -- zysk oczekiwany (sprzedaz po cenie odniesienia): p * zysk - (1-p) * utracony depozyt
    r.expected = p * r.targetProfit - (1 - p) * r.deposit
    r.expectedPct = r.expected / r.buy * 100

    if r.targetPct >= db.margin and r.expectedPct > 0 then
        r.verdict = (r.risk.level == "HIGH") and "MARGINAL" or "BUY"
    elseif r.targetPct > 0 and r.expectedPct > 0 then
        r.verdict = "MARGINAL"
    else
        r.verdict = "NO"
    end

    local falling = hs and hs.n >= 8 and hs.trend and hs.trend <= -3
    if falling and r.verdict == "BUY" then r.verdict = "MARGINAL" end

    r.maxUnits = ns.MaxUnits(itemString, r)

    -- uwagi (od najwazniejszych)
    if own and d.minbuy then
        if r.ownLowest then
            r.notes[#r.notes + 1] = string.format("Twoja aukcja jest najnizsza (%s) - DBMinBuyout to pewnie Ty.", ns.MoneyPlain(own))
        else
            r.notes[#r.notes + 1] = string.format("Twoja aukcja (%s) jest podbita - min rynku %s.",
                ns.MoneyPlain(own), ns.MoneyPlain(d.minbuy))
        end
    end
    if r.youngAdj then
        r.notes[#r.notes + 1] = string.format("Mlody rynek (%.0f dni): DBMarket z waga %.0f%%.", age or 0, trust * 100)
    end
    if formulaFailed then
        r.notes[#r.notes + 1] = "Wzor ref. nie zwrocil ceny - uzyto DBMarket."
    end
    if hs and hs.trend and math.abs(hs.trend) >= 3 then
        r.notes[#r.notes + 1] = string.format("Cena %s (%+.1f%%/dobe)%s.", hs.trend > 0 and "rosnie" or "spada", hs.trend,
            falling and " - poczekaj na stabilizacje" or "")
    end
    if r.risk.level ~= "LOW" then
        local top = {}
        for _, w in ipairs(r.risk.why) do
            if w ~= "mlody rynek" and w ~= "cena spada" and w ~= "cena lekko spada" and #top < 2 then
                top[#top + 1] = w
            end
        end
        if #top > 0 then r.notes[#r.notes + 1] = "Ryzyko: " .. table.concat(top, ", ") .. "." end
    end
    if not d.market then
        r.notes[#r.notes + 1] = "Brak DBMarket - uzyto ceny zastepczej."
    end
    if d.minbuy and d.market and d.minbuy > d.market * 1.25 then
        r.notes[#r.notes + 1] = "Aktualna cena 25%+ nad rynkiem - mozliwy chwilowy skok."
    end
    if r.deposit > 0 and r.suggest > 0 and r.deposit / r.suggest > 0.05 then
        r.notes[#r.notes + 1] = string.format("Depozyt to %.0f%% ceny - kosztowny przy wygasnieciu aukcji.", r.deposit / r.suggest * 100)
    end
    if hs and hs.n >= 5 then
        local diff = (r.buy / hs.median - 1) * 100
        if diff > 10 then
            r.notes[#r.notes + 1] = string.format("Kupno %.0f%% drozej niz mediana z %d dni.", diff, db.histDays)
        elseif diff < -10 then
            r.notes[#r.notes + 1] = string.format("Kupno %.0f%% taniej niz mediana z %d dni.", -diff, db.histDays)
        end
    end
    if r.suggest > competitive then
        r.notes[#r.notes + 1] = "Cena do zysku jest powyzej konkurencji - sprzedaz moze byc wolna."
    end
    return r
end

------------------------------------------------------------------
-- Prognozy werdyktow i ocena trafnosci
------------------------------------------------------------------
function ns.RecordPrediction(itemString, d)
    local db = ns.db
    local r = ns.Analyze(itemString, d, nil)  -- zakladamy zakup po aktualnej min
    if r.verdict == "NODATA" then return end
    local now = time()
    local last = db.predLast[itemString]
    if last and now - last < 6 * 3600 then return end
    db.predLast[itemString] = now
    db.preds[#db.preds + 1] = { t = now, s = itemString, v = r.verdict, buy = r.buy,
        be = r.breakEven, ml = r.minList }
    while #db.preds > 3000 do table.remove(db.preds, 1) end
end

-- Ocenione prognozy wpadaja do zagregowanych statystyk (db.accAgg) i znikaja z listy,
-- wiec limit listy nie obcina ocen, a lista zawiera tylko prognozy oczekujace na ocene
local function foldPred(p)
    local agg = ns.db.accAgg
    local a = agg[p.v]
    if not a then a = { n = 0, ok = 0, okMargin = 0, chg = 0 }; agg[p.v] = a end
    a.n = a.n + 1
    if p.ok then a.ok = a.ok + 1 end
    if p.okMargin then a.okMargin = a.okMargin + 1 end
    a.chg = a.chg + (p.chg or 0)
end

function ns.EvalPredictions()
    local db = ns.db
    local now = time()
    local horizon = db.predHours * 3600
    local pending = {}
    for _, p in ipairs(db.preds) do
        if not p.done and now - p.t >= horizon then
            local d = ns.cache[p.s]
            if d and d.minbuy then
                p.done = true
                p.chg = (d.minbuy / p.buy - 1) * 100
                p.ok = d.minbuy >= p.be       -- po czasie da sie wyjsc co najmniej na zero
                p.okMargin = d.minbuy >= p.ml -- po czasie da sie wyjsc z zakladanym zyskiem
            end
        end
        if p.done then
            foldPred(p)
        elseif now - p.t < horizon * 7 then   -- przedmiot juz nie sledzony: porzucamy po 7x horyzoncie
            pending[#pending + 1] = p
        end
    end
    db.preds = pending
end

function ns.AccuracyStats()
    return ns.db.accAgg
end

function ns.AccuracyLine()
    local st = ns.AccuracyStats()
    local a = st.BUY
    if not a or a.n == 0 then
        return string.format("Trafnosc werdyktow: brak danych (ocena po %dh od prognozy).", ns.db.predHours)
    end
    return string.format("Trafnosc KUP: %.0f%% bez straty, %.0f%% z zyskiem (n=%d), sr. zmiana ceny %+.1f%%",
        a.ok / a.n * 100, a.okMargin / a.n * 100, a.n, a.chg / a.n)
end

------------------------------------------------------------------
-- Wybor i odswiezanie
------------------------------------------------------------------
function ns.IsWatched(itemString)
    for i, s in ipairs(ns.db.watch) do
        if s == itemString then return i end
    end
    return nil
end

function ns.Select(itemString)
    ns.db.selected = itemString
    ns.MergeImport(itemString)
    if ns.HasTSM() then
        local d = ns.FetchTSM(itemString)
        ns.cache[itemString] = d
        ns.Record(itemString, d)
    end
    if ns.onSelect then ns.onSelect(itemString) end
    if ns.UpdateUI then ns.UpdateUI() end
    if ns.UpdatePanel then ns.UpdatePanel() end
end

-- zbior przedmiotow do odswiezania: obserwowane + wybrany + z zapasem (lots) + z otwartymi aukcjami
function ns.RefreshList()
    local set, list = {}, {}
    local function add(s)
        if s and not set[s] then set[s] = true; list[#list + 1] = s end
    end
    for _, s in ipairs(ns.db.watch) do add(s) end
    for s, lot in pairs(ns.db.lots) do
        if lot.qty and lot.qty > 0 then add(s) end
    end
    for s in pairs(ns.db.openPosts) do add(s) end
    add(ns.db.selected)
    return list
end

function ns.RefreshAll()
    local list = ns.RefreshList()

    if ns.HasTSM() then
        for _, s in ipairs(list) do
            local d = ns.FetchTSM(s)
            ns.cache[s] = d
            ns.Record(s, d)
        end
        ns.lastRefresh = time()
        ns.nextRefresh = ns.lastRefresh + ns.db.refreshMin * 60
        ns.Safe("pred", function()
            ns.EvalPredictions()
            for _, s in ipairs(list) do ns.RecordPrediction(s, ns.cache[s]) end
        end)
        if ns.CheckAlerts then ns.Safe("alerts", ns.CheckAlerts, list) end
    end
    if ns.UpdateUI then ns.UpdateUI() end
    if ns.UpdatePanel then ns.UpdatePanel() end
end

function ns.StartTicker()
    if ns.ticker then ns.ticker:Cancel() end
    ns.ticker = C_Timer.NewTicker(math.max(1, ns.db.refreshMin) * 60, function()
        ns.Safe("refresh", ns.RefreshAll)
    end)
end

-- Ustaw pole z ns.FIELDS z tekstu; zwraca ok, komunikat
function ns.SetField(fld, txt)
    if fld.kind == "text" then
        txt = strtrim(txt or "")
        if txt ~= "" and ns.HasTSM() and type(TSM_API.IsCustomPriceValid) == "function" then
            local ok, valid = pcall(TSM_API.IsCustomPriceValid, txt)
            if ok and not valid then
                return false, "Niepoprawny wzor TSM dla: " .. fld.label
            end
        end
        ns.db[fld.key] = txt
        if ns.InvalidateTips then ns.InvalidateTips() end
        return true
    end

    local val
    if fld.kind == "money" then val = ns.ParseMoney(txt) else val = tonumber(txt) end
    if val == nil or val < fld.min or val > fld.max then
        return false, "Niepoprawna wartosc dla: " .. fld.label
    end
    if fld.int then val = math.floor(val) end
    local old = ns.db[fld.key]
    ns.db[fld.key] = val
    if fld.key == "refreshMin" and old ~= val then ns.StartTicker() end
    if fld.key == "scale" and ns.ApplyScale then ns.ApplyScale() end
    return true
end

------------------------------------------------------------------
-- Start
------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        TsmAnalizeDB = TsmAnalizeDB or {}
        for k, v in pairs(DEFAULTS) do
            if TsmAnalizeDB[k] == nil then
                TsmAnalizeDB[k] = (type(v) == "table") and CopyTable(v) or v
            end
        end
        ns.db = TsmAnalizeDB

        -- sprzatanie historii przedmiotow, ktore nie sa obserwowane, wybrane, w zapasie ani z otwartymi aukcjami
        local keep = {}
        for _, s in ipairs(ns.db.watch) do keep[s] = true end
        for s, lot in pairs(ns.db.lots) do
            if lot.qty and lot.qty > 0 then keep[s] = true end
        end
        for s in pairs(ns.db.openPosts) do keep[s] = true end
        if ns.db.selected then keep[ns.db.selected] = true end
        for s in pairs(ns.db.items) do
            if not keep[s] then ns.db.items[s] = nil end
        end
        for s in pairs(keep) do ns.MergeImport(s) end

        ns.Safe("hooks", function() if ns.InitFeatures then ns.InitFeatures() end end)
        ns.Safe("ui", ns.BuildUI)
        ns.Safe("panels", function() if ns.BuildPanels then ns.BuildPanels() end end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- TSM wczytuje dane przy logowaniu, dajemy mu chwile
        C_Timer.After(5, function()
            ns.Safe("refresh", ns.RefreshAll)
            ns.StartTicker()
        end)
    end
end)
