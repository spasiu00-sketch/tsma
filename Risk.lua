local ADDON, ns = ...

------------------------------------------------------------------
-- ROZSZERZONA OCENA RYZYKA
--  1) swiezosc danych: ile ROZNYCH wartosci jest w historii (plaski rynek albo nieswieze dane TSM)
--  2) kara za krotka historia (< 5 dni): stabilnosc z 24h to jeszcze nie stabilnosc
--  3) czas sprzedazy: ile dni zajmie sprzedaz Twojej ilosci przy tempie rynku i zakladanym udziale
--  4) bufor spadku: o ile % cena moze spasc, zanim wyjdziesz na minus (i ile to "zmiennosci")
--  5) przedzial niepewnosci p sprzedazy (Wilson 95%), wezszy gdy sa wlasne dane lub model ML
-- Punkty ryzyka z 1-4 dodaja sie do dotychczasowej oceny, wiec wplywaja na werdykt, skaner i alerty.
------------------------------------------------------------------

local DEFAULTS = { riskExt = true, riskShare = 0.5 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

-- przedzial Wilsona dla proporcji p przy efektywnej liczbie prob n
local function wilson(p, n)
    local z = 1.96
    local den = 1 + z * z / n
    local c = (p + z * z / (2 * n)) / den
    local h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return math.max(0, c - h), math.min(1, c + h)
end

local function Level(score)
    return (score < 25 and "LOW") or (score < 50 and "MED") or "HIGH"
end

-- zwraca: dodatkowe punkty, lista powodow, informacje do wyswietlenia
local function Extras(s, d, hs)
    local db = ns.db
    local pts, why, info = 0, {}, {}
    local function add(n, txt)
        pts = pts + n
        why[#why + 1] = txt
    end

    -- 1) swiezosc danych
    local nPts, nUniq, prev = 0, 0, nil
    local rec = db.items[s]
    if rec then
        for _, p in ipairs(rec.hist) do
            nPts = nPts + 1
            local v = p[2] or 0
            if prev == nil or v ~= prev then nUniq = nUniq + 1 end
            prev = v
        end
    end
    info.nPts, info.nUniq = nPts, nUniq
    if nPts >= 8 and nUniq <= 3 then
        info.stale = true
        add(8, "malo roznych wartosci w historii (plaski rynek albo nieswieze dane)")
    end

    -- 2) krotka historia
    if hs and hs.spanDays then
        info.span = hs.spanDays
        if hs.spanDays < 1 then add(14, "historia krotsza niz doba")
        elseif hs.spanDays < 3 then add(8, "krotka historia (< 3 dni)")
        elseif hs.spanDays < 5 then add(4, "historia < 5 dni") end
    end

    -- 3) czas sprzedazy
    local share = clamp(db.riskShare or 0.5, 0.05, 1)
    local perDay = d.perDay and (d.perDay / (db.perDayDiv or 1)) or nil
    local lot = db.lots[s]
    local qty = lot and lot.qty
    if not qty or qty <= 0 then
        local op = db.openPosts[s]
        if op then
            qty = 0
            for _, p in ipairs(op) do qty = qty + p.qty end
        end
    end
    info.share, info.perDay, info.qty = share, perDay, (qty and qty > 0) and qty or nil
    if perDay and perDay > 0 then
        info.maxSell = math.max(1, math.floor(perDay * share * 2))   -- ile sztuk sprzeda sie w 48h (czas aukcji)
        if info.qty then
            info.days = info.qty / (perDay * share)
            if info.days > 4 then add(20, string.format("sprzedaz %d szt. zajmie ~%.0f dni", info.qty, info.days))
            elseif info.days > 2 then add(10, string.format("sprzedaz %d szt. zajmie ~%.1f dnia", info.qty, info.days)) end
        end
    end

    -- 4) bufor spadku (liczony od ceny zakupu: zapisanej albo aktualnej min)
    local ref = d.market or d.recent or d.regionSale or d.minbuy
    local buy = db.buyPrice[s] or d.minbuy
    if ref and buy and ref > 0 then
        local keep = 1 - ns.Cut() / 100
        local be = buy / keep
        local buf = (ref - be) / ref * 100
        local trust = ns.EconomyTrust()
        local sigma = hs and hs.stdevPct or nil
        local sEff = math.max(sigma or 0, (trust < 1) and 5 or 2)   -- podloga zmiennosci (w mlodym rynku wyzsza)
        info.buffer, info.sigma, info.sEff = buf, sigma, sEff
        info.bufferSigma = buf / sEff
        if hs and hs.n >= 8 then
            if info.bufferSigma < 1 then add(15, "maly bufor spadku (< 1x zmiennosci)")
            elseif info.bufferSigma < 2 then add(8, "umiarkowany bufor spadku (< 2x zmiennosci)") end
        end
    end
    return pts, why, info
end

