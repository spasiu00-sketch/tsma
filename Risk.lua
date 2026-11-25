local ADDON, ns = ...

------------------------------------------------------------------
-- OCENA RYZYKA v3 (zastepuje punktacje z Core.RiskScore, gdy riskExt = ON)
--  A) P(sprzedaz): model przeplywu rynku z rozkladem UJEMNYM DWUMIANOWYM (nadmierna dyspersja sprzedazy,
--     parametr riskDisp; 0 = Poisson). Twoje sztuki schodza po "qtyAhead" sztukach przed Toba (drabina ns.live).
--  B) HIERARCHICZNA KALIBRACJA p: kazde Twoje wystawienie zapisuje prognoze modelu; po rozliczeniu (sprzedane /
--     wygasle) uczymy sie obciazenia modelu: poziom globalny -> kategoria przedmiotu (shrinkage do globalnego).
--     Przedmiot z kilkoma transakcjami dziedziczy zachowanie swojej kategorii. Potem Beta-prior z danymi wlasnymi.
--  C) RYZYKO CENY: sigma dobowa = EWMA (lambda 0.94) na przycietych log-zwrotach (odporna), powrot do sredniej
--     (AR(1) na zamknieciach: wariancja h-dobowa = sigma^2 * (1-phi^h)/(1-phi)), a gdy jest >= 25 historycznych
--     zmian h-dobowych - KWANTYLE EMPIRYCZNE tych zmian (grube ogony). Wynik: 16 kwantyli zmiany ceny (extra.zq)
--     uzywanych przez Profit.lua do CVaR.
--  D) kazdy czynnik wchodzi do punktow raz, progi ciagle, p nie jest funkcja score.
--  E) POMIAR zamiast zalozen (dane z AuctionEngine w BlizzData.lua, patrz flow.py):
--     - przeplyw rynku: it.fl = zejscia ofert z AH przy minimum (szt./dobe) z sledzenia ID aukcji, zamiast regionalnego
--       DBRegionSoldPerDay; it.fd = zmierzona dyspersja (Var = mu + phi*mu^2), gdy >= 5 dni pokrycia
--     - calib.disp: dyspersja z backtestu (gdy brak pomiaru per przedmiot), calib.zs: skala kwantyli ceny z backtestu
--       (pokrycie kwantyla 5% w backtescie na historii dobowej)
-- Wylaczenie riskExt przywraca ocene z Core/Learn.
-- Komenda: /tsma risk  |  /tsma risk cal  (kalibracja: obciazenie modelu, kategorie, krzywa niezawodnosci)
------------------------------------------------------------------

local DEFAULTS = { riskExt = true, riskShare = 0.5, riskHours = 48, riskDisp = 0.5 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local PRIOR_K = 8        -- sila priora Beta (wirtualne wystawienia modelu)
local ZQ_N = 16          -- liczba kwantyli rozkladu zmiany ceny
local EMP_MIN = 25       -- min. liczba historycznych zmian h-dobowych do uzycia kwantyli empirycznych

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

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

local function median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- kwantyl z posortowanej tablicy (interpolacja liniowa)
local function quantile(sorted, p)
    local n = #sorted
    if n == 0 then return nil end
    local pos = clamp(p, 0, 1) * (n - 1) + 1
    local lo = math.floor(pos)
    local hi = math.min(n, lo + 1)
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo)
end

-- odwrotna dystrybuanta rozkladu normalnego (Abramowitz-Stegun 26.2.23, blad < 5e-4)
local function normInv(p)
    if p <= 0 then return -8 elseif p >= 1 then return 8 elseif p == 0.5 then return 0 end
    local q = (p < 0.5) and p or (1 - p)
    local t = math.sqrt(-2 * math.log(q))
    local z = t - (2.515517 + 0.802853 * t + 0.010328 * t * t) /
        (1 + 1.432788 * t + 0.189269 * t * t + 0.001308 * t * t * t)
    return (p < 0.5) and -z or z
end
ns.NormInv = normInv

