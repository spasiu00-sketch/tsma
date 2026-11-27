local ADDON, ns = ...

------------------------------------------------------------------
-- PROGNOZA UCZONA W ADDONIE (bez silnika): regresja kwantylowa online (SGD, pinball loss), cel: zmiana log(min) za 24 h
--  cechy: zwrot 6 h i 24 h, odchylenie od sredniej 7 d, zmiennosc 24 h, spread mediana/min, godzina (sin/cos),
--         zwrot calego rynku (srednia sledzonych przedmiotow) i zwrot tej samej kategorii (bez samego przedmiotu)
--  dane:  wlasna historia db.items[s].hist; przy starcie model uczy sie z calej dostepnej historii (probki co 3 h),
--         potem dociaga nowe probki przy kazdym odswiezeniu. Kazda probka jest najpierw OCENIANA (prequential), potem uczy.
--  straznik: prognoza jest uzywana tylko gdy po >= 100 ocenach bije stale kwantyle (skill >= 2%) i pokrycie p10 / p90 miesci sie w 5-17%.
--  wynik: ns.OnlineFc(s) -> { f24 = {p10, p50, p90} w %, src = "addon" }; ns.FcFor sięga po nia, gdy silnik nie dal prognozy.
-- Wczytaj PO Forecast.lua i PRZED Weekly.lua. Komenda: /tsma online [reset]
------------------------------------------------------------------

local DEFAULTS = { onlOn = true }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local QS = { 0.1, 0.5, 0.9 }
local NF = 9
local SC = { 0.06, 0.10, 0.10, 1, 0.10, 1, 1, 0.03, 0.03 }   -- r6, r24, dev, vol, spread, sin, cos, mk6, ck6
local LRW, LRB, L2 = 0.0005, 0.001, 1e-5
local WARM, MIN_EVAL, GAP = 300, 100, 8000
local DAY, SAMPLE_STEP = 86400, 3 * 3600

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

local function O() return ns.db and ns.db.onl end

local function Fresh()
    local o = { nf = NF, w = {}, b = { 0, 0, 0 }, bb = { 0, 0, 0 }, bt = {}, n = 0, ne = 0, Lm = 0, Lb = 0, lo = 0, hi = 0 }
    for k = 1, 3 do
        o.w[k] = {}
        for i = 1, NF do o.w[k][i] = 0 end
    end
    return o
end

local function InitDB()
    local db = ns.db
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.onl) ~= "table" or db.onl.nf ~= NF then db.onl = Fresh() end
end

------------------------------------------------------------------
-- Model
------------------------------------------------------------------
local function Raw(o, k, x)
    local z, w = o.b[k], o.w[k]
    for i = 1, NF do z = z + w[i] * x[i] end
    return z
end

local function Pred(o, x)
    local p = { Raw(o, 1, x), Raw(o, 2, x), Raw(o, 3, x) }
    table.sort(p)
    return p
end

local function Pin(y, p)
    local s = 0
    for k = 1, 3 do
        local e = y - p[k]
        s = s + math.max(QS[k] * e, (QS[k] - 1) * e)
    end
    return s / 3
end

local function Train(x, y)
    local o = O()
    y = clamp(y, -0.5, 0.5)
    local p = Pred(o, x)
    o.n = o.n + 1
    if o.n > WARM then
        o.Lm, o.Lb, o.ne = o.Lm + Pin(y, p), o.Lb + Pin(y, o.bb), o.ne + 1
        if y < p[1] then o.lo = o.lo + 1 end
        if y > p[3] then o.hi = o.hi + 1 end
        if o.ne > 5000 then
            o.Lm, o.Lb, o.ne, o.lo, o.hi = o.Lm / 2, o.Lb / 2, o.ne / 2, o.lo / 2, o.hi / 2
        end
    end
    for k = 1, 3 do
        local g = (y < Raw(o, k, x)) and (1 - QS[k]) or -QS[k]
        o.b[k] = o.b[k] - LRB * g
        local w = o.w[k]
        for i = 1, NF do w[i] = w[i] - LRW * (g * x[i] + L2 * w[i]) end
        local gb = (y < o.bb[k]) and (1 - QS[k]) or -QS[k]
        o.bb[k] = o.bb[k] - LRB * gb
    end
end

