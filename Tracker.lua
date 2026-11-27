local ADDON, ns = ...

------------------------------------------------------------------
-- TRACKER RYNKU W ADDONIE (niezalezny od TSM i od aplikacji)
--  * kazde wyszukiwanie w AH (zdarzenia COMMODITY/ITEM_SEARCH_RESULTS_UPDATED) zapisuje skrot drabiny:
--    min, druga cena, ilosc na minimum, glebokosc +5% / +10%, podaz (db.mt[id].h, ring 48 probek)
--  * WLASNY PRZEPLYW: porownanie dwoch skanow tego samego przedmiotu po ID aukcji (jak flow.py): zejscia przy minimum
--    (cena <= 1.25 x min poprzedniego skanu, bez Twoich aukcji, bez tych z krotkim czasem do konca) / czas pokrycia.
--    To estymata sprzedazy (anulowanie przy minimum jest nieodroznialne). ns.OwnFlow(s) -> szt./dobe, godziny pokrycia.
--    Gdy TSM nie ma DBRegionSoldPerDay (albo flowPrefer = ON), FetchTSM wstawia wlasny przeplyw do d.perDay (Risk.lua go uzywa).
--  * FLIPY Z LUKI: gdy kilka najtanszych ofert stoi wyraznie ponizej "sciany" nastepnego poziomu, liczy zysk z wykupienia ich
--    i wystawienia tuz pod sciana (prowizja, depozyt, undercut). ns.Flips(); alert na czacie; /tsma flip
--  * DIAGNOSTYKA: /tsma data (pokrycie danych TSM, ktore decyduje o jakosci modelu ryzyka), /tsma flow, /tsma size
--  * ROZMIAR SavedVariables: /tsma size [trim]; przy wylogowaniu przycina tracker / dziennik prognoz, gdy db > maxSV
-- Wczytaj po Core.lua; do danych ofert nie potrzebuje Huba.
------------------------------------------------------------------

