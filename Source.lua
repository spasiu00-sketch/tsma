local ADDON, ns = ...

------------------------------------------------------------------
-- ZRODLO WYKRESOW: TSMA (TSM + archiwum) albo Blizzard (AuctionEngine -> BlizzData.lua + BlizzHist.lua)
-- Zrodla sa rozdzielone: w trybie Blizzard wykres (HUD, duzy wykres, Hub) rysuje WYLACZNIE punkty z Blizzarda
-- i nie dopina historii TSM ani archiwum.
-- BlizzData.lua to tylko aktualna migawka (jeden punkt na eksport). Pelna historia punktow (czas, min, mediana, ilosc)
-- jest w BlizzHist.lua, ktory AuctionEngine zapisuje przy kazdym eksporcie z wlasnej bazy. Addon scala go z db.blizzHist
-- (duplikaty po czasie pomijane), wiec po dowolnej liczbie eksportow miedzy /reload wykres Blizzarda jest ciagly.
-- Dodatkowo addon sam dopisuje punkt z migawki, gdy BlizzHist.lua nie ma danego przedmiotu.
-- Scalanie dotyczy przedmiotow sledzonych (lista, zapas, otwarte aukcje, wybrany) oraz kazdego nowo wybranego.
-- Przelaczanie: przycisk "Zrodlo" w Hubie i na duzym wykresie, Ustawienia, albo /tsma source tsma|blizz
-- Nie zmienia ani nie czyta niczego poza _G.TsmAnalizeBlizz i _G.TsmAnalizeBlizzHist (aplikacja zewnetrzna bez zmian).
------------------------------------------------------------------

local MAX_ITEMS, MAX_PTS, KEEP = 300, 600, 60 * 86400

local function Snapshot()
    local d = _G.TsmAnalizeBlizz
    if type(d) == "table" and type(d.items) == "table" and (d.generated or 0) > 0 then return d end
    return nil
end

-- plik historii z silnika: items["i:123"] = "t,min,mediana,ilosc;t,min,mediana,ilosc;..."
local function HistFile()
    local f = _G.TsmAnalizeBlizzHist
    if type(f) == "table" and type(f.items) == "table" and (f.generated or 0) > 0 then return f end
    return nil
end