------------------------------------------------------------------
-- A) Model przeplywu: ujemny dwumian (Poisson gdy phi ~ 0)
------------------------------------------------------------------
-- P(N >= k) przyblizeniem normalnym o wariancji var (dla duzych mu / k)
local function normTail(k, mu, var)
    if k <= 0 then return 1 end
    if mu <= 0 then return 0 end
    local z = (k - 0.5 - mu) / math.sqrt(math.max(var, 1e-9))
    return 0.5 * (1 - math.tanh(0.7978845608 * (z + 0.044715 * z * z * z)))
end

-- oczekiwany odsetek partii "qty" sprzedany, gdy rynek sprzeda N sztuk (srednia mu, Var = mu + phi*mu^2),
-- a przed Toba stoi "ahead" sztuk = (1/qty) * suma_{j=1..qty} P(N >= ahead + j)
local function FracSold(mu, ahead, qty, phi)
    if not mu or mu <= 0 then return 0 end
    phi = math.max(0, phi or 0)
    ahead = math.max(0, math.floor((ahead or 0) + 0.5))
    qty = math.max(1, math.floor(qty or 1))
    local K = ahead + qty
    if mu > 300 or K > 400 then
        local var = mu * (1 + phi * mu)
        local n = math.min(qty, 100)
        local sum = 0
        for i = 1, n do
            sum = sum + normTail(ahead + math.ceil(i * qty / n), mu, var)
        end
        return clamp(sum / n, 0, 1)
    end
    local nb = phi >= 0.01
    local r, q, pmf
    if nb then
        r = 1 / phi
        q = mu / (r + mu)
        pmf = (r / (r + mu)) ^ r
    else
        pmf = math.exp(-mu)
    end
    local cdf = pmf                 -- P(N <= k-1) na poczatku iteracji k
    local sum = 0
    for k = 1, K do
        if k > ahead then sum = sum + (1 - cdf) end
        if nb then pmf = pmf * (k - 1 + r) / k * q else pmf = pmf * mu / k end
        cdf = cdf + pmf
    end
    return clamp(sum / qty, 0, 1)
end
ns.FracSold = FracSold

-- ile sztuk tanszych od "ref" stoi przed Toba wg drabiny z Huba (ns.live[itemID], swieza < 30 min); nil = brak danych
local function LadderAhead(s, ref)
    local live = ns.live
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local lv = live and id and live[id]
    if not (lv and lv.rows and lv.t and time() - lv.t < 1800 and ref) then return nil end
    local a = 0
    for _, m in ipairs(lv.rows) do
        if m.price < ref and not m.own then a = a + (m.qty or 0) end
    end
    return a
end

------------------------------------------------------------------
-- B) Kalibracja hierarchiczna (global -> kategoria)
------------------------------------------------------------------
local catMemo = {}
local function Category(s)
    local id = tonumber((s or ""):match("^i:(%d+)"))
    if not id then return "Inne" end
    local m = catMemo[id]
    if m then return m end
    local gi = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local cat = "Inne"
    if gi then
        local ok, _, t, st = pcall(gi, id)
        if ok and t and t ~= "" then
            cat = (st and st ~= "" and st ~= t) and (t .. ": " .. st) or t
            catMemo[id] = cat
        end
    end
    return cat
end

-- obciazenie modelu (w punktach procentowych p), shrinkage: kategoria -> poziom globalny -> 0
local function CalBias(s)
    local cal = ns.db and ns.db.riskCal
    if not (cal and cal.G) then return 0, 0, nil end
    local G = cal.G
    local gRaw = (G.n > 0) and ((G.sold - G.pred) / G.n) or 0
    local bG = G.n / (G.n + 25) * gRaw
    local bias = bG
    local cname = Category(s)
    local c = cal.cat[cname]
    if c and c.n > 0 then
        local cRaw = (c.sold - c.pred) / c.n
        bias = bG + c.n / (c.n + 15) * (cRaw - bG)
    end
    return clamp(bias, -0.3, 0.3), G.n, cname
end

local function Decay(c)
    if c.n > 400 then
        c.n, c.sold, c.pred = c.n / 2, c.sold / 2, c.pred / 2
    end
