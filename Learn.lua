local ADDON, ns = ...

------------------------------------------------------------------
-- UCZENIE W ADDONIE (lekkie modele statystyczne, bez zewnetrznych narzedzi)
--  1) model sprzedazy: regresja logistyczna uczona online na Twoich wystawieniach (sprzedane / wygasle)
--  2) cena wystawienia wg modelu: maksimum oczekiwanego zysku (p sprzedazy * zysk - (1-p) * depozyt)
--  3) prognoza ceny minimalnej za 6h i 24h (powrot do mediany, AR(1)) z oceną na danych historycznych
--  4) wzorzec dobowy i tygodniowy cen (z historii wszystkich sledzonych przedmiotow)
--  5) auto-kalibracja marginesu na podstawie trafnosci werdyktow KUP
-- Domyslnie TRYB CIENIA: modele licza i pokazuja wyniki w oknie "ML" (przycisk na HUD), ale nic nie zmieniaja.
-- Wplyw na werdykty wlaczysz w ustawieniach (ML: uzywaj modelu / auto-korekta marginesu).
------------------------------------------------------------------

local NF = 8                                   -- liczba cech modelu
local W0 = { 0.8, -3.0, -3.0, 0.5, 0.3, -0.4, 0, 0 }   -- wagi startowe (przekonania a priori)
local LR, LAM, LRB, LAMB, WCAP = 0.05, 0.05, 0.05, 0.1, 3
local MIN_READY_N = 40                         -- tyle rozliczonych wystawien, zanim model moze byc "gotowy"

local DEFAULTS = { mlUse = false, mlAutoCal = false, mlShown = false }

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

local function sigmoid(z)
    z = clamp(z, -12, 12)
    return 1 / (1 + math.exp(-z))
end

local function medianOf(vals)
    local n = #vals
    if n == 0 then return nil end
    local t = {}
    for i, v in ipairs(vals) do t[i] = v end
    table.sort(t)
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return (t[n / 2] + t[n / 2 + 1]) / 2
end

local function M()
    return ns.db and ns.db.ml
end

