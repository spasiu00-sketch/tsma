local ADDON, ns = ...

------------------------------------------------------------------
-- ZYSK (tylko TSM + Twoje dane): realna cena sprzedazy z hierarchii
--   1) Twoje realne sprzedaze z dziennika (>= REAL_MIN szt. w 45 dni, srednia wazona iloscia)
--   2) mediana wlasnych punktow ceny min z 7 dni (>= MIN_PTS punktow, historia >= MIN_SPAN dni)
--   3) DBRegionSaleAvg
--   4) cena ref.
-- zawsze nie wyzej niz cena ref.
-- Dalej: koszt ponownych wystawien, ROI na dobe, zysk na dobe, "kupuj do" z realnej ceny,
-- scenariusz pesymistyczny, korekta wg Twoich realnych wynikow na przedmiocie.
-- Nadpisuje r.expected / r.expectedPct / r.maxBuy i tylko OBNIZA werdykt.
-- Dodaje r.profit = { sell, src, nPts, net, pct, days, roiDay, profitDay, failCost, worst, worstPct, sigma }
-- Komendy: /tsma top (ranking wg zysku na dobe), /tsma pl (Twoje realne wyniki)
------------------------------------------------------------------

local DEFAULTS = { profitOn = true, minRoiDay = 1, maxLoss = 25 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local WINDOW    = 7 * 86400   -- okno wlasnych punktow
local MIN_PTS   = 30          -- ile punktow w oknie, zeby ufac wlasnym danym
local MIN_SPAN  = 2           -- ile dni historii
local REAL_DAYS = 45          -- okno realnych sprzedazy z dziennika
local REAL_MIN  = 5           -- min. sprzedanych sztuk, zeby ufac realnej cenie / ocenie wyniku

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

------------------------------------------------------------------
-- Realne wyniki z dziennika (cache 60 s)
------------------------------------------------------------------
local rsCache, rsSig, rsT
local function Realized()
    local log = ns.db.log
    local last = log[#log]
    local sig = #log .. ":" .. (last and last.t or 0)
    local now = GetTime()
    if rsCache and sig == rsSig and rsT and now - rsT < 60 then return rsCache end
    rsCache, rsSig, rsT = {}, sig, now
    local cutoff = time() - REAL_DAYS * 86400
    for _, e in ipairs(log) do
        if e.t >= cutoff then
            local st = rsCache[e.s]
            if not st then
                st = { sold = 0, rev = 0, profit = 0, nProfit = 0, exp = 0 }
                rsCache[e.s] = st
            end
            if e.kind == "sell" then
                st.sold = st.sold + e.qty
                st.rev = st.rev + e.qty * e.price
                if e.profit then
                    st.profit = st.profit + e.profit
                    st.nProfit = st.nProfit + e.qty
                end
            elseif e.kind == "expired" then
                st.exp = st.exp + e.qty
                st.profit = st.profit + (e.profit or 0)   -- utracony depozyt (ujemny)
            end
        end
    end
    return rsCache
end

------------------------------------------------------------------
-- Hierarchia ceny sprzedazy
------------------------------------------------------------------
-- zwraca: cena, zrodlo, liczba probek
local function RealSell(s, d, r, real)
    local ref = r.sellRef
    if real and real.sold >= REAL_MIN then
        return math.min(ref, real.rev / real.sold), "Twoje sprzedaze", real.sold
    end
    local hs = r.hs
    if hs and hs.spanDays and hs.spanDays >= MIN_SPAN then
        local med, n = ns.HistMedianSince(s, WINDOW)
        if med and n >= MIN_PTS then
            return math.min(ref, med), "wlasne punkty", n
        end
    end
    if d.regionSale and d.regionSale > 0 then
        return math.min(ref, d.regionSale), "DBRegionSaleAvg", 0
    end
    return ref, "cena ref.", 0
end

local function Enhance(s, d, r)
    local db = ns.db
    local keep = 1 - ns.Cut() / 100
    local p = clamp(r.risk.p, 0.05, 0.95)
    local perDay = d.perDay and (d.perDay / (db.perDayDiv or 1)) or nil
    local share = clamp(db.riskShare or 0.5, 0.05, 1)
    local real = Realized()[s]

    local sell, src, nPts = RealSell(s, d, r, real)
    local dep = r.deposit or 0
    local failCost = dep * (1 - p) / p            -- oczekiwany depozyt stracony na nieudanych wystawieniach
    local net = sell * keep - r.buy - failCost
    local pct = net / r.buy * 100
    local days = 2 / p - 1                        -- oczekiwany czas obrotu kapitalu (dni)
    local roiDay = pct / days

    -- scenariusz pesymistyczny: cena nizsza o zmiennosc (max 60%)
    local sigma = clamp((r.hs and r.hs.stdevPct) or 0, 0, 60)
    local worst = sell * (1 - sigma / 100) * keep - r.buy - failCost
    local worstPct = worst / r.buy * 100

    local profitDay
    if perDay and perDay > 0 then
        local unitsDay = perDay * share
        if r.maxUnits then unitsDay = math.min(unitsDay, r.maxUnits / days) end
        profitDay = net * unitsDay
    end

    r.profit = { sell = sell, src = src, nPts = nPts, net = net, pct = pct, days = days, roiDay = roiDay,
        profitDay = profitDay, failCost = failCost, worst = worst, worstPct = worstPct, sigma = sigma }
    r.expectedRef, r.expectedPctRef = r.expected, r.expectedPct
    r.expected, r.expectedPct = net, pct

    -- kupuj do: najwyzsza cena, przy ktorej realny zysk spelnia margines
    local minPct = db.margin or 0
    local mb = math.floor((sell * keep - failCost) / (1 + minPct / 100))
    r.maxBuyRef = r.maxBuy
    r.maxBuy = (mb > 0) and mb or nil

    -- werdykt: tylko obnizanie
    local old = r.verdict
    local minRoi, maxLoss = db.minRoiDay or 0, db.maxLoss or 0
    local reasons = {}
    if net <= 0 then
        r.verdict = "NO"
        reasons[#reasons + 1] = string.format("realny zysk %+.1f%%", pct)
    elseif old == "BUY" then
        if pct < minPct then
            reasons[#reasons + 1] = string.format("zysk %+.1f%% < %.0f%%", pct, minPct)
        end
        if roiDay < minRoi then
            reasons[#reasons + 1] = string.format("ROI %+.1f%%/dobe < %.1f%%", roiDay, minRoi)
        end
        if maxLoss > 0 and worstPct < -maxLoss then
            reasons[#reasons + 1] = string.format("scenariusz pesymistyczny %+.0f%% (zmiennosc %.0f%%)", worstPct, sigma)
        end
        if real and real.nProfit >= REAL_MIN and real.profit < 0 then
            reasons[#reasons + 1] = string.format("Twoj wynik na tym przedmiocie: -%s (%d szt., %d dni)",
                ns.MoneyPlain(real.profit), real.nProfit, REAL_DAYS)
        end
        if #reasons > 0 then r.verdict = "MARGINAL" end
    end

    local notes = {}
    if r.verdict ~= old and #reasons > 0 then
        notes[#notes + 1] = "Werdykt obnizony: " .. table.concat(reasons, "; ") .. "."
    end
    if src ~= "cena ref." and sell < r.sellRef * 0.98 then
        notes[#notes + 1] = string.format("Realna cena sprzedazy %s (%s%s) zamiast ref. %s.",
            ns.MoneyPlain(sell), src, nPts > 0 and (", " .. nPts .. " szt./pkt") or "", ns.MoneyPlain(r.sellRef))
    end
    if failCost > r.buy * 0.03 then
        notes[#notes + 1] = string.format("Ponowne wystawienia kosztuja srednio %s/szt. (depozyt przy p=%.0f%%).",
            ns.MoneyPlain(failCost), p * 100)
    end
    for i = #notes, 1, -1 do table.insert(r.notes, 1, notes[i]) end
end

local origAnalyze = ns.Analyze
function ns.Analyze(s, d, buy)
    local r = origAnalyze(s, d, buy)
    local db = ns.db
    if not (db and db.profitOn) or r.verdict == "NODATA" or not (r.buy and r.sellRef and r.risk) then return r end
    ns.Safe("profit", Enhance, s, d, r)
    return r
end

------------------------------------------------------------------
-- /tsma top: obserwowane i zapas wg zysku na dobe (zakup po akt. min)
------------------------------------------------------------------
local function Top()
    if not ns.HasTSM() then ns.Print("TSM nie wykryte."); return end
    local rows = {}
    for _, s in ipairs(ns.RefreshList()) do
        local d = ns.cache[s] or ns.FetchTSM(s)
        local ok, r = pcall(ns.Analyze, s, d, nil)
        if ok and r and r.profit and r.verdict ~= "NODATA" then
            rows[#rows + 1] = { s = s, r = r }
        end
    end
    table.sort(rows, function(a, b)
        local x, y = a.r.profit.profitDay or -1e18, b.r.profit.profitDay or -1e18
        if x ~= y then return x > y end
        return a.r.profit.roiDay > b.r.profit.roiDay
    end)
    if #rows == 0 then ns.Print("Brak danych (lista pusta albo opcja profitOn wylaczona)."); return end
    ns.Print("Ranking wg zysku na dobe (zakup po akt. min):")
    for i = 1, math.min(10, #rows) do
        local r, pf = rows[i].r, rows[i].r.profit
        ns.Print(string.format("  %d. %s %s  zysk/szt. %s  ROI %+.1f%%/dobe  ~%s/dobe  kupuj do %s  [%s]", i,
            ns.ItemName(rows[i].s), ns.VERDICT_SHORT[r.verdict], ns.MoneyPlain(pf.net), pf.roiDay,
            pf.profitDay and ns.MoneyPlain(pf.profitDay) or "?", r.maxBuy and ns.MoneyPlain(r.maxBuy) or "-", pf.src))
    end
end

------------------------------------------------------------------
-- /tsma pl: Twoje realne wyniki z dziennika (45 dni)
------------------------------------------------------------------
local function PL()
    local rows, total = {}, 0
    for s, v in pairs(Realized()) do
        if v.sold > 0 or v.exp > 0 then
            rows[#rows + 1] = { s = s, v = v }
            total = total + v.profit
        end
    end
    if #rows == 0 then ns.Print("Brak sprzedazy / wygasniec w dzienniku z ostatnich " .. REAL_DAYS .. " dni."); return end
    table.sort(rows, function(a, b) return a.v.profit > b.v.profit end)
    ns.Print(string.format("Realne wyniki (%d dni): %d przedmiotow, zysk netto lacznie %s", REAL_DAYS, #rows, ns.Money(total)))
    local function line(x)
        ns.Print(string.format("  %s: %s  (sprzedano %d, wygaslo %d)", ns.ItemName(x.s), ns.Money(x.v.profit), x.v.sold, x.v.exp))
    end
    ns.Print("Najlepsze:")
    for i = 1, math.min(5, #rows) do line(rows[i]) end
    if #rows > 5 then
        ns.Print("Najgorsze:")
        for i = #rows, math.max(6, #rows - 4), -1 do line(rows[i]) end
    end
end

------------------------------------------------------------------
-- Ustawienia, komendy, start
------------------------------------------------------------------
table.insert(ns.FIELDS, { key = "minRoiDay", label = "Min. ROI na dobe (%)", kind = "num", min = 0, max = 100 })
table.insert(ns.FIELDS, { key = "maxLoss", label = "Max strata w scen. pesymistycznym (%, 0 = wyl.)", kind = "num", min = 0, max = 100 })
table.insert(ns.TOGGLES, { key = "profitOn", label = "Zysk: realna cena sprzedazy, ROI/dobe, ostrzejszy werdykt" })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = (msg or ""):match("^(%S*)")
    cmd = (cmd or ""):lower()
    if cmd == "top" and ns.db then
        Top()
    elseif (cmd == "pl" or cmd == "wyniki") and ns.db then
        PL()
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
end)