local DEFAULTS = { mtOn = true, flowPrefer = false, flipOn = true, flipAlert = true, flipMinProfit = 50000,
    flipMaxUnits = 200, mtMaxItems = 250, maxSV = 12 * 1024 * 1024 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local RING, FLOW_WIN, FLOW_MIN_GAP, FLOW_MAX_GAP = 48, 72 * 3600, 300, 3 * 3600
local mem, flips, alerted = {}, {}, {}
ns.mem, ns.flips = mem, flips

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

local function MT(id)
    local db = ns.db
    db.mt = db.mt or {}
    local e = db.mt[id]
    if not e then
        e = { h = {}, fl = {}, u = 0 }
        db.mt[id] = e
        local n, oid, ot = 0, nil, nil
        for k, v in pairs(db.mt) do
            n = n + 1
            if k ~= id and (not ot or (v.u or 0) < ot) then oid, ot = k, v.u or 0 end
        end
        if n > (db.mtMaxItems or 250) and oid then db.mt[oid] = nil end
    end
    return e
end

------------------------------------------------------------------
-- Przeplyw
------------------------------------------------------------------
local function AddFlow(id, dt, lost)
    local e = MT(id)
    local now = time()
    e.fl[#e.fl + 1] = { now, dt, lost }
    while e.fl[1] and now - e.fl[1][1] > FLOW_WIN do table.remove(e.fl, 1) end
end

-- szt./dobe oraz godziny pokrycia w oknie 72 h (nil gdy < 2 h pokrycia)
function ns.OwnFlow(s)
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local e = id and ns.db and ns.db.mt and ns.db.mt[id]
    if not (e and e.fl) then return nil end
    local now, sdt, sl = time(), 0, 0
    for _, f in ipairs(e.fl) do
        if now - f[1] <= FLOW_WIN then sdt, sl = sdt + f[2], sl + f[3] end
    end
    if sdt < 2 * 3600 then return nil end
    return sl / sdt * 86400, sdt / 3600
end

------------------------------------------------------------------
-- Flipy z luki w drabinie
------------------------------------------------------------------
local function Flip(id, lv)
    local db = ns.db
    local s = "i:" .. id
    flips[s] = nil
    if #lv < 2 then return end
    local d = ns.cache[s] or ns.FetchTSM(s)
    local keep = 1 - ns.Cut() / 100
    local under = math.max(1, db.undercut or 1)
    local dep = ns.DepositPerUnit(d, s) or 0
    local p = 0.8
    if ns.OwnSellProb then
        local po, n = ns.OwnSellProb(s)
        if po and n >= 10 then p = clamp(po, 0.1, 0.95) end
    end
    local failCost = dep * (1 - p) / p
    local maxU = db.flipMaxUnits or 200
    local cost, got, best = 0, 0, nil
    for j = 1, #lv - 1 do
        local take = math.min(lv[j].q, maxU - got)
        if take <= 0 then break end
        cost, got = cost + take * lv[j].p, got + take
        local sell = lv[j + 1].p - under
        if sell > lv[j].p then
            local profit = got * sell * keep - cost - got * failCost
            local gain = profit / cost * 100
            if profit > 0 and gain >= (db.margin or 0) and (not best or profit > best.profit) then
                best = { s = s, id = id, units = got, cost = cost, avg = cost / got, sell = sell, wall = lv[j + 1].p,
                    profit = profit, gain = gain, levels = j }
            end
        end
    end
    if not best then return end
    local fl = ns.OwnFlow(s)
    if not fl and d and d.perDay then fl = d.perDay / (db.perDayDiv or 1) end
    best.days = fl and fl > 0 and (best.units / (fl * 0.5)) or nil
    best.t = time()
    flips[s] = best
    if db.flipAlert and best.profit >= (db.flipMinProfit or 50000) and time() - (alerted[s] or 0) > 600 then
        alerted[s] = time()
        ns.Print(string.format("FLIP: %s - kup %dx (sr. %s), wystaw za %s pod sciana %s; zysk ~%s (%+.0f%%)", ns.ItemLink(s), best.units,
            ns.MoneyPlain(best.avg), ns.MoneyPlain(best.sell), ns.MoneyPlain(best.wall), ns.MoneyPlain(best.profit), best.gain))
        if db.alertSound ~= false then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
    end
end

function ns.Flips()
    local out, now = {}, time()
    for _, f in pairs(flips) do
        if now - f.t < 900 then out[#out + 1] = f end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    return out
end

-- podpowiedz sprzedazy: pojedyncza oferta tuz pod Toba przed "sciana"
function ns.SellHint(s)
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local m = id and mem[id]
    if not (m and m.lv and #m.lv >= 2 and time() - m.t < 900) then return nil end
    local l1, l2 = m.lv[1], m.lv[2]
    if l1.q <= math.max(2, m.total * 0.03) and l2.p >= l1.p * 1.08 then
        return string.format("Najtansza oferta to tylko %d szt. po %s, nastepna dopiero %s: wystaw tuz pod %s zamiast pod pierwsza.",
            l1.q, ns.MoneyPlain(l1.p), ns.MoneyPlain(l2.p), ns.MoneyPlain(l2.p))
    end
    return nil
end

------------------------------------------------------------------
-- Przetwarzanie wyniku wyszukiwania
------------------------------------------------------------------
local function Process(id, rows, commodity)
    local db = ns.db
    if not (db and db.mtOn and id and #rows > 0) then return end
    local now = time()
    table.sort(rows, function(a, b) return a.u < b.u end)
    local lv, last, total = {}, nil, 0
    for _, r in ipairs(rows) do
        if not r.own then
            total = total + r.q
            if last and last.p == r.u then last.q = last.q + r.q else last = { p = r.u, q = r.q }; lv[#lv + 1] = last end
        end
    end
    if #lv == 0 then return end
    local p1 = lv[1].p
    local d5, d10 = 0, 0
    for _, l in ipairs(lv) do
        if l.p <= p1 * 1.05 then d5 = d5 + l.q end
        if l.p <= p1 * 1.10 then d10 = d10 + l.q end
    end
    local full = #rows < 400
    local m = mem[id]
    if m and m.full and full and m.ids and now - m.t >= FLOW_MIN_GAP and now - m.t <= FLOW_MAX_GAP then
        local cur = {}
        for _, r in ipairs(rows) do if r.id then cur[r.id] = r end end
        local lost = 0
        for aid, o in pairs(m.ids) do
            local c = cur[aid]
            local gone = o.q - (c and c.q or 0)
            if gone > 0 and o.u <= m.min * 1.25 and not (not c and o.left and o.left > 0 and o.left < 1800) then
                lost = lost + gone
            end
        end
        AddFlow(id, now - m.t, lost)
    end
    local ids = {}
    if full then
        for _, r in ipairs(rows) do
            if r.id and not r.own then ids[r.id] = { q = r.q, u = r.u, left = r.left } end
        end
    end
    mem[id] = { t = now, min = p1, lv = lv, ids = ids, total = total, full = full, commodity = commodity }

    local e = MT(id)
    local lh = e.h[#e.h]
    if not lh or now - lh[1] >= 600 or math.abs(p1 / lh[2] - 1) > 0.01 then
        e.h[#e.h + 1] = { now, p1, lv[2] and lv[2].p or 0, lv[1].q, d5, d10, total }
        while #e.h > RING do table.remove(e.h, 1) end
    end
    e.u = now
    if db.flipOn then ns.Safe("flip", Flip, id, lv) end
end

local function OnCommodity(id)
    local AH = _G.C_AuctionHouse
    if not (AH and AH.GetNumCommoditySearchResults and id) then return end
    local n = AH.GetNumCommoditySearchResults(id) or 0
    local rows = {}
    for i = 1, math.min(n, 400) do
        local r = AH.GetCommoditySearchResultInfo(id, i)
        if r and r.unitPrice then
            rows[#rows + 1] = { id = r.auctionID, u = r.unitPrice, q = r.quantity or 1, left = r.timeLeftSeconds,
                own = (r.containsOwnerItem or (r.numOwnerItems or 0) > 0) and true or false }
        end
    end
    Process(id, rows, true)
end

local function OnItem(key)
    local AH = _G.C_AuctionHouse
    local id = key and key.itemID
    if not (AH and AH.GetNumItemSearchResults and id) then return end
    local n = AH.GetNumItemSearchResults(key) or 0
    local rows = {}
    for i = 1, math.min(n, 400) do
        local r = AH.GetItemSearchResultInfo(key, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 then
            local q = r.quantity or 1
            rows[#rows + 1] = { id = r.auctionID, u = math.floor(r.buyoutAmount / q), q = q, left = r.timeLeftSeconds,
                own = r.containsOwnerItem and true or false }
        end
    end
    Process(id, rows, false)
end

-- wlasny przeplyw zasila d.perDay (Risk.lua dzieli przez perDayDiv, wiec mnozymy)
local origFetch = ns.FetchTSM
function ns.FetchTSM(s)
    local d = origFetch(s)
    local db = ns.db
    if db and db.mtOn and d then
        local fl, cov = ns.OwnFlow(s)
        if fl and cov >= 2 and (db.flowPrefer or not d.perDay) then
            d.perDay = fl * (db.perDayDiv or 1)
            d.perDaySrc = "addon"
        end
    end
    return d
end

------------------------------------------------------------------
-- Rozmiar SavedVariables
------------------------------------------------------------------
local function Est(v, depth)
    local t = type(v)
    if t == "number" then return 9
    elseif t == "string" then return #v + 3
    elseif t == "boolean" then return 5
    elseif t == "table" then
        local s = 16
        if depth > 8 then return s end
        for k, x in pairs(v) do s = s + Est(k, depth + 1) + Est(x, depth + 1) + 2 end
        return s
    end
    return 0
end

function ns.DBSize()
    local out, total = {}, 0
    for k, v in pairs(ns.db) do
        local b = Est(v, 0)
        out[#out + 1] = { k = k, b = b }
        total = total + b
    end
    table.sort(out, function(a, b) return a.b > b.b end)
    return out, total
end

local function HalfOldest(tbl, stamp)
    local arr = {}
    for k, v in pairs(tbl) do arr[#arr + 1] = { k = k, t = stamp(v) or 0 } end
    table.sort(arr, function(a, b) return a.t < b.t end)
    for i = 1, math.floor(#arr / 2) do tbl[arr[i].k] = nil end
end

function ns.TrimDB()
    local db = ns.db
    local _, total = ns.DBSize()
    local limit = db.maxSV or DEFAULTS.maxSV
    local steps = {}
    if total > limit and db.mt then HalfOldest(db.mt, function(v) return v.u end); steps[#steps + 1] = "tracker" end
    _, total = ns.DBSize()
    if total > limit and db.fcLog then db.fcLog = {}; steps[#steps + 1] = "dziennik prognoz" end
    _, total = ns.DBSize()
    if total > limit and db.blizzHist then HalfOldest(db.blizzHist, function(v) local l = v[#v]; return l and l[1] end); steps[#steps + 1] = "historia Blizzarda" end
    _, total = ns.DBSize()
    return steps, total
end

------------------------------------------------------------------
-- Komendy
------------------------------------------------------------------
local function pct(n, d) return d > 0 and string.format("%.0f%%", n / d * 100) or "n/d" end

local function DataCommand()
    local db = ns.db
    if not ns.HasTSM() then ns.Print("TSM nie wykryte - brak danych do diagnozy."); return end
    local ids, seen = {}, {}
    local function add(s) if s and not seen[s] then seen[s] = true; ids[#ids + 1] = s end end
    for _, s in ipairs(db.watch) do add(s) end
    add(db.selected)
    local n = 0
    for id in pairs(ns.arcNow or {}) do
        if n >= 200 then break end
        add("i:" .. id); n = n + 1
    end
    local cnt = { DBMinBuyout = 0, DBMarket = 0, DBRegionSaleRate = 0, DBRegionSoldPerDay = 0 }
    local perDays = {}
    for _, s in ipairs(ids) do
        for src in pairs(cnt) do
            local ok, v = ns.RawTSM(src, s)
            if ok and type(v) == "number" and v > 0 then
                cnt[src] = cnt[src] + 1
                if src == "DBRegionSoldPerDay" then perDays[#perDays + 1] = v end
            end
        end
    end
    table.sort(perDays)
    local N = #ids
    ns.Print(string.format("Diagnoza danych TSM (%d przedmiotow z listy / archiwum):", N))
    ns.Print(string.format("  DBMinBuyout %s, DBMarket %s, DBRegionSaleRate %s, DBRegionSoldPerDay %s",
        pct(cnt.DBMinBuyout, N), pct(cnt.DBMarket, N), pct(cnt.DBRegionSaleRate, N), pct(cnt.DBRegionSoldPerDay, N)))
    if #perDays > 0 then
        ns.Print(string.format("  SoldPerDay: mediana %.2f, max %.1f (dzielnik perDayDiv = %s)", perDays[math.ceil(#perDays / 2)],
            perDays[#perDays], tostring(db.perDayDiv)))
    end
    local nm, nf = 0, 0
    for id in pairs(db.mt or {}) do
        nm = nm + 1
        if ns.OwnFlow("i:" .. id) then nf = nf + 1 end
    end
    ns.Print(string.format("  Tracker: %d przedmiotow w db.mt, wlasny przeplyw policzony dla %d (potrzeba 2 skanow tego samego przedmiotu w odstepie 5 min - 3 h)", nm, nf))
    local missing = N - cnt.DBRegionSoldPerDay
    if N > 0 and cnt.DBRegionSoldPerDay / N < 0.5 then
        ns.Print("  |cffff4040TSM nie ma tempa sprzedazy dla wiekszosci przedmiotow|r - model ryzyka dziala na zgadywanych wartosciach. Skanuj AH (tracker liczy wlasny przeplyw) i wlacz /tsma flow prefer.")
    elseif missing > 0 then
        ns.Print(string.format("  Brak tempa sprzedazy dla %d przedmiotow - dla nich uzywany jest wlasny przeplyw, gdy jest.", missing))
    else
        ns.Print("  Dane TSM o sprzedazy sa kompletne.")
    end
    local s = db.selected
    if s then
        ns.Print("Wybrany " .. ns.ItemName(s) .. ":")
        for _, src in ipairs({ "DBRegionSaleRate", "DBRegionSoldPerDay" }) do
            local ok, v = ns.RawTSM(src, s)
            ns.Print(string.format("  %s = %s", src, ok and tostring(v) or "blad"))
        end
        local fl, cov = ns.OwnFlow(s)
        ns.Print("  Wlasny przeplyw: " .. (fl and string.format("%.1f szt./dobe (pokrycie %.1f h)", fl, cov) or "brak (zeskanuj ten przedmiot dwa razy)"))
    end
end

local function FlipCommand()
    local list = ns.Flips()
    if #list == 0 then ns.Print("Brak flipow z luki (potrzebne swieze wyszukiwania w AH; flip wymaga min. 2 poziomow cen).") end
    for i = 1, math.min(10, #list) do
        local f = list[i]
        ns.Print(string.format("  %s: kup %dx (sr. %s, %d poz.) -> wystaw za %s pod sciana %s; zysk ~%s (%+.0f%%)%s", ns.ItemName(f.s), f.units,
            ns.MoneyPlain(f.avg), f.levels, ns.MoneyPlain(f.sell), ns.MoneyPlain(f.wall), ns.MoneyPlain(f.profit), f.gain,
            f.days and string.format(", sprzedaz ~%.1f dnia", f.days) or ""))
    end
    local s = ns.db.selected
    local h = s and ns.SellHint(s)
    if h then ns.Print("Wybrany: " .. h) end
end

local function FlowCommand(rest)
    local db = ns.db
    local v = (rest or ""):lower()
    if v == "on" or v == "off" then db.mtOn = (v == "on")
    elseif v == "prefer" then db.flowPrefer = not db.flowPrefer end
    ns.Print(string.format("Tracker rynku: %s; wlasny przeplyw ma pierwszenstwo nad TSM: %s  (/tsma flow on|off|prefer)",
        db.mtOn and "ON" or "OFF", db.flowPrefer and "TAK" or "nie (tylko gdy TSM nie ma danych)"))
    local s = db.selected
    if s then
        local fl, cov = ns.OwnFlow(s)
        ns.Print("  " .. ns.ItemName(s) .. ": " .. (fl and string.format("%.1f szt./dobe, pokrycie %.1f h", fl, cov) or "brak wlasnego przeplywu"))
    end
end

local function SizeCommand(rest)
    local list, total = ns.DBSize()
    ns.Print(string.format("Rozmiar db (szacunek): %.1f MB, limit %.0f MB", total / 1048576, (ns.db.maxSV or DEFAULTS.maxSV) / 1048576))
    for i = 1, math.min(6, #list) do ns.Print(string.format("  %s: %.2f MB", list[i].k, list[i].b / 1048576)) end
    if (rest or ""):lower() == "trim" then
        local steps, t2 = ns.TrimDB()
        ns.Print(#steps > 0 and (string.format("Przycieto: %s -> %.1f MB", table.concat(steps, ", "), t2 / 1048576)) or "Nic do przyciecia (db pod limitem).")
    end
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not ns.db then if origSlash then origSlash(msg) end return end
    if cmd == "data" or cmd == "dane" then DataCommand()
    elseif cmd == "flip" then FlipCommand()
    elseif cmd == "flow" then FlowCommand(rest)
    elseif cmd == "size" then SizeCommand(rest)
    elseif origSlash then origSlash(msg) end
end

table.insert(ns.TOGGLES, { key = "mtOn", label = "Tracker rynku: skrot drabiny i wlasny przeplyw przy kazdym wyszukiwaniu AH" })
table.insert(ns.TOGGLES, { key = "flowPrefer", label = "Wlasny przeplyw ma pierwszenstwo nad danymi sprzedazy z TSM" })
table.insert(ns.TOGGLES, { key = "flipOn", label = "Flipy z luki w drabinie (liczenie przy kazdym wyszukiwaniu)" })
table.insert(ns.TOGGLES, { key = "flipAlert", label = "Alert na czacie o flipie z luki" })
table.insert(ns.FIELDS, { key = "flipMinProfit", label = "Flip: min. zysk dla alertu", kind = "money", min = 0, max = 1e10 })
table.insert(ns.FIELDS, { key = "flipMaxUnits", label = "Flip: max sztuk do wykupienia", kind = "num", min = 1, max = 2000, int = true })

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, a1)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON or not ns.db then return end
        self:UnregisterEvent("ADDON_LOADED")
        for k, v in pairs(DEFAULTS) do
            if ns.db[k] == nil then ns.db[k] = v end
        end
        ns.db.mt = ns.db.mt or {}
        for _, e in ipairs({ "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "PLAYER_LOGOUT" }) do
            pcall(self.RegisterEvent, self, e)
        end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        ns.Safe("tracker", OnCommodity, a1)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        ns.Safe("tracker", OnItem, a1)
    elseif event == "PLAYER_LOGOUT" then
        ns.Safe("tracker", ns.TrimDB)
    end
end)