end

local ctxQty   -- ilosc wystawienia podczas zapisu prognozy (RecPost)

local function RecPost(s, qty)
    local db = ns.db
    if not (db and db.riskPend and db.riskCal and qty and qty > 0) then return end
    local d = ns.cache[s] or ns.FetchTSM(s)
    ctxQty = qty
    local ok, r = pcall(ns.RiskScore, s, d, ns.HistStats(s))
    ctxQty = nil
    if ok and r and r.p0raw then
        local list = db.riskPend[s]
        if not list then list = {}; db.riskPend[s] = list end
        list[#list + 1] = { t = time(), qty = qty, p0 = r.p0raw }
    end
end

local function RecSettle(s, qty, y)
    local db = ns.db
    local list = db and db.riskPend and db.riskPend[s]
    if not (list and db.riskCal) then return end
    local cal = db.riskCal
    local cname = Category(s)
    local c = cal.cat[cname]
    if not c then c = { n = 0, sold = 0, pred = 0 }; cal.cat[cname] = c end
    local rem = qty
    while rem > 0 and list[1] do
        local e = list[1]
        local take = math.min(e.qty, rem)
        for _, t in ipairs({ cal.G, c }) do
            t.n = t.n + take
            t.sold = t.sold + y * take
            t.pred = t.pred + e.p0 * take
        end
        local bi = math.min(5, math.floor(e.p0 * 5) + 1)
        local b = cal.bins[bi]
        if not b then b = { n = 0, sold = 0, pred = 0 }; cal.bins[bi] = b end
        b.n, b.sold, b.pred = b.n + take, b.sold + y * take, b.pred + e.p0 * take
        e.qty = e.qty - take
        rem = rem - take
        if e.qty <= 0 then table.remove(list, 1) end
    end
    if #list == 0 then db.riskPend[s] = nil end
    Decay(cal.G)
    Decay(c)
end

-- podpiecie pod dziennik (Learn.lua juz opakowal te funkcje; opakowujemy dalej)
local origPost, origSell, origExpire = ns.Post, ns.Sell, ns.Expire

function ns.Post(s, qty, price)
    origPost(s, qty, price)
    ns.Safe("riskcal", RecPost, s, qty)
end

function ns.Sell(s, qty, price, noConsume)
    local ok, res = origSell(s, qty, price, noConsume)
    if ok then ns.Safe("riskcal", RecSettle, s, qty, 1) end
    return ok, res
end

function ns.Expire(s, qty, deposit, noConsume)
    local r = origExpire(s, qty, deposit, noConsume)
    ns.Safe("riskcal", RecSettle, s, qty, 0)
    return r
end

local function InitDB()
    local db = ns.db
    if type(db.riskCal) ~= "table" then db.riskCal = {} end
    local cal = db.riskCal
    if type(cal.G) ~= "table" then cal.G = { n = 0, sold = 0, pred = 0 } end
    if type(cal.cat) ~= "table" then cal.cat = {} end
    if type(cal.bins) ~= "table" then cal.bins = {} end
    if type(db.riskPend) ~= "table" then db.riskPend = {} end
    local now = time()
    for s, list in pairs(db.riskPend) do          -- wystawienia starsze niz 4 dni nie moga byc aktywne
        local keep = {}
        for _, e in ipairs(list) do
            if now - e.t < 4 * 86400 then keep[#keep + 1] = e end
        end
        db.riskPend[s] = (#keep > 0) and keep or nil
    end
end

------------------------------------------------------------------
-- C) Model ceny: seria dobowa, EWMA, AR(1), kwantyle empiryczne
------------------------------------------------------------------
local serCache = {}
local function Series(s)
    local db = ns.db
    local rec = db.items[s]
    local h = rec and rec.hist or {}
    local last = h[#h]
    local key = #h .. ":" .. (last and last[1] or 0) .. ":" .. (ns.arcDay or 0)
    local c = serCache[s]
    if c and c.key == key and time() - c.t < 600 then return c end

    local id = tonumber((s or ""):match("^i:(%d+)"))
    local byDay = {}
    if id and db.arc and ns.ArchivePoints then
        for _, p in ipairs(ns.ArchivePoints(id) or {}) do
            if p[2] and p[2] > 0 then byDay[math.floor(p[1] / 86400)] = p[2] end
        end
    end
    for _, p in ipairs(h) do                 -- chronologicznie: ostatni punkt doby wygrywa (nadpisuje archiwum)
        local v = p[2]
        if v and v > 0 then byDay[math.floor(p[1] / 86400)] = v end
    end
    local days = {}
    for dd in pairs(byDay) do days[#days + 1] = dd end
    table.sort(days)

    -- log-zwroty dobowe (przerwy do 3 dni normalizowane sqrt(przerwy))
    local rets = {}
    for i = 2, #days do
        local gap = days[i] - days[i - 1]
        if gap >= 1 and gap <= 3 then
            rets[#rets + 1] = math.log(byDay[days[i]] / byDay[days[i - 1]]) / math.sqrt(gap)
        end
    end
    local out = { key = key, t = time(), byDay = byDay, days = days, nRet = #rets }

    if #rets >= 6 then
        local m = median(rets)
        local dev = {}
        for i, v in ipairs(rets) do dev[i] = math.abs(v - m) end
        out.sigMAD = 1.4826 * median(dev)
        if #rets >= 10 then
            -- EWMA na przycietych zwrotach (odporne na pojedyncze skoki DBMinBuyout)
            local clip = (out.sigMAD > 0) and (4 * out.sigMAD) or math.huge
            local cl = {}
            for i, v in ipairs(rets) do cl[i] = clamp(v, -clip, clip) end
            local v0, n0 = 0, math.min(10, #cl)
            for i = 1, n0 do v0 = v0 + cl[i] * cl[i] end
            local var = v0 / n0
            for i = 1, #cl do var = 0.94 * var + 0.06 * cl[i] * cl[i] end
            out.sigEW = math.sqrt(var)
        end
    end

    -- AR(1) na poziomach (log) z kolejnych dob: phi (powrot do sredniej)
    local ys = {}
    for _, dd in ipairs(days) do ys[#ys + 1] = math.log(byDay[dd]) end
    if #ys >= 16 then
        local mu = median(ys)
        local num, den, pairsN = 0, 0, 0
        for i = 2, #days do
            if days[i] - days[i - 1] == 1 then
                local a, b = ys[i - 1] - mu, ys[i] - mu
                num, den, pairsN = num + a * b, den + a * a, pairsN + 1
            end
        end
        if pairsN >= 15 and den > 0 then out.phi = clamp(num / den, 0.05, 0.995) end
    end
    serCache[s] = out
    return out
end

-- zwraca { sigmaH, sigDay, phi, nRet, nH, method, zq, floored, measured }
-- zq = ZQ_N kwantyli zmiany log-ceny w horyzoncie h dni, wycentrowane tak, by E[exp(z)] = 1
local pmCache = {}
local function PriceModel(s, hDays, floorDay, fallbackSig, zs)
    zs = zs or 1
    local ser = Series(s)
    local h = math.max(1, math.floor(clamp(hDays, 1, 14) + 0.5))
    local ck = s .. ":" .. h .. ":" .. floorDay .. ":" .. tostring(fallbackSig) .. ":" .. zs
    local c = pmCache[ck]
    if c and c.key == ser.key and c.t == ser.t then return c.v end

    local sigDay = ser.sigEW or ser.sigMAD
    local fromLevel = false
    if not sigDay and fallbackSig then sigDay, fromLevel = fallbackSig, true end
    local phi = ser.phi
    local vf = h
    if phi and phi < 0.999 then vf = (1 - phi ^ h) / (1 - phi) end
    local sigModel = sigDay and (sigDay * math.sqrt(vf)) or nil
    local floorH = floorDay * math.sqrt(h)

    -- zmiany h-dobowe z historii (okna nakladajace sie)
    local emp = {}
    for _, dd in ipairs(ser.days) do
        local v2 = ser.byDay[dd + h]
        if v2 then emp[#emp + 1] = math.log(v2 / ser.byDay[dd]) end
    end
    table.sort(emp)

    local v = { sigDay = sigDay, phi = phi, nRet = ser.nRet, nH = #emp, measured = sigDay ~= nil,
        fromLevel = fromLevel, h = h }
    local zq = {}
    local sigEmp
    if #emp >= EMP_MIN then
        sigEmp = (quantile(emp, 0.8413) - quantile(emp, 0.1587)) / 2
    end
    if sigEmp and sigEmp >= floorH then
        local med = quantile(emp, 0.5)
        for i = 1, ZQ_N do zq[i] = quantile(emp, (i - 0.5) / ZQ_N) - med end
        v.sigmaH, v.method = sigEmp, string.format("kwantyle empiryczne (n=%d)", #emp)
    else
        local sig = math.max(sigModel or 0, floorH)
        for i = 1, ZQ_N do zq[i] = sig * normInv((i - 0.5) / ZQ_N) end
        v.sigmaH = sig
        v.floored = (sigModel == nil) or (sigModel < floorH)
        v.method = phi and string.format("normalny + powrot do sredniej (phi=%.2f)", phi) or "normalny"
    end
    if zs ~= 1 then                          -- skala z backtestu (pokrycie kwantyli)
        for i = 1, ZQ_N do zq[i] = zq[i] * zs end
        v.sigmaH = v.sigmaH * zs
        v.method = v.method .. string.format(", skala x%.2f", zs)
    end
    local sm = 0
    for i = 1, ZQ_N do sm = sm + math.exp(zq[i]) end
    local shift = math.log(sm / ZQ_N)
    for i = 1, ZQ_N do zq[i] = zq[i] - shift end
    v.zq = zq
    pmCache[ck] = { key = ser.key, t = ser.t, v = v }
    return v
end

------------------------------------------------------------------
-- Glowna ocena
------------------------------------------------------------------
local function Compute(s, d, hs, r)
    local db = ns.db
    local pts, why, info = 0, {}, {}
    local function add(n, txt)
        if n >= 0.5 then
            pts = pts + n
            why[#why + 1] = txt
        end
    end

    -- dane o historii
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
    if hs and hs.spanDays then info.span = hs.spanDays end

    -- ilosc w zapasie / otwartych wystawieniach
    local lot = db.lots[s]
    local held = lot and lot.qty
    if not held or held <= 0 then
        local op = db.openPosts[s]
        if op then
            held = 0
            for _, p in ipairs(op) do held = held + p.qty end
        end
    end
    held = (held and held > 0) and held or nil
    local qEff = ctxQty or held or 1

    ---------------- A) P(sprzedaz): model przeplywu ----------------
    local share = clamp(db.riskShare or 0.5, 0.05, 1)
    local bz = _G.TsmAnalizeBlizz
    local bzOk = type(bz) == "table"
    local be = (bzOk and type(bz.items) == "table") and bz.items[s] or nil
    local fresh = bzOk and bz.generated and (time() - bz.generated) < 8 * 3600
    local perDay, flowSrc, measured = nil, "TSM", false
    if be and fresh and be.fl and (be.fk or 0) >= 2 then
        perDay, flowSrc, measured = be.fl, string.format("Blizz, %.0f d", be.fk), true
    elseif d.perDay then
        perDay = d.perDay / (db.perDayDiv or 1)
    end
    local phiD, dispSrc = clamp(db.riskDisp or 0.5, 0, 3), "ustawienie"
    if be and fresh and be.fd and (be.fk or 0) >= 5 then
        phiD, dispSrc = clamp(be.fd, 0, 3), "pomiar Blizz"
    elseif bzOk and type(bz.calib) == "table" and tonumber(bz.calib.disp) then
        phiD, dispSrc = clamp(tonumber(bz.calib.disp), 0, 3), "backtest"
    end
    local ref = d.market or d.recent or d.regionSale or d.minbuy
    local winDays = clamp((db.riskHours or 48) / 24, 1 / 12, 2)
    local ahead = ref and LadderAhead(s, ref) or nil
    local rate = (perDay and (perDay > 0 or measured)) and math.max(perDay * (ahead and 1 or share), 1e-6) or nil

    local p0, p0raw, src
    local tSell = 2
    if rate then
        p0raw = clamp(FracSold(rate * winDays, ahead or 0, qEff, phiD), 0.02, 0.98)
        local bias, nCal, cname = CalBias(s)
        p0 = clamp(p0raw + bias, 0.02, 0.98)
        src = ahead and "model przeplywu + drabina AH" or "model przeplywu"
        if nCal > 0 then src = src .. string.format(" (kalibracja %+.0f pp)", bias * 100) end
        info.bias, info.nCal, info.cat = bias, nCal, cname
        tSell = clamp(((ahead or 0) + qEff) / rate, 0.02, 30)
        info.maxSell = math.max(1, math.floor(rate * winDays - (ahead or 0)))
    else
        p0, src = 0.4, "szac."
    end
    info.perDay, info.share, info.qty, info.ahead = perDay, ahead and 1 or share, held, ahead
    info.tSell, info.winDays, info.disp = tSell, winDays, phiD
    info.flowSrc, info.dispSrc = flowSrc, dispSrc
    if held and rate then info.days = tSell end

    ---------------- B) dane wlasne jako Beta-prior ----------------
    local p, nEff = p0, PRIOR_K
    local pOwn, nOwn
    if ns.OwnSellProb then
        local po, n = ns.OwnSellProb(s)       -- (sold+1)/(n+2), n
        if po and n and n >= 3 then
            local sold = po * (n + 2) - 1
            p = (sold + PRIOR_K * p0) / (n + PRIOR_K)
            nEff = n + PRIOR_K
            pOwn, nOwn = true, n
            src = "wlasne dane + " .. src
        end
    end
    r.pHeur = p
    if r.pML and db.ml then                  -- Learn.lua ustawia r.pML tylko gdy model aktywny i gotowy
        local a = math.min(0.8, (db.ml.n or 0) / 200)
        p = (1 - a) * p + a * r.pML
        nEff = nEff + a * math.min(150, (db.ml.nW or 0) * 0.5)
        src = src .. " + ML"
    end
    p = clamp(p, 0.05, 0.95)

    if not rate and not pOwn then
        add(30, "brak danych o sprzedazy")
    else
        add(40 * clamp((0.9 - p) / 0.65, 0, 1), string.format("niska szansa sprzedazy (%.0f%%)", p * 100))
    end
    if d.saleRate and d.saleRate < (db.minSaleRate or 0) then add(8, "wolna sprzedaz (sale rate)") end

    ---------------- C) ryzyko ceny ----------------
    local trust = ns.EconomyTrust()
    local floorDay = (trust < 1) and 0.05 or 0.02
    local hDays = clamp(tSell, 1, 14)
    local fallback = (hs and hs.n >= 8 and hs.stdevPct) and (hs.stdevPct / 100 * 0.45) or nil
    local zs = (bzOk and type(bz.calib) == "table" and tonumber(bz.calib.zs)) or 1
    zs = clamp(zs, 0.7, 2)
    local pm = PriceModel(s, hDays, floorDay, fallback, zs)
    info.zs = zs
    info.sigmaDay, info.nRet, info.hDays, info.phi = pm.sigDay, pm.nRet, pm.h, pm.phi
    info.priceMethod, info.nH, info.zq = pm.method, pm.nH, pm.zq
    info.sEff = pm.sigmaH * 100
    info.sigma = (not pm.floored) and (pm.sigmaH * 100) or nil

    local buy = db.buyPrice[s] or d.minbuy
    if ref and buy and ref > 0 then
        local keep = 1 - ns.Cut() / 100
        local be = buy / keep
        local buf = (ref - be) / ref                    -- ulamek
        info.buffer = buf * 100
        info.bufferSigma = buf / pm.sigmaH
        if pm.measured or pm.nH >= EMP_MIN then
            add(35 * clamp((2.5 - info.bufferSigma) / 2.5, 0, 1),
                string.format("maly bufor spadku (%.1fx zmiennosci)", info.bufferSigma))
        end
    end

    -- trend: wchodzi tylko tutaj
    if hs and hs.n >= 8 and hs.trend then
        add(15 * clamp((-hs.trend - 1) / 3, 0, 1), "cena spada")
    end

    if d.minbuy and d.market then
        if d.minbuy > d.market * 1.25 then add(10, "cena nad rynkiem")
        elseif d.minbuy < d.market * 0.5 then add(10, "cena podejrzanie niska") end
    end
    if trust < 1 then add((1 - trust) * 20, "mlody rynek") end

    ---------------- jakosc danych ----------------
    local n8 = (hs and hs.n) or 0
    if n8 < 8 then add(15 * (1 - n8 / 8), "malo wlasnych danych") end
    if hs and hs.spanDays and hs.spanDays < 5 then
        add(14 * (1 - hs.spanDays / 5), "krotka historia (< 5 dni)")
    end
    if nPts >= 8 and nUniq <= 3 then
        info.stale = true
        add(8, "malo roznych wartosci w historii (plaski rynek albo nieswieze dane)")
    end

    ---------------- wynik ----------------
    local score = math.min(100, math.floor(pts + 0.5))
    r.score, r.level, r.why = score, Level(score), why
    r.p, r.pOwn, r.nOwn = p, pOwn, nOwn
    r.p0, r.p0raw = p0, p0raw
    r.pLo, r.pHi = wilson(clamp(p, 0.01, 0.99), math.max(nEff, 1))
    r.pN, r.pSrc = nEff, src
    r.tSell = tSell
    r.extra, r.extraPts = info, score
end

local origRisk = ns.RiskScore
function ns.RiskScore(s, d, hs)
    local r = origRisk(s, d, hs)         -- Core + Learn (daje m.in. r.pML); punktacje nizej nadpisujemy
    local db = ns.db
    if not db then return r end
    if db.riskExt ~= false then
        local ok, err = pcall(Compute, s, d, hs, r)
        if not ok then ns.Safe("risk", error, err, 0) end
    end
    if not r.pLo then                    -- tryb zapasowy (riskExt OFF albo blad)
        local n, src
        if r.pOwn then n, src = math.max(r.nOwn or 10, 10), "wlasne dane"
        elseif r.pML then n, src = 8 + math.min(150, ((db.ml and db.ml.nW) or 0) * 0.5), "model ML"
        else n, src = 8, "szac." end
        r.pLo, r.pHi = wilson(clamp(r.p, 0.01, 0.99), n)
        r.pN, r.pSrc = n, src
    end
    return r
end

-- limit ilosci wg tempa sprzedazy
local origAnalyze = ns.Analyze
function ns.Analyze(s, d, buy)
    local r = origAnalyze(s, d, buy)
    local x = r.risk and r.risk.extra
    if x and x.maxSell and r.maxUnits then
        r.maxUnits = math.min(r.maxUnits, x.maxSell)
    end
    return r
end

------------------------------------------------------------------
-- Linie opisu ryzyka i komendy
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
        if x.buffer and x.bufferSigma then
            local col = (x.bufferSigma < 1 and "|cffff4040") or (x.bufferSigma < 2 and "|cffffcc33") or "|cff33dd66"
            local note = x.sigma and "" or " (przyjeta podloga)"
            lines[#lines + 1] = string.format("Bufor spadku: %s%.0f%% = %.1fx zmiennosci %.0f%% (horyzont %.0f d)|r%s",
                col, x.buffer, x.bufferSigma, x.sEff, x.hDays or 0, gray(note))
        end
        if x.priceMethod then lines[#lines + 1] = gray("Model ceny: " .. x.priceMethod) end
        if x.perDay then
            local t = string.format("Rynek ~%.1f szt./dzien (%s, dysp. %.2f - %s); okno %.0fh", x.perDay, x.flowSrc or "TSM",
                x.disp or 0, x.dispSrc or "?", (x.winDays or 2) * 24)
            if x.ahead then t = t .. string.format("; przed Toba %d szt.", x.ahead) end
            if x.maxSell then t = t .. string.format("; Twoje ~%d szt.", x.maxSell) end
            if x.days and x.qty then
                local col = (x.days > 4 and "|cffff4040") or (x.days > 2 and "|cffffcc33") or "|cff33dd66"
                t = t .. string.format("; %d szt. = %s~%.1f dnia|r", x.qty, col, x.days)
            end
            lines[#lines + 1] = t
        else
            lines[#lines + 1] = gray("Tempo sprzedazy: brak danych z TSM (nie da sie oszacowac czasu sprzedazy)")
        end
        local dline = string.format("Dane: %d roznych wartosci w %d pomiarach", x.nUniq, x.nPts)
        if x.span then dline = dline .. string.format(", historia %.1f dnia", x.span) end
        if x.nRet then dline = dline .. string.format(", %d zwrotow dobowych", x.nRet) end
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
    ns.Print(string.format("Ryzyko %s: %d pkt (%s)", ns.ItemName(s), r.risk.score, r.risk.level))
    for _, w in ipairs(r.risk.why) do ns.Print("  - " .. w) end
    for _, l in ipairs(BlockLines(r) or {}) do ns.Print("  " .. Plain(l)) end
    local pf = r.profit
    if pf and pf.cvar then
        ns.Print(string.format("  Rozklad zysku/szt.: oczek. %s, P(strata) %.0f%%, kwantyl 5%% %s, CVaR95 %s (%+.0f%%)",
            ns.MoneyPlain(pf.net), pf.pLoss * 100, ns.MoneyPlain(pf.worst), ns.MoneyPlain(pf.cvar), pf.cvarPct))
    end
end

local function CalCommand()
    local cal = ns.db.riskCal
    if not (cal and cal.G) then ns.Print("Brak danych kalibracji."); return end
    local G = cal.G
    if G.n <= 0 then
        ns.Print("Kalibracja: brak rozliczonych sztuk (wystaw i rozlicz kilka aukcji, zeby model sie uczyl).")
        return
    end
    ns.Print(string.format("Kalibracja p (model przeplywu vs Twoja rzeczywistosc): %.0f szt., sprzedane %.0f%%, prognoza %.0f%%",
        G.n, G.sold / G.n * 100, G.pred / G.n * 100))
    local names = {}
    for k in pairs(cal.cat) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        local c = cal.cat[k]
        if c.n > 0 then
            ns.Print(string.format("  %s: %.0f szt., sprzedane %.0f%%, prognoza %.0f%%", k, c.n, c.sold / c.n * 100, c.pred / c.n * 100))
        end
    end
    ns.Print("Krzywa niezawodnosci (prognoza -> faktycznie sprzedane):")
    for i = 1, 5 do
        local b = cal.bins[i]
        if b and b.n > 0 then
            ns.Print(string.format("  p w [%.1f, %.1f): %.0f szt., prognoza %.0f%%, faktycznie %.0f%%",
                (i - 1) / 5, i / 5, b.n, b.pred / b.n * 100, b.sold / b.n * 100))
        end
    end
end

------------------------------------------------------------------
-- Ustawienia, komenda, start
------------------------------------------------------------------
table.insert(ns.FIELDS, { key = "riskShare", label = "Udzial w sprzedazy rynku bez drabiny AH (0-1)", kind = "num", min = 0.05, max = 1 })
table.insert(ns.FIELDS, { key = "riskHours", label = "Okno sprzedazy dla p (godziny, 2-48)", kind = "num", min = 2, max = 48 })
table.insert(ns.FIELDS, { key = "riskDisp", label = "Dyspersja sprzedazy (0 = Poisson, 0.5 typowo)", kind = "num", min = 0, max = 3 })
table.insert(ns.TOGGLES, { key = "riskExt", label = "Ocena ryzyka v3 (przeplyw NB, kalibracja, kwantyle ceny)" })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    if (cmd or ""):lower() == "risk" and ns.db then
        if (rest or ""):lower() == "cal" then CalCommand() else RiskCommand() end
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
    ns.Safe("riskcal", InitDB)
    if ns.UpdateUI then ns.UpdateUI() end
end)