local origRisk = ns.RiskScore
function ns.RiskScore(s, d, hs)
    local r = origRisk(s, d, hs)
    local db = ns.db
    if not db then return r end

    if db.riskExt ~= false then
        local pts, why, info = Extras(s, d, hs)
        if pts > 0 then
            r.score = math.min(100, r.score + pts)
            r.level = Level(r.score)
            for _, w in ipairs(why) do r.why[#r.why + 1] = w end
            -- p z heurystyki przeliczamy; p z wlasnych danych / modelu ML zostaje (to pomiar, nie zgadywanie)
            if not r.pOwn and not r.pML then
                r.p = clamp(0.9 - r.score / 100 * 0.6, 0.25, 0.9)
            end
        end
        r.extra, r.extraPts = info, pts
    end

    -- przedzial niepewnosci p
    local n, src
    if r.pOwn then
        n, src = math.max(r.nOwn or 10, 10), "wlasne dane"
    elseif r.pML then
        n, src = 8 + math.min(150, ((db.ml and db.ml.nW) or 0) * 0.5), "model ML"
    else
        n, src = 8, "szac."
    end
    r.pLo, r.pHi = wilson(clamp(r.p, 0.01, 0.99), n)
    r.pN, r.pSrc = n, src
    return r
end

-- zapamietanie ostatniej analizy wybranego przedmiotu (do wyswietlenia na HUD) + limit ilosci wg tempa sprzedazy
local last, lastS
local origAnalyze = ns.Analyze
function ns.Analyze(s, d, buy)
    local r = origAnalyze(s, d, buy)
    local x = r.risk and r.risk.extra
    if x and x.maxSell and r.maxUnits then
        r.maxUnits = math.min(r.maxUnits, x.maxSell)
    end
    if ns.db and s == ns.db.selected then last, lastS = r, s end
    return r
end

------------------------------------------------------------------
-- Linie opisu ryzyka (komenda /tsma risk; na HUD pokazuje je zakladka "Ryzyko") i komenda
------------------------------------------------------------------
local function BlockLines(r)
    local rk = r and r.risk
    if not rk then return nil end
    local lines = {}
    local function gray(t) return "|cff9aa0a6" .. t .. "|r" end

    if rk.pLo then
        lines[#lines + 1] = string.format("p sprzedazy %.0f%% (przedzial 95%%: %.0f-%.0f%%, %s, n~%.0f)",
            rk.p * 100, rk.pLo * 100, rk.pHi * 100, rk.pSrc, rk.pN)
    end
    local x = rk.extra
    if x then
        if x.buffer then
            local col = (x.bufferSigma < 1 and "|cffff4040") or (x.bufferSigma < 2 and "|cffffcc33") or "|cff33dd66"
            local floorNote = (not x.sigma or x.sEff > x.sigma) and " (przyjeta podloga)" or ""
            lines[#lines + 1] = string.format("Bufor spadku: %s%.0f%% = %.1fx zmiennosci %.0f%%|r%s",
                col, x.buffer, x.bufferSigma, x.sEff, gray(floorNote))
        end
        if x.perDay then
            local t = string.format("Rynek ~%.1f szt./dzien; w 48h Twoje ~%d szt. (zakl. %.0f%% udzialu)",
                x.perDay, x.maxSell or 0, x.share * 100)
            if x.days then
                local col = (x.days > 4 and "|cffff4040") or (x.days > 2 and "|cffffcc33") or "|cff33dd66"
                t = t .. string.format("; %d szt. = %s~%.1f dnia|r", x.qty, col, x.days)
            end
            lines[#lines + 1] = t
        else
            lines[#lines + 1] = gray("Tempo sprzedazy: brak danych z TSM (nie da sie oszacowac czasu sprzedazy)")
        end
        local dline = string.format("Dane: %d roznych wartosci w %d pomiarach", x.nUniq, x.nPts)
        if x.span then dline = dline .. string.format(", historia %.1f dnia", x.span) end
        if x.stale then dline = dline .. " |cffffa040- plaski rynek albo nieswieze dane TSM (zrob /reload)|r" end
        lines[#lines + 1] = dline
    end
    return lines
end

local function Plain(t)
    return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function RiskCommand()
    local db = ns.db
    local s = db.selected
    if not s then ns.Print("Najpierw wybierz przedmiot."); return end
    local d = ns.cache[s] or ns.FetchTSM(s)
    local r = ns.Analyze(s, d, (ns.EffectiveBuy(s, d)))
    if r.verdict == "NODATA" then ns.Print("Brak danych z TSM dla tego przedmiotu."); return end
    ns.Print(string.format("Ryzyko %s: %d pkt (w tym %d z rozszerzonej oceny)", ns.ItemName(s), r.risk.score, r.risk.extraPts or 0))
    for _, w in ipairs(r.risk.why) do ns.Print("  - " .. w) end
    for _, l in ipairs(BlockLines(r) or {}) do ns.Print("  " .. Plain(l)) end
end

------------------------------------------------------------------
-- Ustawienia i komenda /tsma risk
------------------------------------------------------------------
table.insert(ns.FIELDS, { key = "riskShare", label = "Udzial w sprzedazy rynku (0-1)", kind = "num", min = 0.05, max = 1 })
table.insert(ns.TOGGLES, { key = "riskExt", label = "Rozszerzona ocena ryzyka (dane, czas sprzedazy, bufor)" })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = (msg or ""):match("^(%S*)")
    if (cmd or ""):lower() == "risk" and ns.db then
        RiskCommand()
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
    if ns.UpdateUI then ns.UpdateUI() end
end)