-- -> trusted, skill, cov_lo, cov_hi, ne
function ns.OnlineStats()
    local o = O()
    if not o or o.ne < 1 or o.Lb <= 0 then return false, nil, nil, nil, o and o.ne or 0 end
    local skill, lo, hi = 1 - o.Lm / o.Lb, o.lo / o.ne, o.hi / o.ne
    local ok = o.ne >= MIN_EVAL and skill >= 0.02 and lo >= 0.05 and lo <= 0.17 and hi >= 0.05 and hi <= 0.17
    return ok, skill, lo, hi, o.ne
end

------------------------------------------------------------------
-- Cechy z historii
------------------------------------------------------------------
local function idxAt(h, t)
    local lo, hi = 1, #h
    if hi == 0 or h[1][1] > t then return nil end
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if h[mid][1] <= t then lo = mid else hi = mid - 1 end
    end
    if t - h[lo][1] > GAP then return nil end
    return lo
end

local function logAt(h, t)
    local j = idxAt(h, t)
    local m = j and h[j][2]
    if m and m > 0 then return math.log(m), j end
end

local catMemo = {}
local function Cat(s)
    local c = catMemo[s]
    if c then return c end
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local gi = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    c = "Inne"
    if id and gi then
        local ok, _, t, st = pcall(gi, id)
        if ok and t and t ~= "" then
            c = (st and st ~= "" and st ~= t) and (t .. ": " .. st) or t
            catMemo[s] = c
        end
    end
    return c
end

local function MakeItem(s)
    local rec = ns.db.items[s]
    local h = rec and rec.hist
    if h and #h >= 60 then return { s = s, h = h, cat = Cat(s) } end
end

-- zwrot 6 h w kazdym punkcie historii (do wskaznika rynku / kategorii)
local function BuildR6(it)
    local r, h = {}, it.h
    for j = 1, #h do
        local v = h[j][2]
        local a = v and v > 0 and logAt(h, h[j][1] - 6 * 3600)
        r[j] = a and (math.log(v) - a) or false
    end
    it.R6 = r
end

local function Market(ctx, it, t)
    local sa, na, sc, nc = 0, 0, 0, 0
    for _, o in ipairs(ctx) do
        if o ~= it and o.R6 then
            local j = idxAt(o.h, t)
            local r = j and o.R6[j]
            if r then
                sa, na = sa + r, na + 1
                if o.cat == it.cat then sc, nc = sc + r, nc + 1 end
            end
        end
    end
    return na >= 3 and sa / na or 0, nc >= 2 and sc / nc or 0
end

local function Feat(it, i, ctx)
    local h = it.h
    local p = h[i]
    local t, m = p[1], p[2]
    if not (m and m > 0) then return end
    local lm = math.log(m)
    local a6, a24 = logAt(h, t - 6 * 3600), logAt(h, t - DAY)
    if not (a6 and a24) then return end
    local sum, n, sq, nr, prevV, prevT = 0, 0, 0, 0, nil, nil
    local j = i
    while j >= 1 and h[j][1] >= t - 7 * DAY do
        local v = h[j][2]
        if v and v > 0 then
            local lv = math.log(v)
            sum, n = sum + lv, n + 1
            if h[j][1] >= t - DAY and prevV then
                local dtu = math.max(1, (prevT - h[j][1]) / 1800)
                local r = prevV - lv
                sq, nr = sq + r * r / dtu, nr + 1
            end
            prevV, prevT = lv, h[j][1]
        end
        j = j - 1
    end
    if n < 40 or nr < 8 then return end
    local spread = (p[3] and p[3] > 0) and clamp(math.log(p[3] / m), -0.5, 0.5) or 0
    local hr = (t / 3600) % 24
    local mk, ck = 0, 0
    if ctx then mk, ck = Market(ctx, it, t) end
    local raw = { lm - a6, lm - a24, lm - sum / n, math.sqrt(sq / nr), spread, math.sin(2 * math.pi * hr / 24),
        math.cos(2 * math.pi * hr / 24), mk, ck }
    local x = {}
    for k = 1, NF do x[k] = clamp(raw[k] / SC[k], -4, 4) end
    return x, lm
end

