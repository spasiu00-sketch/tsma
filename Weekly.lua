local ADDON, ns = ...

------------------------------------------------------------------
-- PETLA ZWROTNA: czy prognozy i sygnaly faktycznie zarabiaja?
--  * kazda prognoza +24h dla sledzonych przedmiotow jest zapisywana (db.fcLog) i po 24 h porownana z realna cena min
--  * agregat db.fcAgg: trafnosc kierunku, blad mediany vs "bez zmian", pokrycie p10 / p90
--  * straznik: gdy po >= 40 ocenach prognoza mediany jest GORSZA niz "bez zmian", ns.FcFor zwraca nil (prognozy sie wylaczaja)
--  * /tsma weekly: raport 7 dni (zysk z dziennika, najlepsze / najgorsze przedmioty, trafnosc KUP, trafnosc prognoz)
-- Wczytaj PO Forecast.lua (opakowuje ns.FcFor).
------------------------------------------------------------------

local HORIZON = 24 * 3600
local MIN_EVAL = 40

local function Agg()
    local db = ns.db
    db.fcLog = db.fcLog or {}
    db.fcAgg = db.fcAgg or { n = 0, dir = 0, dirN = 0, errM = 0, errZ = 0, lo = 0, hi = 0 }
    return db.fcAgg
end

local function Record(list)
    local db = ns.db
    if not (db and db.fcOn) then return end
    Agg()
    local now = time()
    local last = db.fcLogLast or {}
    db.fcLogLast = last
    for _, s in ipairs(list) do
        local d = ns.cache[s]
        local f = ns.FcForRaw and ns.FcForRaw(s)
        if d and d.minbuy and f and f.f24 and now - (last[s] or 0) >= 6 * 3600 then
            last[s] = now
            db.fcLog[#db.fcLog + 1] = { t = now, s = s, base = d.minbuy, p = { f.f24[1], f.f24[2], f.f24[3] } }
        end
    end
    while #db.fcLog > 2000 do table.remove(db.fcLog, 1) end
end

local function Evaluate()
    local db = ns.db
    if not (db and db.fcLog) then return end
    local a = Agg()
    local now, keep = time(), {}
    for _, e in ipairs(db.fcLog) do
        local d = ns.cache[e.s]
        if now - e.t >= HORIZON and d and d.minbuy and e.base > 0 then
            local act = (d.minbuy / e.base - 1) * 100
            a.n = a.n + 1
            a.errM = a.errM + math.abs(act - e.p[2])
            a.errZ = a.errZ + math.abs(act)
            if math.abs(e.p[2]) >= 1 then
                a.dirN = a.dirN + 1
                if (act > 0) == (e.p[2] > 0) then a.dir = a.dir + 1 end
            end
            if act < e.p[1] then a.lo = a.lo + 1 end
            if act > e.p[3] then a.hi = a.hi + 1 end
        elseif now - e.t < HORIZON * 7 then
            keep[#keep + 1] = e
        end
    end
    db.fcLog = keep
    if a.n > 600 then for k, v in pairs(a) do a[k] = v / 2 end end   -- starsze oceny stopniowo wygasaja
end

-- straznik: surowy odczyt zostaje dostepny, a ns.FcFor (uzywane przez Analyze) milknie przy slabej skutecznosci
local rawFcFor = ns.FcFor
ns.FcForRaw = rawFcFor
function ns.FcTrusted()
    local a = ns.db and ns.db.fcAgg
    if not a or a.n < MIN_EVAL then return true end
    return a.errM < a.errZ
end
function ns.FcFor(s)
    if not ns.FcTrusted() then return nil end
    return rawFcFor(s)
end

local function Weekly()
    local db = ns.db
    local now = time()
    local cut = now - 7 * 86400
    local by, total, sells, lost = {}, 0, 0, 0
    for _, e in ipairs(db.log) do
        if e.t >= cut and (e.kind == "sell" or e.kind == "expired") then
            local p = e.profit or 0
            total = total + p
            if e.kind == "sell" then sells = sells + (e.qty or 0) else lost = lost - p end
            by[e.s] = (by[e.s] or 0) + p
        end
    end
    ns.Print("=== Raport 7 dni ===")
    ns.Print(string.format("Zysk netto z dziennika: %s  (sprzedanych szt.: %d, utracone depozyty: %s)", ns.MoneyPlain(total), sells, ns.MoneyPlain(lost)))
    local rows = {}
    for s, p in pairs(by) do rows[#rows + 1] = { s = s, p = p } end
    table.sort(rows, function(x, y) return x.p > y.p end)
    for i = 1, math.min(3, #rows) do ns.Print("  + " .. ns.ItemName(rows[i].s) .. ": " .. ns.MoneyPlain(rows[i].p)) end
    for i = #rows, math.max(#rows - 2, 4), -1 do
        if rows[i].p < 0 then ns.Print("  - " .. ns.ItemName(rows[i].s) .. ": -" .. ns.MoneyPlain(rows[i].p)) end
    end
    ns.Print(ns.AccuracyLine())
    local a = Agg()
    if a.n == 0 then
        ns.Print("Prognozy: brak ocenionych (potrzeba BlizzForecast.lua i 24 h).")
    else
        ns.Print(string.format("Prognozy +24h (n=%d): blad mediany %.1f pp vs %.1f pp dla \"bez zmian\"; kierunek trafny %s; poza p10 %.0f%%, powyzej p90 %.0f%% (cel 10%%/10%%)",
            a.n, a.errM / a.n, a.errZ / a.n, a.dirN > 0 and string.format("%.0f%%", a.dir / a.dirN * 100) or "n/d", a.lo / a.n * 100, a.hi / a.n * 100))
        if a.n >= MIN_EVAL then
            ns.Print(ns.FcTrusted() and "  Werdykt: prognozy bija \"bez zmian\" - zostaja wlaczone."
                or "  |cffff4040Werdykt: prognozy sa gorsze niz \"bez zmian\" - wylaczone automatycznie (ns.FcFor), sprawdz silnik / dane.|r")
        else
            ns.Print(string.format("  Za malo ocen do werdyktu (%d/%d).", a.n, MIN_EVAL))
        end
    end
    local sn = _G.TsmAnalizeSnipe
    ns.Print(string.format("Ostatni eksport: snajpow %d, arbitrazu %d.", sn and sn.rows and #sn.rows or 0,
        _G.TsmAnalizeArb and _G.TsmAnalizeArb.rows and #_G.TsmAnalizeArb.rows or 0))
end

hooksecurefunc(ns, "RefreshAll", function()
    ns.Safe("weekly", function()
        Evaluate()
        Record(ns.RefreshList())
    end)
end)

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if (cmd == "weekly" or cmd == "tydzien") and ns.db then
        Weekly()
    elseif origSlash then
        origSlash(msg)
    end
end