local function InitDB()
    local db = ns.db
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.ml) ~= "table" then db.ml = {} end
    local ml = db.ml
    if type(ml.w) ~= "table" or #ml.w ~= NF then
        ml.w = {}
        for i = 1, NF do ml.w[i] = W0[i] end
    end
    ml.ib = ml.ib or {}
    ml.pend = ml.pend or {}
    ml.n = ml.n or 0          -- liczba rozliczonych zdarzen (uczacych aktualizacji)
    ml.pos = ml.pos or 0      -- suma wazona sprzedanych
    ml.nW = ml.nW or 0        -- suma wazona wszystkich
    ml.bsML = ml.bsML or 0    -- skumulowany blad Briera modelu (przed aktualizacja)
    ml.bsBase = ml.bsBase or 0 -- ... i stalej bazowej (srednia sprzedazy)
    -- wystawienia starsze niz 4 dni nie moga juz byc aktywne
    local now = time()
    for s, list in pairs(ml.pend) do
        local keep = {}
        for _, e in ipairs(list) do
            if now - e.t < 4 * 86400 then keep[#keep + 1] = e end
        end
        ml.pend[s] = (#keep > 0) and keep or nil
    end
end

------------------------------------------------------------------
-- Cechy i model sprzedazy
------------------------------------------------------------------
-- 1 wyraz wolny, 2 ln(cena/ref), 3 ln(cena/min), 4 sale rate, 5 trend, 6 zmiennosc, 7-8 pora dnia
local function features(price, ref, d, hs, t)
    local x = { 1, 0, 0, 0, 0, 0, 0, 0 }
    if ref and ref > 0 and price and price > 0 then x[2] = clamp(math.log(price / ref), -1, 1) end
    if d and d.minbuy and d.minbuy > 0 and price and price > 0 then x[3] = clamp(math.log(price / d.minbuy), -1, 1) end
    if d and d.saleRate then x[4] = math.log(1 + d.saleRate * 20) / 3 end
    if hs and hs.trend then x[5] = clamp(hs.trend / 10, -1, 1) end
    if hs and hs.stdevPct then x[6] = clamp(hs.stdevPct / 50, 0, 2) end
    t = t or time()
    local h = tonumber(date("%H", t)) + tonumber(date("%M", t)) / 60
    x[7] = math.sin(2 * math.pi * h / 24)
    x[8] = math.cos(2 * math.pi * h / 24)
    return x
end

local function predict(x, s)
    local ml = M()
    local z = (ml.ib[s] or 0)
    for i = 1, NF do z = z + ml.w[i] * x[i] end
    return sigmoid(z)
end

local function train(s, x, y, units)
    local ml = M()
    local wt = math.min(units, WCAP)
    local p = predict(x, s)
    local base = (ml.pos + 1) / (ml.nW + 2)
    ml.bsML = ml.bsML + wt * (p - y) ^ 2
    ml.bsBase = ml.bsBase + wt * (base - y) ^ 2
    for i = 1, NF do
        ml.w[i] = ml.w[i] + LR * wt * (y - p) * x[i] - LR * LAM * (ml.w[i] - W0[i])
    end
    local b = ml.ib[s] or 0
    ml.ib[s] = clamp(b + LRB * wt * (y - p) - LRB * LAMB * b, -1.5, 1.5)
    ml.n = ml.n + 1
    ml.pos = ml.pos + y * wt
    ml.nW = ml.nW + wt
end

-- (ml, przewaga nad stala w skali Briera, czy gotowy)
local function ModelStats()
    local ml = M()
    local skill
    if ml.nW > 0 and ml.bsBase > 0 then skill = 1 - ml.bsML / ml.bsBase end
    local ready = (ml.n >= MIN_READY_N and skill and skill > 0.03) and true or false
    return ml, skill, ready
end

local function RefPrice(d)
    return d and (d.market or d.recent or d.regionSale or d.minbuy)
end

-- zapis cech w chwili wystawienia (do pozniejszego rozliczenia sprzedane / wygasle)
local function capture(s, qty, price)
    local ml = M()
    if not ml or not price or price <= 0 or not qty or qty <= 0 then return end
    local d = ns.cache[s] or ns.FetchTSM(s)
    local hs = ns.HistStats(s)
    local ok, r = pcall(ns.Analyze, s, d, nil)
    local ref = (ok and r and r.sellRef) or RefPrice(d)
    if not ref then return end
    local list = ml.pend[s]
    if not list then list = {}; ml.pend[s] = list end
    list[#list + 1] = { t = time(), qty = qty, x = features(price, ref, d, hs, time()) }
end

-- rozliczenie najstarszych wystawien (FIFO): y = 1 sprzedane, 0 wygasle
local function resolve(s, qty, y)
    local ml = M()
    if not ml then return end
    local list = ml.pend[s]
    local remaining = qty
    while remaining > 0 and list and list[1] do
        local e = list[1]
        local take = math.min(e.qty, remaining)
        train(s, e.x, y, take)
        e.qty = e.qty - take
        remaining = remaining - take
        if e.qty <= 0 then table.remove(list, 1) end
    end
    if list and #list == 0 then ml.pend[s] = nil end
end

-- podpiecie pod istniejace funkcje dziennika (kazde wystawienie / sprzedaz / wygasniecie uczy model)
local origPost, origSell, origExpire = ns.Post, ns.Sell, ns.Expire

function ns.Post(s, qty, price)
    origPost(s, qty, price)
    ns.Safe("ml", capture, s, qty, price)
end

function ns.Sell(s, qty, price, noConsume)
    local ok, res = origSell(s, qty, price, noConsume)
    if ok then ns.Safe("ml", resolve, s, qty, 1) end
    return ok, res
end

function ns.Expire(s, qty, deposit, noConsume)
    local r = origExpire(s, qty, deposit, noConsume)
    ns.Safe("ml", resolve, s, qty, 0)
    return r
end

------------------------------------------------------------------
-- 2) Cena wystawienia wg modelu
------------------------------------------------------------------
local function Suggest(s, d, r, hs)
    if not (r and r.buy and r.sellRef and r.deposit) then return nil end
    local keep = 1 - ns.Cut() / 100
    local now = time()
    local function ev(price)
        local p = predict(features(price, r.sellRef, d, hs, now), s)
        return p, p * (price * keep - r.buy) - (1 - p) * r.deposit
    end
    local bestP, bestPrice, bestE
    for m = 80, 130 do
        local price = math.floor(r.sellRef * m / 100 + 0.5)
        if price > 0 then
            local p, e = ev(price)
            if not bestE or e > bestE then bestP, bestPrice, bestE = p, price, e end
        end
    end
    if not bestPrice then return nil end
    local curP, curE = ev(r.suggest)
    return { price = bestPrice, p = bestP, e = bestE, curP = curP, curE = curE }
end

------------------------------------------------------------------
-- 3) Prognoza ceny (AR(1) wokol mediany) + ocena na danych historycznych
------------------------------------------------------------------
local function hourlySeries(s)
    local rec = ns.db.items[s]
    if not rec then return nil end
    local pts = {}
    for _, p in ipairs(rec.hist) do
        if p[2] and p[2] > 0 then pts[#pts + 1] = { p[1], math.log(p[2]) } end
    end
    if #pts < 24 then return nil end
    local t0 = math.floor(pts[1][1] / 3600)
    local now = math.floor(time() / 3600)
    if now - t0 < 48 then return nil end
    if now - t0 > 336 then t0 = now - 336 end
    local ys, j, last = {}, 1, pts[1][2]
    for h = t0, now do
        while pts[j] and math.floor(pts[j][1] / 3600) <= h do
            last = pts[j][2]
            j = j + 1
        end
        ys[#ys + 1] = last
    end
    return ys
end

local function fitAR(ys, i1, i2)
    local vals = {}
    for i = i1, i2 do vals[#vals + 1] = ys[i] end
    local mu = medianOf(vals)
    local num, den = 0, 0
    for i = i1 + 1, i2 do
        local a, b = ys[i - 1] - mu, ys[i] - mu
        num = num + a * b
        den = den + a * a
    end
    local phi = (den > 0) and clamp(num / den, 0, 0.995) or 0
    return mu, phi
end

local function Forecast(s)
    local ys = hourlySeries(s)
    if not ys then return nil end
    local N = #ys
    local mu, phi = fitAR(ys, 1, N)
    local yT = ys[N]
    local out = {}
    for _, h in ipairs({ 6, 24 }) do
        local yh = mu + (phi ^ h) * (yT - mu)
        local skill, nt
        local split = math.floor(N * 0.6)
        if split >= 24 then
            local mu2, phi2 = fitAR(ys, 1, split)
            local em, en, c = 0, 0, 0
            for t = split, N - h do
                local pred = mu2 + (phi2 ^ h) * (ys[t] - mu2)
                em = em + math.abs(ys[t + h] - pred)
                en = en + math.abs(ys[t + h] - ys[t])
                c = c + 1
            end
            if c >= 24 and en > 0 then skill, nt = 1 - em / en, c end
        end
        out[h] = { price = math.exp(yh), pct = (math.exp(yh - yT) - 1) * 100, skill = skill, n = nt }
    end
    return out
end

------------------------------------------------------------------
-- 4) Wzorzec dobowy i tygodniowy
------------------------------------------------------------------
local function accumulateProfile(rec, hours, days)
    local byDay = {}
    for _, p in ipairs(rec.hist) do
        if p[2] and p[2] > 0 then
            local k = date("%Y%m%d", p[1])
            local g = byDay[k]
            if not g then g = { pts = {}, sum = 0, n = 0, t = p[1] }; byDay[k] = g end
            local y = math.log(p[2])
            g.pts[#g.pts + 1] = { p[1], y }
            g.sum = g.sum + y
            g.n = g.n + 1
        end
    end
    -- srednie dobowe (doby z >= 3 punktami)
    local means = {}
    for _, g in pairs(byDay) do
        if g.n >= 3 then
            g.mean = g.sum / g.n
            means[#means + 1] = { x = math.floor(g.t / 86400), y = g.mean, g = g }
        end
    end
    -- wzorzec w ciagu doby: odchylenie od sredniej tej doby
    for _, m in ipairs(means) do
        for _, q in ipairs(m.g.pts) do
            local h = tonumber(date("%H", q[1]))
            local b = hours[h]
            if not b then b = { 0, 0 }; hours[h] = b end
            b[1] = b[1] + (q[2] - m.y)
            b[2] = b[2] + 1
        end
    end
    -- wzorzec tygodniowy: odchylenie sredniej doby od trendu liniowego (min. 10 dob)
    if #means >= 10 then
        local sx, sy, sxx, sxy, n = 0, 0, 0, 0, #means
        for _, m in ipairs(means) do
            sx, sy = sx + m.x, sy + m.y
            sxx, sxy = sxx + m.x * m.x, sxy + m.x * m.y
        end
        local den = n * sxx - sx * sx
        local slope = (den ~= 0) and (n * sxy - sx * sy) / den or 0
        local icpt = (sy - slope * sx) / n
        for _, m in ipairs(means) do
            local wd = tonumber(date("%w", m.g.t))
            local b = days[wd]
            if not b then b = { 0, 0 }; days[wd] = b end
            b[1] = b[1] + (m.y - (icpt + slope * m.x))
            b[2] = b[2] + 1
        end
    end
end

local DAYNAMES = { [0] = "niedziela", "poniedzialek", "wtorek", "sroda", "czwartek", "piatek", "sobota" }

local function Summarize(hours, days)
    local res = {}
    local avg, total = {}, 0
    for h = 0, 23 do
        local b = hours[h]
        if b then total = total + b[2] end
        if b and b[2] >= 3 then avg[h] = b[1] / b[2] end
    end
    local lo, hi, loH, hiH
    for h = 0, 23 do
        local s, c = 0, 0
        for k = 0, 2 do
            local v = avg[(h + k) % 24]
            if v then s, c = s + v, c + 1 end
        end
        if c == 3 then
            local m = s / 3
            if not lo or m < lo then lo, loH = m, h end
            if not hi or m > hi then hi, hiH = m, h end
        end
    end
    if lo and total >= 60 and (math.exp(hi - lo) - 1) * 100 >= 2 then
        res.hour = { lo = loH, loPct = (math.exp(lo) - 1) * 100, hi = hiH, hiPct = (math.exp(hi) - 1) * 100, n = total }
    end

    local dl, dh, dlW, dhW, cnt = nil, nil, nil, nil, 0
    for wd = 0, 6 do
        local b = days[wd]
        if b and b[2] >= 2 then
            cnt = cnt + 1
            local v = b[1] / b[2]
            if not dl or v < dl then dl, dlW = v, wd end
            if not dh or v > dh then dh, dhW = v, wd end
        end
    end
    if cnt == 7 and (math.exp(dh - dl) - 1) * 100 >= 3 then
        res.day = { lo = dlW, loPct = (math.exp(dl) - 1) * 100, hi = dhW, hiPct = (math.exp(dh) - 1) * 100 }
    end
    return res
end

local function ItemPattern(s)
    local rec = ns.db.items[s]
    if not rec then return nil end
    local hours, days = {}, {}
    accumulateProfile(rec, hours, days)
    return Summarize(hours, days)
end

local gCache, gT
local function GlobalPattern()
    if gCache and gT and time() - gT < 600 then return gCache end
    local hours, days = {}, {}
    for _, rec in pairs(ns.db.items) do
        if rec.hist then accumulateProfile(rec, hours, days) end
    end
    gCache, gT = Summarize(hours, days), time()
    return gCache
end

------------------------------------------------------------------
-- 5) Kalibracja werdyktow (margines)
------------------------------------------------------------------
local function CalInfo()
    local a = ns.db.accAgg and ns.db.accAgg.BUY
    if not a or a.n < 30 then return { n = a and a.n or 0, adj = 0 } end
    local rOk, rM = a.ok / a.n, a.okMargin / a.n
    local adj = clamp(math.floor((0.55 - rM) * 25 + 0.5), -3, 10)
    return { n = a.n, rOk = rOk, rM = rM, adj = adj, chg = a.chg / a.n }
end

-- gdy wlaczone: Analyze liczy z poprawionym marginesem (w punktach procentowych)
local origAnalyze = ns.Analyze
function ns.Analyze(s, d, buy)
    local db = ns.db
    local adj = (db and db.mlAutoCal) and CalInfo().adj or 0
    if adj == 0 then return origAnalyze(s, d, buy) end
    local old = db.margin
    db.margin = math.max(0, old + adj)
    local ok, r = pcall(origAnalyze, s, d, buy)
    db.margin = old
    if not ok then error(r, 0) end
    r.marginAdj = adj
    return r
end

-- gdy wlaczone i model gotowy: p sprzedazy = mieszanka heurystyki i modelu (waga rosnie z liczba probek)
local origRisk = ns.RiskScore
function ns.RiskScore(s, d, hs)
    local r = origRisk(s, d, hs)
    local db = ns.db
    if db and db.mlUse and db.ml then
        local ml, _, ready = ModelStats()
        local ref = RefPrice(d)
        if ready and ref then
            local pml = predict(features(ref, ref, d, hs, time()), s)
            local a = math.min(0.8, ml.n / 200)
            r.pHeur, r.pML = r.p, pml
            r.p = clamp((1 - a) * r.p + a * pml, 0.05, 0.95)
        end
    end
    return r
end

------------------------------------------------------------------
-- Okno "ML" (przycisk na HUD) i komenda /tsma ml
------------------------------------------------------------------
local function pct(v) return string.format("%+.1f%%", v) end
local function hh(h) return string.format("%02d:00-%02d:00", h, (h + 3) % 24) end

local cache = {}   -- prognoza i wzorzec per przedmiot (przeliczane tylko po zmianie historii)

local function heavy(s)
    local rec = ns.db.items[s]
    local h = rec and rec.hist
    local key = s .. ":" .. (h and #h or 0) .. ":" .. (h and h[#h] and h[#h][1] or 0)
    if cache.key ~= key then
        cache.key = key
        cache.forecast = Forecast(s)
        cache.pattern = ItemPattern(s)
    end
    return cache.forecast, cache.pattern
end

local function BuildText()
    local db = ns.db
    local lines = {}
    local function add(t) lines[#lines + 1] = t end
    local function gray(t) return "|cff9aa0a6" .. t .. "|r" end

    local ml, skill, ready = ModelStats()
    local cal = CalInfo()

    -- stan modelu
    add("|cffffffffModel sprzedazy|r  " .. string.format("rozliczonych wystawien: %d", ml.n)
        .. "   przewaga nad stala: " .. (skill and pct(skill * 100) or "brak"))
    local state
    if db.mlUse and ready then
        state = string.format("|cff33dd66AKTYWNY|r - wplywa na p sprzedazy (waga modelu %.0f%%)", math.min(0.8, ml.n / 200) * 100)
    elseif ready then
        state = "|cffffcc33GOTOWY, ale tryb cienia|r - wlacz w Ustaw: \"ML: uzywaj modelu\""
    else
        state = string.format("|cff9aa0a6uczy sie|r - potrzeba %d+ rozliczonych wystawien i przewagi > 3%% (jest %d)", MIN_READY_N, ml.n)
    end
    add(state)
    add("")

    local s = db.selected
    if not s then
        add(gray("Wybierz przedmiot w HUD, zeby zobaczyc sugestie i prognoze."))
    elseif not ns.HasTSM() then
        add("|cffff4040TSM nie wykryte.|r")
    else
        add("|cff33aaff" .. ns.ItemName(s) .. "|r")
        local d = ns.cache[s] or ns.FetchTSM(s)
        local buy = ns.EffectiveBuy(s, d)
        local r = ns.Analyze(s, d, buy)
        local hs = r.hs

        -- 2) cena wg modelu
        local sg = (r.verdict ~= "NODATA") and Suggest(s, d, r, hs) or nil
        if sg then
            local tag = ready and "" or gray("  (model sie uczy - orientacyjnie)")
            add("Cena wg ML: " .. ns.Money(sg.price) .. string.format("  p~%.0f%%  oczek. zysk ", sg.p * 100) .. ns.Money(sg.e) .. "/szt." .. tag)
            add("Sugestia addonu: " .. ns.Money(r.suggest) .. string.format("  p~%.0f%%  oczek. zysk ", sg.curP * 100) .. ns.Money(sg.curE) .. "/szt.")
            add(gray(string.format("Heurystyka ryzyka: p~%.0f%%", r.risk.p * 100)
                .. (r.risk.pOwn and string.format(" (wlasne dane, n=%d)", r.risk.nOwn) or " (szac.)")))
        else
            add(gray("Brak ceny odniesienia - bez sugestii ML."))
        end
        add("")

        -- 3) prognoza
        local fc, pat = heavy(s)
        if fc then
            for _, h in ipairs({ 6, 24 }) do
                local f = fc[h]
                local q
                if f.skill == nil then
                    q = gray("(za malo danych do oceny)")
                elseif f.skill > 0.05 then
                    q = string.format("|cff33dd66przewaga nad \"bez zmian\": %+.0f%%|r", f.skill * 100)
                else
                    q = string.format("|cffffcc33brak przewagi nad \"bez zmian\" (%+.0f%%)|r", f.skill * 100)
                end
                add(string.format("Prognoza min +%dh: ", h) .. ns.Money(f.price) .. " (" .. pct(f.pct) .. ")  " .. q)
            end
        else
            add(gray("Prognoza: potrzeba ok. 2+ dni historii tego przedmiotu."))
        end
        add("")

        -- 4) wzorce
        local scopeNote = "tego przedmiotu"
        if not (pat and (pat.hour or pat.day)) then
            pat = GlobalPattern()
            scopeNote = "wszystkich sledzonych"
        end
        if pat and pat.hour then
            add(string.format("Wzorzec dobowy (%s): najtaniej ok. %s (%s), najdrozej ok. %s (%s)",
                scopeNote, hh(pat.hour.lo), pct(pat.hour.loPct), hh(pat.hour.hi), pct(pat.hour.hiPct)))
        else
            add(gray("Wzorzec dobowy: brak wyraznego wzorca albo za malo danych."))
        end
        if pat and pat.day then
            add(string.format("Wzorzec tygodniowy: najtaniej %s (%s), najdrozej %s (%s)",
                DAYNAMES[pat.day.lo], pct(pat.day.loPct), DAYNAMES[pat.day.hi], pct(pat.day.hiPct)))
        else
            add(gray("Wzorzec tygodniowy: potrzeba ok. 10+ dob danych."))
        end
        add(gray("Uwaga: punkty historii powstaja tylko gdy grasz, wiec wzorzec dotyczy godzin, w ktorych jestes w grze."))
    end
    add("")

    -- 5) kalibracja
    if cal.n < 30 then
        add(string.format("Kalibracja werdyktow: za malo ocenionych prognoz KUP (%d/30).", cal.n))
    else
        add(string.format("Kalibracja: KUP ocenione %d razy, bez straty %.0f%%, z zyskiem %.0f%%, sr. zmiana ceny %s",
            cal.n, cal.rOk * 100, cal.rM * 100, pct(cal.chg)))
        add(string.format("Sugerowana korekta marginesu: %+d pp (%s)", cal.adj,
            db.mlAutoCal and "|cff33dd66stosowana|r" or "tylko sugestia - wlacz w Ustaw: \"ML: auto-korekta\""))
    end
    return table.concat(lines, "\n")
end

local win
local function RefreshWindow()
    if not (win and win:IsShown()) then return end
    win:SetScale(ns.db.scale or 1)
    win.text:SetText(BuildText())
end

local function BuildWindow()
    local f = CreateFrame("Frame", "TsmAnalizeML", UIParent, "BackdropTemplate")
    win = f
    f:SetSize(420, 420)
    f:SetPoint("TOPRIGHT", ns.frame, "TOPLEFT", -4, 0)
    ns.DarkBackdrop(f, 0.93)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    local title = ns.MakeFS(f, 14)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("|cff33aaffTSMA|r  Uczenie (ML)")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() f:Hide(); ns.db.mlShown = false end)

    f.text = ns.MakeFS(f, 11)
    f.text:SetPoint("TOPLEFT", 14, -36)
    f.text:SetWidth(392)
    f.text:SetSpacing(3)

    f:SetScript("OnShow", function() ns.Safe("ml", RefreshWindow) end)

end

if ns.UpdateUI then
    hooksecurefunc(ns, "UpdateUI", function() ns.Safe("ml", RefreshWindow) end)
end

------------------------------------------------------------------
-- Ustawienia + komenda /tsma ml
------------------------------------------------------------------
table.insert(ns.TOGGLES, { key = "mlUse", label = "ML: uzywaj modelu w ocenie (inaczej tryb cienia)" })
table.insert(ns.TOGGLES, { key = "mlAutoCal", label = "ML: auto-korekta marginesu z trafnosci" })

local function MLCommand(rest)
    local db = ns.db
    local v = (rest or ""):lower()
    if v == "reset" then
        db.ml = nil
        InitDB()
        cache = {}
        ns.Print("Model ML wyzerowany (uczy sie od nowa).")
    elseif v == "on" or v == "off" then
        db.mlUse = (v == "on")
    elseif v == "cal on" or v == "cal off" then
        db.mlAutoCal = (v == "cal on")
    elseif v == "window" or v == "okno" then
        if ns.DockSelect then ns.DockSelect("ml") end
        return
    end
    local ml, skill, ready = ModelStats()
    local cal = CalInfo()
    local npend = 0
    for _, list in pairs(ml.pend) do npend = npend + #list end
    ns.Print(string.format("ML: rozliczonych wystawien %d, oczekujacych %d, przewaga nad stala %s, %s; tryb: %s; auto-korekta marginesu: %s (sugestia %+d pp, n=%d)",
        ml.n, npend, skill and pct(skill * 100) or "brak", ready and "GOTOWY" or "uczy sie",
        db.mlUse and "aktywny" or "cien", db.mlAutoCal and "ON" or "OFF", cal.adj, cal.n))
    ns.Print("  /tsma ml on|off | cal on|off | window | reset   (okno: przycisk ML na HUD)")
    ns.UpdateUI()
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    if (cmd or ""):lower() == "ml" and ns.db and ns.db.ml then
        MLCommand(rest)
    elseif origSlash then
        origSlash(msg)
    end
end

------------------------------------------------------------------
-- Start (po zbudowaniu HUD przez Core.lua)
------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.Safe("ml", InitDB)
    if ns.frame then ns.Safe("ml", BuildWindow) end
end)