------------------------------------------------------------------
-- Uczenie z historii (probki co 3 h, tylko nowe od ostatniego razu)
------------------------------------------------------------------
local function Items(list)
    local out = {}
    for _, s in ipairs(list) do
        local it = MakeItem(s)
        if it then out[#out + 1] = it end
    end
    for _, it in ipairs(out) do BuildR6(it) end
    return out
end

local function TrainItem(it, ctx)
    local o = O()
    local h = it.h
    local last = h[#h][1]
    local start = o.bt[it.s] or 0
    local lastS, cnt = start, 0
    for i = 1, #h do
        local t = h[i][1]
        if t > start and t - lastS >= SAMPLE_STEP and t + DAY <= last then
            local x, lm = Feat(it, i, ctx)
            local k = x and idxAt(h, t + DAY)
            if x and k and h[k][2] and h[k][2] > 0 then
                Train(x, math.log(h[k][2]) - lm)
                cnt = cnt + 1
            end
            lastS = t
            o.bt[it.s] = t
        end
    end
    return cnt
end

local running = false
function ns.OnlineTrain(list, sync)
    local db = ns.db
    if not (db and db.onlOn and O()) or running then return 0 end
    local ctx = Items(list or ns.RefreshList())
    local total, i = 0, 1
    local function step()
        if i > #ctx then running = false; return end
        total = total + (ns.Safe("online", function() TrainItem(ctx[i], ctx) end) and 0 or 0)
        i = i + 1
        if sync then step() else C_Timer.After(0, step) end
    end
    running = true
    step()
    return #ctx
end

------------------------------------------------------------------
-- Predykcja na zywo
------------------------------------------------------------------
local liveCtx, liveT
local function LiveCtx()
    if liveCtx and liveT and time() - liveT < 120 then return liveCtx end
    liveCtx, liveT = Items(ns.RefreshList()), time()
    return liveCtx
end

function ns.OnlineFc(s)
    local db = ns.db
    if not (db and db.onlOn and O()) then return nil end
    local ok = ns.OnlineStats()
    if not ok then return nil end
    local ctx = LiveCtx()
    local it
    for _, c in ipairs(ctx) do if c.s == s then it = c; break end end
    it = it or MakeItem(s)
    if not it then return nil end
    local i = #it.h
    if time() - it.h[i][1] > 5400 then return nil end
    local x = Feat(it, i, ctx)
    if not x then return nil end
    local P = Pred(O(), x)
    local function pc(z) return math.floor((math.exp(clamp(z, -3, 3)) - 1) * 1000 + 0.5) / 10 end
    return { f24 = { pc(P[1]), pc(P[2]), pc(P[3]) }, src = "addon", age = 0 }
end

local engineFc = ns.FcFor
function ns.FcFor(s)
    local f = engineFc and engineFc(s)
    if f and f.f24 then return f end
    local on = ns.OnlineFc(s)
    if on then
        if f then f.f24, f.src = on.f24, "addon"; return f end
        return on
    end
    return f
end

------------------------------------------------------------------
-- Komenda, ustawienia, start
------------------------------------------------------------------
local function Command(rest)
    local db = ns.db
    local v = (rest or ""):lower()
    if v == "reset" then db.onl = Fresh(); ns.Print("Model online wyzerowany."); return end
    if v == "on" or v == "off" then db.onlOn = (v == "on") end
    local o = O()
    local ok, skill, lo, hi, ne = ns.OnlineStats()
    ns.Print(string.format("Model online: probek %d, ocenionych %d, przewaga nad stalymi kwantylami %s, poza p10 %s, powyzej p90 %s -> %s",
        o.n, ne, skill and string.format("%+.1f%%", skill * 100) or "n/d", lo and string.format("%.0f%%", lo * 100) or "n/d",
        hi and string.format("%.0f%%", hi * 100) or "n/d", ok and "|cff33dd66UZYWANY|r" or "|cff9aa0a6uczy sie / brak przewagi|r"))
    local names = { "zwrot 6h", "zwrot 24h", "odchylenie 7d", "zmiennosc", "spread", "sin", "cos", "rynek", "kategoria" }
    local parts = {}
    for i = 1, NF do parts[#parts + 1] = string.format("%s %+.3f", names[i], o.w[2][i]) end
    ns.Print("  wagi mediany: " .. table.concat(parts, ", "))
    local s = db.selected
    local f = s and ns.OnlineFc(s)
    if f then ns.Print(string.format("  %s +24h: %+.1f%% (p10 %+.1f%%, p90 %+.1f%%)", ns.ItemName(s), f.f24[2], f.f24[1], f.f24[3])) end
end

table.insert(ns.TOGGLES, { key = "onlOn", label = "Prognoza uczona w addonie (regresja kwantylowa online)" })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    if (cmd or ""):lower() == "online" and ns.db and ns.db.onl then
        Command(rest)
    elseif origSlash then
        origSlash(msg)
    end
end

hooksecurefunc(ns, "RefreshAll", function()
    ns.Safe("online", ns.OnlineTrain)
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.Safe("online", InitDB)
end)
