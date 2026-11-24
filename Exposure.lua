local ADDON, ns = ...

------------------------------------------------------------------
-- EKSPOZYCJA NA KATEGORIE + WYJSCIE CZASOWE
--  1) limit kapitalu na kategorie przedmiotow (typ: podtyp z gry, np. "Trade Goods: Herb"):
--     przedmioty z jednej kategorii sa skorelowane, wiec 5 roznych ziol to jedna pozycja.
--     Obniza r.maxUnits (ns.MaxUnits) do reszty limitu kategorii; r.catCap = { cat, held, cap, units }.
--  2) wyjscie czasowe: towar w zapasie (db.lots) lezacy >= staleDays dni dostaje alert z cena wyjscia
--     (min rynku - undercut) i strata/zysk wzgledem sredniego kosztu. Alert raz na dobe na przedmiot.
-- Wymaga db.capital > 0 (jak limit per przedmiot). Wczytaj PO Profit.lua i PRZED AnalyzeCache.lua.
-- Komenda: /tsma exp
------------------------------------------------------------------

local DEFAULTS = { catExpOn = true, catExposurePct = 15, staleOn = true, staleDays = 5 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local catCache = {}

local function CatOf(s)
    local c = catCache[s]
    if c then return c end
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local gi = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if id and gi then
        local _, t, st = gi(id)
        if t and t ~= "" then
            c = (st and st ~= "" and st ~= t) and (t .. ": " .. st) or t
            catCache[s] = c
            return c
        end
    end
    return "Inne"
end

-- koszt zapasu per kategoria
local function Held()
    local by = {}
    for s, lot in pairs(ns.db.lots) do
        if lot.qty and lot.qty > 0 and lot.cost then
            local c = CatOf(s)
            by[c] = (by[c] or 0) + lot.cost
        end
    end
    return by
end

------------------------------------------------------------------
-- 1) Limit kategorii (opakowanie ns.MaxUnits wolanego z Analyze w Core.lua)
------------------------------------------------------------------
local origMaxUnits = ns.MaxUnits
function ns.MaxUnits(s, r)
    local m = origMaxUnits(s, r)
    local db = ns.db
    if m == nil or not (db and db.catExpOn) then return m end
    if not r.buy or r.buy <= 0 or (db.capital or 0) <= 0 then return m end
    local cat = CatOf(s)
    local cap = db.capital * (db.catExposurePct or 15) / 100
    local held = Held()[cat] or 0
    local room = cap - held
    local units = (room <= 0) and 0 or math.floor(room / r.buy)
    r.catCap = { cat = cat, held = held, cap = cap, units = units }
    return math.min(m, units)
end

------------------------------------------------------------------
-- 2) Wiek zapasu (db.lotAge[s] = czas zakupu najstarszej niesprzedanej partii, przyblizenie FIFO)
------------------------------------------------------------------
local origBuy, origSell = ns.Buy, ns.Sell

function ns.Buy(s, qty, price)
    origBuy(s, qty, price)
    local db = ns.db
    db.lotAge = db.lotAge or {}
    if not db.lotAge[s] then db.lotAge[s] = time() end
end

function ns.Sell(s, qty, price, noConsume)
    local ok, res = origSell(s, qty, price, noConsume)
    local db = ns.db
    if ok and db.lotAge and not db.lots[s] then db.lotAge[s] = nil end
    return ok, res
end

local function InitAges()
    local db = ns.db
    db.lotAge = db.lotAge or {}
    db.staleSeen = db.staleSeen or {}
    local firstBuy = {}
    for _, e in ipairs(db.log) do
        if e.kind == "buy" and not firstBuy[e.s] then firstBuy[e.s] = e.t end
    end
    for s, lot in pairs(db.lots) do
        if lot.qty and lot.qty > 0 and not db.lotAge[s] then
            db.lotAge[s] = firstBuy[s] or time()
        end
    end
    for s in pairs(db.lotAge) do
        local lot = db.lots[s]
        if not (lot and lot.qty and lot.qty > 0) then db.lotAge[s] = nil end
    end
end