-- scala punkty z BlizzHist.lua do serii h przedmiotu s (raz na wygenerowanie pliku); zwraca liczbe dodanych punktow
local function MergeFile(s, h)
    local f = HistFile()
    local str = f and f.items[s]
    if type(str) ~= "string" then return 0 end
    local db = ns.db
    db.blizzStamp = db.blizzStamp or {}
    if db.blizzStamp[s] == f.generated then return 0 end

    local have = {}
    for _, p in ipairs(h) do have[p[1]] = true end
    local cutoff = time() - KEEP
    local added = 0
    for t, m, d, q in str:gmatch("(%d+),(%d+),(%d+),(%d+)") do
        t, m, d, q = tonumber(t), tonumber(m), tonumber(d), tonumber(q)
        if t >= cutoff and not have[t] then
            h[#h + 1] = { t, m, d, q }
            have[t] = true
            added = added + 1
        end
    end
    if added > 0 then
        table.sort(h, function(a, b) return a[1] < b[1] end)
        while h[1] and (h[1][1] < cutoff or #h > MAX_PTS) do table.remove(h, 1) end
    end
    db.blizzStamp[s] = f.generated
    return added
end

-- zapis serii Blizzarda dla jednego przedmiotu: historia z pliku + aktualna migawka (raz na eksport)
function ns.BlizzRecord(s)
    local db = ns.db
    if not (db and s) then return end
    local d = Snapshot()
    local e = d and d.items[s]
    local hf = HistFile()
    local inFile = hf and type(hf.items[s]) == "string"
    local inSnap = (e and e.m) and true or false
    if not (inSnap or inFile) then return end

    db.blizzHist = db.blizzHist or {}
    db.blizzStamp = db.blizzStamp or {}
    local h = db.blizzHist[s]
    if not h then
        h = {}
        db.blizzHist[s] = h
        db.blizzStamp[s] = nil
        local n, oid, ot = 0, nil, nil
        for k, v in pairs(db.blizzHist) do
            n = n + 1
            if k ~= s then
                local last = v[#v]
                local t = last and last[1] or 0
                if not ot or t < ot then oid, ot = k, t end
            end
        end
        if n > MAX_ITEMS and oid then
            db.blizzHist[oid] = nil
            db.blizzStamp[oid] = nil
        end
    end

    MergeFile(s, h)

    if not inSnap then return end
    local last = h[#h]
    if last and last[1] >= d.generated then return end
    h[#h + 1] = { d.generated, e.m, e.d, e.q }
    local cutoff = time() - KEEP
    while h[1] and (h[1][1] < cutoff or #h > MAX_PTS) do table.remove(h, 1) end
end

local function RecordTracked()
    local db = ns.db
    if not (db and (Snapshot() or HistFile())) then return end
    local seen = {}
    local function rec(s)
        if s and not seen[s] then seen[s] = true; ns.BlizzRecord(s) end
    end
    for _, s in ipairs(db.watch or {}) do rec(s) end
    for s, lot in pairs(db.lots or {}) do
        if lot.qty and lot.qty > 0 then rec(s) end
    end
    for s in pairs(db.openPosts or {}) do rec(s) end
    rec(db.selected)
    for s in pairs(db.blizzHist or {}) do rec(s) end
end

-- seria w formacie historii TSMA ({t, min, mediana}) - dla funkcji, ktore czytaja rec.hist
function ns.ChartRec(s)
    local db = ns.db
    if db.chartBlizz then
        local h = db.blizzHist and db.blizzHist[s]
        if not h then return nil end
        local out = {}
        for _, p in ipairs(h) do out[#out + 1] = { p[1], p[2], p[3] or 0 } end
        return { hist = out }
    end
    return db.items[s]
end

function ns.SetChartSource(blizz)
    ns.db.chartBlizz = blizz and true or false
    ns.Print("Zrodlo wykresow: " .. (ns.db.chartBlizz and "Blizzard (AuctionEngine)" or "TSMA (TSM + archiwum)"))
    if ns.UpdateUI then ns.UpdateUI() end
end

function ns.ChartSourceText()
    return (ns.db and ns.db.chartBlizz) and "Zrodlo: Blizzard" or "Zrodlo: TSMA"
end

------------------------------------------------------------------
-- Rysowanie: w trybie Blizzard podmieniamy serie na czas rysowania i wylaczamy dopinanie archiwum
------------------------------------------------------------------
local prevDraw = ns.DrawChart
function ns.DrawChart(chart, itemString, breakEven, alertPrice)
    local db = ns.db
    if chart and chart.empty and not chart.emptyOrig then chart.emptyOrig = chart.empty:GetText() end

    if not (db and db.chartBlizz and itemString) then
        if chart and chart.empty and chart.emptyOrig and chart.empty.SetText then chart.empty:SetText(chart.emptyOrig) end
        return prevDraw(chart, itemString, breakEven, alertPrice)
    end

    local rec = db.items[itemString]
    local created = false
    if not rec then
        rec = { hist = {} }
        db.items[itemString] = rec
        created = true
    end
    local saved = rec.hist
    local pts = {}
    local series = db.blizzHist and db.blizzHist[itemString]
    for _, p in ipairs(series or {}) do pts[#pts + 1] = { p[1], p[2], p[3] or 0 } end
    rec.hist = pts

    local savedArc = db.arc
    db.arc = nil   -- Archive.lua nie dopina wtedy starszych dni z TSM
    local ok, err = pcall(prevDraw, chart, itemString, breakEven, alertPrice)
    db.arc = savedArc
    rec.hist = saved
    if created then db.items[itemString] = nil end
    if not ok then error(err, 0) end

    if chart.empty and chart.empty:IsShown() then
        chart.empty:SetText((Snapshot() or HistFile())
            and "|cff888888Blizzard: za malo punktow (potrzeba 2+ eksportow AuctionEngine)|r"
            or "|cff888888Brak danych Blizzarda (BlizzData.lua)|r")
    elseif not chart.big and chart.xl then
        local tx = chart.xl:GetText()
        if tx and tx ~= "" then chart.xl:SetText(tx .. " |cff33aaffBlizz|r") end
    end
end

------------------------------------------------------------------
-- Statystyki z Blizzarda (do duzego wykresu)
------------------------------------------------------------------
local function BlizzStats(s, range)
    if not (Snapshot() or HistFile()) then return "|cffff4040Brak danych Blizzarda (BlizzData.lua).|r" end
    local h = ns.db.blizzHist and ns.db.blizzHist[s]
    local cutoff = range and (time() - range) or 0
    local pts = {}
    for _, p in ipairs(h or {}) do
        if p[1] >= cutoff then pts[#pts + 1] = p end
    end
    if #pts == 0 then
        return "|cff888888Blizzard: brak punktow w tym zakresie (zapis przy kazdym eksporcie AuctionEngine).|r"
    end
    local lo, hi, sum = pts[1][2], pts[1][2], 0
    for _, p in ipairs(pts) do
        lo, hi, sum = math.min(lo, p[2]), math.max(hi, p[2]), sum + p[2]
    end
    local first, last = pts[1], pts[#pts]
    local snap = Snapshot()
    local e = snap and snap.items[s]
    local txt = string.format("Blizzard (%d pkt): %s / %s / %s", #pts, ns.Money(lo), ns.Money(sum / #pts), ns.Money(hi))
    if e then
        txt = txt .. "   mediana teraz " .. ns.Money(e.d) .. "   ilosc " .. tostring(e.q or "?")
    end
    if #pts >= 2 and first[2] > 0 then
        local ch = (last[2] / first[2] - 1) * 100
        txt = txt .. string.format("   zmiana w zakresie %s%+.1f%%|r", ch >= 0 and "|cff33dd66" or "|cffff4040", ch)
    end
    return txt
end

ns.BlizzStats = BlizzStats   -- uzywane przez duzy wykres (Chart.lua)

------------------------------------------------------------------
-- Ustawienia, komenda, start
------------------------------------------------------------------
table.insert(ns.TOGGLES, { key = "chartBlizz", label = "Wykresy: zrodlo Blizzard (AuctionEngine) zamiast TSMA",
    set = function(v)
        ns.db.chartBlizz = v and true or false
        if ns.UpdateUI then ns.UpdateUI() end
    end })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    if (cmd or ""):lower() == "source" and ns.db then
        local v = (rest or ""):lower()
        if v == "blizz" or v == "blizzard" then
            ns.SetChartSource(true)
        elseif v == "tsma" or v == "tsm" then
            ns.SetChartSource(false)
        else
            local n, pts = 0, 0
            for _, h in pairs(ns.db.blizzHist or {}) do n = n + 1; pts = pts + #h end
            ns.Print(string.format("Zrodlo wykresow: %s; dane Blizzarda: %s; sledzonych przedmiotow z historia Blizzarda: %d (punktow lacznie: %d)",
                ns.db.chartBlizz and "Blizzard" or "TSMA", Snapshot() and "sa" or "brak", n, pts))
            local hf = HistFile()
            if hf then
                local nf = 0
                for _ in pairs(hf.items) do nf = nf + 1 end
                ns.Print(string.format("  BlizzHist.lua: %d przedmiotow, wygenerowany %s", nf, date("%d.%m %H:%M", hf.generated)))
            else
                ns.Print("  BlizzHist.lua: brak (nie wczytany albo AuctionEngine 2.3 jeszcze go nie zapisal; nowy plik w .toc wymaga pelnego restartu gry)")
            end
            ns.Print("  /tsma source tsma | blizz")
        end
    elseif origSlash then
        origSlash(msg)
    end
end

-- punkt po kazdej zmianie wyboru (wybrany przedmiot trafia do sledzonych)
hooksecurefunc(ns, "UpdateUI", function()
    ns.Safe("source", function()
        if ns.db then ns.BlizzRecord(ns.db.selected) end
    end)
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.Safe("source", RecordTracked)
end)