local function StaleList()
    local db = ns.db
    local out = {}
    local now = time()
    local limit = (db.staleDays or 5) * 86400
    local keep = 1 - ns.Cut() / 100
    for s, lot in pairs(db.lots) do
        local t = db.lotAge and db.lotAge[s]
        if lot.qty and lot.qty > 0 and lot.cost and t and now - t >= limit then
            local d = ns.cache[s]
            local avg = lot.cost / lot.qty
            local exitP = d and d.minbuy and math.max(1, d.minbuy - (db.undercut or 1)) or nil
            out[#out + 1] = {
                s = s, days = (now - t) / 86400, qty = lot.qty, avg = avg,
                be = math.ceil(avg / keep), exit = exitP,
                pct = exitP and ((exitP * keep / avg - 1) * 100) or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.days > b.days end)
    return out
end

local function StaleText(x)
    local t = string.format("lezy %.0f dni: %dx %s, koszt sr. %s, break-even %s", x.days, x.qty,
        ns.ItemLink(x.s), ns.MoneyPlain(x.avg), ns.MoneyPlain(x.be))
    if x.exit then
        t = t .. string.format(" -> wyjscie %s (%+.0f%% vs koszt)", ns.MoneyPlain(x.exit), x.pct)
    end
    return t
end

local function CheckStale()
    local db = ns.db
    if not (db and db.staleOn) then return end
    db.staleSeen = db.staleSeen or {}
    local now = time()
    for _, x in ipairs(StaleList()) do
        if now - (db.staleSeen[x.s] or 0) >= 86400 then
            db.staleSeen[x.s] = now
            ns.Print("Wyjscie czasowe: " .. StaleText(x))
            if UIErrorsFrame and UIErrorsFrame.AddMessage then
                pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "TSMA: towar lezy " .. string.format("%.0f", x.days) .. " dni", 1, 0.8, 0.2)
            end
        end
    end
end

hooksecurefunc(ns, "RefreshAll", function() ns.Safe("stale", CheckStale) end)

------------------------------------------------------------------
-- Komenda /tsma exp
------------------------------------------------------------------
local function ExpCommand()
    local db = ns.db
    local capital = db.capital or 0
    if capital <= 0 then
        ns.Print("Kapital = 0, limit kategorii nieaktywny (ustaw: /tsma set capital 500g).")
    else
        local cap = capital * (db.catExposurePct or 15) / 100
        local rows = {}
        for c, v in pairs(Held()) do rows[#rows + 1] = { c = c, v = v } end
        table.sort(rows, function(a, b) return a.v > b.v end)
        ns.Print(string.format("Ekspozycja na kategorie (limit %s%% kapitalu = %s, %s):", tostring(db.catExposurePct),
            ns.MoneyPlain(cap), db.catExpOn and "ON" or "OFF"))
        if #rows == 0 then ns.Print("  brak zapasu.") end
        for _, r in ipairs(rows) do
            ns.Print(string.format("  %s: %s  (%.0f%% limitu)%s", r.c, ns.MoneyPlain(r.v), r.v / cap * 100,
                r.v > cap and "  |cffff4040PRZEKROCZONY|r" or ""))
        end
    end
    local st = StaleList()
    ns.Print(string.format("Towar lezacy >= %d dni: %d", db.staleDays or 5, #st))
    for i, x in ipairs(st) do
        if i > 10 then break end
        ns.Print("  " .. StaleText(x))
    end
    ns.Print("  /tsma set catExposurePct 15 | staleDays 5   (przelaczniki w Hub > Ustawienia)")
end

------------------------------------------------------------------
-- Ustawienia, komenda, start
------------------------------------------------------------------
table.insert(ns.FIELDS, { key = "catExposurePct", label = "Max % kapitalu na kategorie", kind = "num", min = 0, max = 100 })
table.insert(ns.FIELDS, { key = "staleDays", label = "Wyjscie czasowe: towar lezy (dni)", kind = "num", min = 1, max = 60, int = true })
table.insert(ns.TOGGLES, { key = "catExpOn", label = "Limit ekspozycji na kategorie" })
table.insert(ns.TOGGLES, { key = "staleOn", label = "Alert: towar lezy za dlugo (wyjscie czasowe)" })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if cmd == "exp" and ns.db then
        ExpCommand()
    elseif origSlash then
        origSlash(msg)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    for k, v in pairs(DEFAULTS) do
        if ns.db[k] == nil then ns.db[k] = v end
    end
    ns.Safe("exposure", InitAges)
end)
