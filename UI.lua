local ADDON, ns = ...

local WIDTH, HEIGHT = 420, 660
local CONTENT_W, STAT_ROWS, STAT_H = 388, 12, 18

local GRAY, GREEN, YELLOW, RED, BLUE, WHITE, ORANGE =
    "|cff9aa0a6", "|cff33dd66", "|cffffcc33", "|cffff4040", "|cff33aaff", "|cffffffff", "|cffffa040"

------------------------------------------------------------------
-- Wspolne helpery (uzywane tez w Panels.lua)
------------------------------------------------------------------
-- tryb dla daltonistow: zielony -> niebieski, czerwony -> pomaranczowy (w tekstach); kolory wykresow i plakietek osobno
local CB_MAP = { ["|cff33dd66"] = "|cff4da6ff", ["|cff33e666"] = "|cff4da6ff", ["|cffff4040"] = "|cffff8c1a" }
function ns.Recolor(t)
    if type(t) ~= "string" or not (ns.db and ns.db.colorblind) then return t end
    return (t:gsub("|cff%x%x%x%x%x%x", function(c) return CB_MAP[c] end))
end

local function MakeFS(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, size, "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(0.92, 0.92, 0.92)
    local rawSetText = fs.SetText
    fs.SetText = function(self, t) return rawSetText(self, ns.Recolor(t)) end
    return fs
end
ns.MakeFS = MakeFS

function ns.MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

function ns.MakeInput(parent, w)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 22)
    e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

function ns.DarkBackdrop(frame, a)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.06, 0.07, 0.09, a or 0.93)
    frame:SetBackdropBorderColor(0.25, 0.27, 0.32, 1)
end

local function AgeLabel(sec)
    if sec >= 86400 then return string.format("-%.1fd", sec / 86400) end
    return string.format("-%dh", math.max(1, math.floor(sec / 3600)))
end

-- kwota skrocona do karty: od 100g bez miedzi, od 1000g tylko zlote
local function commas(n)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function MoneyShort(c)
    if c == nil then return "|cff888888--|r" end
    local neg = c < 0
    local a = math.floor(math.abs(c) + 0.5)
    local g = math.floor(a / 10000)
    if g < 100 then return ns.Money(c) end
    local s = math.floor((a % 10000) / 100)
    local out
    if g >= 1000 then
        out = "|cffffd700" .. commas(g) .. "g|r"
    else
        out = "|cffffd700" .. g .. "g|r |cffc7c7cf" .. s .. "s|r"
    end
    return (neg and "|cffff4040-|r" or "") .. out
end

local function PctStr(p)
    if p == nil then return "" end
    return string.format("%s%+.1f%%|r", p >= 0 and GREEN or RED, p)
end

------------------------------------------------------------------
-- Wykres
------------------------------------------------------------------
local function GetLine(chart, i)
    chart.pool = chart.pool or {}
    local l = chart.pool[i]
    if not l then
        l = chart:CreateLine(nil, "ARTWORK")
        chart.pool[i] = l
    end
    l:Show()
    return l
end

local function GetLabel(chart, i)
    chart.labels = chart.labels or {}
    local fs = chart.labels[i]
    if not fs then
        fs = MakeFS(chart, 11)
        chart.labels[i] = fs
    end
    fs:SetTextColor(0.8, 0.8, 0.8)
    fs:Show()
    return fs
end

-- skrocona kwota do opisu osi (bez miedzi od 1g)
local function MoneyAxis(v)
    if v >= 10000 then
        return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r", math.floor(v / 10000), math.floor((v % 10000) / 100))
    end
    return ns.Money(v)
end

-- swiece dobowe z serii "aktualna min": otwarcie, zamkniecie, max, min (doba wg czasu lokalnego)
-- punkty z archiwum (p[4] == 2) maja prawdziwe min/max doby w p[5]; ich otwarcie = zamkniecie poprzedniej doby
local function BuildCandles(pts)
    local out, cur, key = {}, nil, nil
    for _, p in ipairs(pts) do
        local v = p[2]
        if v and v > 0 then
            local k = date("%Y%m%d", p[1])
            local x = p[5]
            local lo = (x and x[1] and x[1] > 0) and x[1] or v
            local hi = (x and x[2] and x[2] > 0) and x[2] or v
            if k ~= key then
                cur = { o = v, c = v, h = hi, l = lo, ts = 0, n = 0, syn = (p[4] == 2) }
                out[#out + 1] = cur
                key = k
            end
            cur.c = v
            if hi > cur.h then cur.h = hi end
            if lo < cur.l then cur.l = lo end
            cur.ts = cur.ts + p[1]
            cur.n = cur.n + 1
        end
    end
    for i, c in ipairs(out) do
        c.t = c.ts / c.n
        if c.syn and i > 1 then c.o = out[i - 1].c end
    end
    return out
end

-- seria cen dowolnego przedmiotu: archiwum (starsze dni) + wlasna historia
local function SeriesOf(itemString)
    local out, first = {}, math.huge
    local rec = ns.db.items[itemString]
    if rec and rec.hist then
        for _, p in ipairs(rec.hist) do
            if p[2] and p[2] > 0 then out[#out + 1] = { p[1], p[2] } end
        end
        if rec.hist[1] then first = rec.hist[1][1] end
    end
    local id = tonumber((itemString or ""):match("^i:(%d+)"))
    if id and ns.ArchivePoints then
        local pre = {}
        for _, p in ipairs(ns.ArchivePoints(id) or {}) do
            if p[1] < first then pre[#pre + 1] = { p[1], p[2] } end
        end
        for _, p in ipairs(out) do pre[#pre + 1] = p end
        out = pre
    end
    return out
end

-- seria do porownania, przeskalowana tak, by na poczatku zakresu miala te sama wartosc co glowna
local function BuildCompare(itemString2, pts, t0)
    local m0
    for _, p in ipairs(pts) do
        if p[2] and p[2] > 0 then m0 = p[2]; break end
    end
    if not m0 then return nil end
    local list = {}
    for _, p in ipairs(SeriesOf(itemString2)) do
        if p[1] >= t0 then list[#list + 1] = p end
    end
    if #list < 2 then return nil end
    local ratio = m0 / list[1][2]
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = { p[1], p[2] * ratio } end
    return out
end

local function PalLine()
    if ns.db and ns.db.colorblind then
        return { up = { 0.30, 0.65, 1.0 }, down = { 1.0, 0.55, 0.10 }, min = { 0.30, 0.65, 1.0 }, be = { 1.0, 0.55, 0.10 } }
    end
    return { up = { 0.2, 0.9, 0.4 }, down = { 1.0, 0.3, 0.3 }, min = { 0.2, 0.9, 0.4 }, be = { 1.0, 0.25, 0.25 } }
end

-- chart.big  = duzy wykres (siatka, osie, kursor); chart.range = ostatnie N sekund (nil = cala historia)
-- chart.candles = swiece dobowe; chart.showMedian / showSMA / costPrice / compare = nakladki (tylko duzy wykres)
-- chart.refLines = { {v = cena, label = "...", c = {r,g,b}}, ... } - linie odniesienia z TSM (tylko duzy wykres)
function ns.DrawChart(chart, itemString, breakEven, alertPrice)
    for _, l in pairs(chart.pool or {}) do l:Hide() end
    for _, fs in pairs(chart.labels or {}) do fs:Hide() end
    chart.empty:Hide()
    chart.hi:SetText("")
    chart.lo:SetText("")
    chart.xl:SetText("")
    chart.geom = nil

    local rec = itemString and ns.db.items[itemString]
    local h = rec and rec.hist
    if not h or #h < 2 then
        chart.empty:Show()
        return
    end

    local now = time()
    local t0 = h[1][1]
    if chart.range and now - chart.range > t0 then t0 = now - chart.range end
    if now <= t0 then chart.empty:Show(); return end

    local pts = {}
    for _, p in ipairs(h) do
        if p[1] >= t0 then pts[#pts + 1] = p end
    end
    if #pts < 2 then chart.empty:Show(); return end

    local big = chart.big
    local PL = PalLine()

    -- nakladki (tylko duzy wykres)
    local med, sma, cmp, cmpName
    if big then
        if chart.showMedian then
            local vals = {}
            for _, p in ipairs(pts) do
                if p[2] and p[2] > 0 then vals[#vals + 1] = p[2] end
            end
            table.sort(vals)
            local n = #vals
            if n > 0 then med = (n % 2 == 1) and vals[(n + 1) / 2] or (vals[n / 2] + vals[n / 2 + 1]) / 2 end
        end
        if chart.showSMA then
            sma = {}
            local j, sum, cnt = 1, 0, 0
            for _, p in ipairs(pts) do
                local v = p[2]
                if v and v > 0 then sum, cnt = sum + v, cnt + 1 end
                while pts[j][1] < p[1] - 86400 do
                    local u = pts[j][2]
                    if u and u > 0 then sum, cnt = sum - u, cnt - 1 end
                    j = j + 1
                end
                if cnt > 0 then sma[#sma + 1] = { p[1], sum / cnt } end
            end
        end
        if chart.compare and chart.compare ~= itemString then
            cmp = BuildCompare(chart.compare, pts, t0)
            if cmp then cmpName = ns.ItemName(chart.compare) end
        end
    end

    local lo, hi
    local function include(v)
        if v and v > 0 then
            lo = lo and math.min(lo, v) or v
            hi = hi and math.max(hi, v) or v
        end
    end
    for _, p in ipairs(pts) do
        include(p[2]); include(p[3])
        if p[5] then include(p[5][1]); include(p[5][2]) end
    end
    include(breakEven)
    include(alertPrice)
    include(med)
    include(big and chart.costPrice or nil)
    if big and chart.refLines then
        for _, r in ipairs(chart.refLines) do include(r.v) end
    end
    if sma then for _, p in ipairs(sma) do include(p[2]) end end
    if cmp then for _, p in ipairs(cmp) do include(p[2]) end end
    if not lo then chart.empty:Show(); return end
    if hi == lo then hi = lo * 1.05 + 1; lo = lo * 0.95 end

    if big then
        local m = (hi - lo) * 0.05
        lo = math.max(0, lo - m)
        hi = hi + m
    end

    local w, ht = chart:GetWidth(), chart:GetHeight()
    local padL, padR, padT, padB = 3, 3, 3, 3
    if big then padL, padR, padT, padB = 84, 14, 10, 26 end
    local plotW, plotH = w - padL - padR, ht - padT - padB
    local function X(t) return padL + (t - t0) / (now - t0) * plotW end
    local function Y(v) return padB + (v - lo) / (hi - lo) * plotH end

    local idx, nl = 0, 0
    local function seg(x1, y1, x2, y2, r, g, b, a, th)
        idx = idx + 1
        local l = GetLine(chart, idx)
        l:SetThickness(th or (big and 2 or 1.5))
        l:SetColorTexture(r, g, b, a or 1)
        l:SetStartPoint("BOTTOMLEFT", chart, x1, y1)
        l:SetEndPoint("BOTTOMLEFT", chart, x2, y2)
    end
    local function tag(v, txt, r, g, b)
        nl = nl + 1
        local fs = GetLabel(chart, nl)
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOMRIGHT", chart, "BOTTOMLEFT", w - padR - 4, Y(v) + 3)
        fs:SetJustifyH("RIGHT")
        fs:SetTextColor(r, g, b)
        fs:SetText(txt .. " " .. ns.MoneyPlain(v))
    end
    local function poly(list, r, g, b, a, th)
        local px, py
        for _, p in ipairs(list) do
            local x, y = X(p[1]), Y(p[2])
            if px then seg(px, py, x, y, r, g, b, a or 0.95, th or 1.5) end
            px, py = x, y
        end
    end

    if big then
        -- siatka pozioma + opis cen
        for i = 0, 4 do
            local v = lo + (hi - lo) * i / 4
            local y = Y(v)
            seg(padL, y, w - padR, y, 0.4, 0.42, 0.48, 0.4, 1)
            nl = nl + 1
            local fs = GetLabel(chart, nl)
            fs:ClearAllPoints()
            fs:SetPoint("RIGHT", chart, "BOTTOMLEFT", padL - 6, y)
            fs:SetJustifyH("RIGHT")
            fs:SetText(MoneyAxis(v))
        end
        -- siatka pionowa + opis czasu
        local fmt = (now - t0 <= 3 * 86400) and "%d.%m %H:%M" or "%d.%m"
        for i = 0, 5 do
            local t = t0 + (now - t0) * i / 5
            local x = X(t)
            seg(x, padB, x, ht - padT, 0.4, 0.42, 0.48, 0.25, 1)
            nl = nl + 1
            local fs = GetLabel(chart, nl)
            fs:ClearAllPoints()
            fs:SetPoint("TOP", chart, "BOTTOMLEFT", x, padB - 6)
            fs:SetJustifyH("CENTER")
            fs:SetText(i == 5 and "teraz" or date(fmt, t))
        end
    end

    local function series(k, r, g, b)
        local px, py
        for _, p in ipairs(pts) do
            local v = p[k]
            if v and v > 0 then
                local x, y = X(p[1]), Y(v)
                if px then seg(px, py, x, y, r, g, b) end
                px, py = x, y
            else
                px, py = nil, nil
            end
        end
    end

    series(3, 1.0, 0.82, 0.0)   -- rynek (zolty)
    local candles
    if big and chart.candles then
        candles = BuildCandles(pts)
        local bw = math.max(3, math.min(24, plotW / math.max(#candles, 1) * 0.5))
        for _, c in ipairs(candles) do
            local x = X(c.t)
            local col = (c.c >= c.o) and PL.up or PL.down      -- wzrost / spadek doby
            seg(x, Y(c.l), x, Y(c.h), col[1], col[2], col[3], 1, 1)                  -- knot
            local yo, yc = Y(c.o), Y(c.c)
            if math.abs(yo - yc) < 2 then yo, yc = yo - 1, yc + 1 end
            seg(x, yo, x, yc, col[1], col[2], col[3], 1, bw)                         -- korpus
        end
    else
        series(2, PL.min[1], PL.min[2], PL.min[3])    -- aktualna min
    end
    if breakEven then
        seg(X(t0), Y(breakEven), X(now), Y(breakEven), PL.be[1], PL.be[2], PL.be[3], 0.9)   -- break-even
    end
    if alertPrice then
        seg(X(t0), Y(alertPrice), X(now), Y(alertPrice), 0.3, 0.65, 1.0, 0.9)  -- prog alertu (niebieski)
    end

    if big then
        if med then
            seg(X(t0), Y(med), X(now), Y(med), 0.75, 0.75, 0.75, 0.8, 1)
            tag(med, "mediana", 0.8, 0.8, 0.8)
        end
        if sma then poly(sma, 0.3, 0.95, 0.95, 0.95, 1.5) end
        if chart.costPrice then
            seg(X(t0), Y(chart.costPrice), X(now), Y(chart.costPrice), 0.75, 0.5, 1.0, 0.9, 1.5)
            tag(chart.costPrice, "moj zakup", 0.75, 0.55, 1)
        end
        if chart.refLines then
            for _, r in ipairs(chart.refLines) do
                seg(X(t0), Y(r.v), X(now), Y(r.v), r.c[1], r.c[2], r.c[3], 0.85, 1.5)
                tag(r.v, r.label, r.c[1], r.c[2], r.c[3])
            end
        end
        if cmp then
            poly(cmp, 1.0, 0.45, 0.9, 0.95, 1.5)
            tag(cmp[#cmp][2], cmpName .. " (norm.)", 1, 0.55, 0.9)
        end
        if breakEven then tag(breakEven, "break-even", 1, 0.4, 0.4) end
        if alertPrice then tag(alertPrice, "alert", 0.4, 0.7, 1) end
    else
        chart.hi:SetText(ns.Money(hi))
        chart.lo:SetText(ns.Money(lo))
        chart.xl:SetText(AgeLabel(now - t0))
    end

    chart.geom = { X = X, Y = Y, pts = pts, candles = candles, padL = padL, padB = padB, plotW = plotW, plotH = plotH }
end

------------------------------------------------------------------
-- Widgety HUD: plakietki, karty, zakladki, wiersze tabeli
------------------------------------------------------------------
local VERDICT_BADGE = {
    BUY      = { "+ KUP",          "good" },
    MARGINAL = { "~ GRANICZNIE",   "warn" },
    NO       = { "- NIE KUPUJ",    "bad" },
    NODATA   = { "? BRAK DANYCH",  "none" },
}
local RISK_BADGE = {
    LOW  = { "RYZYKO NISKIE [N]",   "good" },
    MED  = { "RYZYKO SREDNIE [S]",  "warn" },
    HIGH = { "RYZYKO WYSOKIE [W]",  "bad" },
}

local function BadgePal()
    if ns.db and ns.db.colorblind then
        return { good = { 0.10, 0.40, 0.80 }, warn = { 0.62, 0.55, 0.08 }, bad = { 0.80, 0.40, 0.05 }, none = { 0.30, 0.32, 0.36 } }
    end
    return { good = { 0.12, 0.50, 0.25 }, warn = { 0.72, 0.50, 0.08 }, bad = { 0.62, 0.16, 0.16 }, none = { 0.30, 0.32, 0.36 } }
end

local function MakeBadge(parent, w, h, size)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.text = MakeFS(b, size or 11, "CENTER")
    b.text:SetPoint("CENTER", 0, 0)
    b.text:SetTextColor(1, 1, 1)
    return b
end

local function SetBadge(b, def, extra)
    if not def then b:Hide(); return end
    local c = BadgePal()[def[2]] or BadgePal().none
    b:Show()
    b.bg:SetColorTexture(c[1], c[2], c[3], 0.92)
    b.text:SetText(def[1] .. (extra or ""))
end

local function MakeCard(parent, x, y, w, h, label)
    local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    c:SetSize(w, h)
    c:SetPoint("TOPLEFT", x, y)
    c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    c:SetBackdropColor(0.10, 0.11, 0.14, 1)
    c:SetBackdropBorderColor(0.22, 0.24, 0.29, 1)
    c.label = MakeFS(c, 9)
    c.label:SetPoint("TOPLEFT", 8, -6)
    c.label:SetText(GRAY .. label .. "|r")
    c.value = MakeFS(c, 14)
    c.value:SetPoint("TOPLEFT", 8, -21)
    c.value:SetWidth(w - 14)
    c.value:SetWordWrap(false)
    c.sub = MakeFS(c, 9)
    c.sub:SetPoint("TOPLEFT", 8, -42)
    c.sub:SetWidth(w - 14)
    c.sub:SetWordWrap(false)
    return c
end

local function SetCard(c, value, sub)
    c.value:SetText(value or "|cff888888--|r")
    c.sub:SetText(sub or "")
end

local function MakeStatRows(parent, n, w, rowH, x, y)
    local rows = {}
    for i = 1, n do
        local r = CreateFrame("Frame", nil, parent)
        r:SetSize(w, rowH)
        r:SetPoint("TOPLEFT", x, y - (i - 1) * rowH)
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.label = MakeFS(r, 11)
        r.label:SetPoint("LEFT", 6, 0)
        r.label:SetWordWrap(false)
        r.label:SetTextColor(0.62, 0.64, 0.67)
        r.value = MakeFS(r, 11, "RIGHT")
        r.value:SetPoint("RIGHT", -6, 0)
        r.value:SetWordWrap(false)
        rows[i] = r
    end
    return rows
end

-- list = { {label, value}, ... }; wpis {header = "Tytul"} to naglowek sekcji
local function SetStatRows(rows, list)
    for i, r in ipairs(rows) do
        local it = list and list[i]
        if not it then
            r:Hide()
        else
            r:Show()
            r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.035 or 0)
            if it.header then
                r.bg:SetColorTexture(0.2, 0.5, 1, 0.12)
                r.label:SetWidth(CONTENT_W - 12)
                r.label:SetText(BLUE .. it.header .. "|r")
                r.value:SetText("")
            else
                r.label:SetWidth(CONTENT_W * 0.46)
                r.label:SetText(it[1])
                r.value:SetWidth(CONTENT_W * 0.52)
                r.value:SetText(it[2] or "")
            end
        end
    end
end

local TABS = { { "overview", "Przeglad" }, { "market", "Rynek" }, { "risk", "Ryzyko" }, { "notes", "Uwagi" } }

------------------------------------------------------------------
-- Aktualizacja HUD
------------------------------------------------------------------
local function TrendText(hs)
    if not hs.trend then return "--" end
    local col, word = GRAY, "stabilny"
    if hs.trend > 1 then col, word = GREEN, "rosnie" elseif hs.trend < -1 then col, word = RED, "spada" end
    return string.format("%s%s %+.1f%%/d|r", col, word, hs.trend)
end

local function CategoryOf(s)
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if id and getInstant then
        local _, itemType, itemSubType = getInstant(id)
        if itemType and itemType ~= "" then
            if itemSubType and itemSubType ~= "" and itemSubType ~= itemType then
                return itemType .. " / " .. itemSubType
            end
            return itemType
        end
    end
    return nil
end

local function ShowMessage(u, verdictText, lines)
    u.name:SetText("")
    u.sub:SetText("")
    u.icon:SetTexture(134400)
    SetBadge(u.verdictBadge, { verdictText, "none" })
    u.riskBadge:Hide()
    SetCard(u.card1, nil, "")
    SetCard(u.card2, nil, "")
    SetCard(u.card3, nil, "")
    SetStatRows(u.rows, nil)
    u.notes:SetText(table.concat(lines, "\n\n"))
    u.notes:Show()
end

local function Update()
    local f = ns.frame
    if not f then return end
    local db = ns.db
    local s = db.selected
    local u = f.ui

    u.houseBtn:SetText(string.format("Dom: %s (%s%%)",
        db.house == "neutral" and "neutralny" or "frakcyjny", tostring(ns.Cut())))

    -- zakladki
    local tab = db.hudTab or "overview"
    for _, t in ipairs(u.tabs) do
        local active = (t.key == tab)
        t.text:SetText(active and (WHITE .. t.label .. "|r") or (GRAY .. t.label .. "|r"))
        t.line:SetShown(active)
    end

    -- stopka
    if ns.lastRefresh then
        u.footer:SetText(string.format("Odswiezono %s  |  nastepne ~%s  |  co %d min",
            date("%H:%M", ns.lastRefresh), date("%H:%M", ns.nextRefresh or ns.lastRefresh), db.refreshMin))
    else
        u.footer:SetText(string.format("Brak odswiezenia  |  co %d min", db.refreshMin))
    end

    if not ns.HasTSM() then
        ShowMessage(u, "BRAK TSM", { RED .. "TSM nie wykryte.|r", "Zainstaluj i wlacz addon TradeSkillMaster oraz aplikacje desktopowa TSM (dane cenowe)." })
        ns.DrawChart(u.chart, nil)
        return
    end

    if not s then
        u.watchBtn:SetText("Obserwuj")
        ShowMessage(u, "WYBIERZ", { GRAY .. "Wklej przedmiot i kliknij Analizuj.|r",
            "Kliknij pole nad nim i zrob Shift+klik na przedmiocie (torba / AH), wpisz ID albo nazwe. Przedmioty mozesz tez dodawac w menu Lista." })
        ns.DrawChart(u.chart, nil)
        return
    end

    u.icon:SetTexture(ns.ItemIcon(s))
    u.name:SetText(ns.ItemName(s))
    local watched = ns.IsWatched(s)
    u.watchBtn:SetText(watched and "Usun z listy" or "Obserwuj")
    local sub = CategoryOf(s) or ""
    if watched then sub = sub .. (sub ~= "" and "   " or "") .. GREEN .. "[obserwowany]|r" end
    u.sub:SetText(GRAY .. sub .. "|r")

    local d = ns.cache[s] or ns.FetchTSM(s)
    local buy, buySrc = ns.EffectiveBuy(s, d)
    local r = ns.Analyze(s, d, buy)
    local hs = r.hs

    if r.verdict == "NODATA" then
        SetBadge(u.verdictBadge, VERDICT_BADGE.NODATA)
        u.riskBadge:Hide()
        SetCard(u.card1, nil, "")
        SetCard(u.card2, nil, "")
        SetCard(u.card3, nil, "")
    else
        SetBadge(u.verdictBadge, VERDICT_BADGE[r.verdict])
        SetBadge(u.riskBadge, RISK_BADGE[r.risk.level], string.format(" (%d)", r.risk.score))

        -- karty glowne: ile maksymalnie zaplacic, za ile wystawic, ile zarobisz
        local buyCol = (r.maxBuy and r.buy <= r.maxBuy) and GREEN or RED
        SetCard(u.card1, r.maxBuy and MoneyShort(r.maxBuy) or nil,
            GRAY .. "zakup: |r" .. buyCol .. ns.MoneyPlain(r.buy) .. "|r")
        SetCard(u.card2, MoneyShort(r.suggest), GRAY .. "break-even " .. ns.MoneyPlain(r.breakEven) .. "|r")
        local pr = r.suggestProfit
        SetCard(u.card3, (pr >= 0 and (GREEN .. "+|r") or "") .. MoneyShort(pr), PctStr(r.suggestPct) .. GRAY .. " / szt.|r")
    end

    ---------------- zakladka: Przeglad ----------------
    local overview = {}
    if r.verdict == "NODATA" then
        overview[#overview + 1] = { GRAY .. "Brak ceny z TSM dla tego przedmiotu.|r", "" }
    else
        overview[#overview + 1] = { "Cena zakupu (" .. buySrc .. ")", ns.Money(r.buy) }
        overview[#overview + 1] = { string.format("Break-even (prowizja %s%%)", tostring(ns.Cut())), ns.Money(r.breakEven) }
        overview[#overview + 1] = { string.format("Min. wystawienie (+%s%%)", tostring(db.margin)), ns.Money(r.minList) }
        overview[#overview + 1] = { WHITE .. "Wystaw za|r", ns.Money(r.suggest) .. "  " .. PctStr(r.suggestPct) }
        if r.fast then
            overview[#overview + 1] = { "Szybka (undercut)", ns.Money(r.fast) .. "  " .. PctStr(r.fastPct) }
        end
        overview[#overview + 1] = { "Cel (cena ref.)", ns.Money(r.target) .. "  " .. PctStr(r.targetPct) }
        if r.craftCost then
            overview[#overview + 1] = { "Craft (koszt " .. ns.MoneyPlain(r.craftCost) .. ")", PctStr(r.craftPct) }
        end
        overview[#overview + 1] = { "Oczekiwany zysk (wg ref.)", ns.Money(r.expected) }
        overview[#overview + 1] = { "Depozyt / szt.", ns.Money(r.deposit) }
        if r.maxUnits then
            overview[#overview + 1] = { "Max do kupienia", r.maxUnits .. " szt." }
        end
        if r.own then
            overview[#overview + 1] = { "Twoja aukcja", (r.ownLowest and (GREEN .. "najnizsza|r ") or (ORANGE .. "podbita|r ")) .. ns.Money(r.own) }
        end
    end

    ---------------- zakladka: Rynek ----------------
    local market = {}
    market[#market + 1] = { "Aktualna min", ns.Money(d.minbuy) }
    market[#market + 1] = { r.formulaUsed and "Cena ref. (wzor TSM)" or "Rynek (DBMarket ~14d)",
        ns.Money(r.marketRaw or d.market) .. (r.youngAdj and ("  " .. ORANGE .. "-> " .. ns.MoneyPlain(r.sellRef) .. "|r") or "") }
    market[#market + 1] = { "Ostatnia (DBRecent)", ns.Money(d.recent) }
    market[#market + 1] = { "Sr. sprzedazy (region)", ns.Money(d.regionSale) }
    if hs then
        market[#market + 1] = { string.format("Min (%dd, %d pkt)", db.histDays, hs.n), ns.Money(hs.min) }
        market[#market + 1] = { "Srednia", ns.Money(hs.avg) }
        market[#market + 1] = { "Max", ns.Money(hs.max) }
        market[#market + 1] = { "Mediana", ns.Money(hs.median) }
        market[#market + 1] = { "Zmiennosc", string.format("%.0f%%", hs.stdevPct) }
        market[#market + 1] = { "Trend", TrendText(hs) }
    else
        market[#market + 1] = { "Zakres wlasny", "|cff888888zbieram dane...|r" }
    end
    local perDay = d.perDay and (d.perDay / (db.perDayDiv or 1)) or nil
    market[#market + 1] = { "Tempo sprzedazy",
        (d.saleRate and string.format("sale rate %.3f", d.saleRate) or (ORANGE .. "brak danych|r"))
        .. (perDay and string.format(", ~%.2f/dzien", perDay) or "") }
    if d.avgBuy then
        market[#market + 1] = { "Twoj sr. zakup (TSM)", ns.Money(d.avgBuy) }
    end

    ---------------- zakladka: Ryzyko ----------------
    local risk = {}
    if r.verdict == "NODATA" then
        risk[#risk + 1] = { GRAY .. "Brak danych do oceny ryzyka.|r", "" }
    else
        local rk = r.risk
        local x = rk.extra
        risk[#risk + 1] = { "Poziom ryzyka", ns.RISK_TEXT[rk.level] .. string.format("  (%d / 100)", rk.score) }
        local pcol = (rk.p >= 0.7 and GREEN) or (rk.p >= 0.5 and YELLOW) or RED
        local range = rk.pLo and string.format("  %s(%.0f-%.0f%%)|r", GRAY, rk.pLo * 100, rk.pHi * 100) or ""
        risk[#risk + 1] = { "Szansa sprzedazy", pcol .. string.format("%.0f%%", rk.p * 100) .. "|r" .. range }
        local src = rk.pSrc or (rk.pOwn and "wlasne dane" or "szacunek")
        if rk.pOwn and rk.nOwn then src = src .. string.format(" (n=%d)", rk.nOwn) end
        risk[#risk + 1] = { "Zrodlo oceny", GRAY .. src .. "|r" }
        if x then
            if x.buffer then
                local bc = (x.bufferSigma < 1 and RED) or (x.bufferSigma < 2 and YELLOW) or GREEN
                risk[#risk + 1] = { "Bufor spadku", bc .. string.format("%.0f%% = %.1fx zmiennosci|r", x.buffer, x.bufferSigma) }
                risk[#risk + 1] = { "Przyjeta zmiennosc", string.format("%.0f%%", x.sEff) }
            end
            if x.perDay then
                risk[#risk + 1] = { "Rynek sprzedaje", string.format("~%.1f szt./dzien", x.perDay) }
                risk[#risk + 1] = { string.format("Twoje w 48h (udzial %.0f%%)", x.share * 100), string.format("~%d szt.", x.maxSell or 0) }
                if x.days then
                    local dc = (x.days > 4 and RED) or (x.days > 2 and YELLOW) or GREEN
                    risk[#risk + 1] = { string.format("Czas sprzedazy %d szt.", x.qty), dc .. string.format("~%.1f dnia|r", x.days) }
                end
            else
                risk[#risk + 1] = { "Tempo sprzedazy", ORANGE .. "brak danych z TSM|r" }
            end
            risk[#risk + 1] = { "Roznych wartosci w historii", string.format("%d z %d pomiarow", x.nUniq, x.nPts) }
            if x.span then risk[#risk + 1] = { "Dlugosc historii", string.format("%.1f dnia", x.span) } end
            risk[#risk + 1] = { "Swiezosc danych", x.stale and (ORANGE .. "plaski rynek / nieswieze|r") or (GREEN .. "OK|r") }
        else
            risk[#risk + 1] = { GRAY .. "Rozszerzona ocena ryzyka wylaczona lub niedostepna.|r", "" }
        end
    end

    ---------------- zakladka: Uwagi ----------------
    local notes = {}
    if r.verdict ~= "NODATA" then
        for _, n in ipairs(r.notes) do notes[#notes + 1] = ORANGE .. "! |r" .. n end
        if r.risk.why and #r.risk.why > 0 then
            notes[#notes + 1] = GRAY .. "Skladniki ryzyka:|r " .. table.concat(r.risk.why, "; ") .. "."
        end
    end
    if #notes == 0 then notes[1] = GRAY .. "Brak uwag.|r" end

    if tab == "market" then
        SetStatRows(u.rows, market)
        u.notes:Hide()
    elseif tab == "risk" then
        SetStatRows(u.rows, risk)
        u.notes:Hide()
    elseif tab == "notes" then
        SetStatRows(u.rows, nil)
        u.notes:SetText(table.concat(notes, "\n\n"))
        u.notes:Show()
    else
        SetStatRows(u.rows, overview)
        u.notes:Hide()
    end

    ns.DrawChart(u.chart, s, r.breakEven, db.alerts[s])
end

function ns.UpdateUI()
    if ns.InvalidateTips then ns.InvalidateTips() end   -- zmiana ustawien/danych = uniewaznij cache tooltipa
    ns.Safe("ui", Update)
    if ns.UpdateBigChart then ns.Safe("bigchart", ns.UpdateBigChart) end
end

function ns.ApplyScale()
    local sc = ns.db.scale or 1
    if ns.frame then ns.frame:SetScale(sc) end
    if ns.panel then ns.panel:SetScale(sc) end
end

------------------------------------------------------------------
-- Duzy wykres na srodku ekranu (klik w maly wykres w HUD albo /tsma chart)
------------------------------------------------------------------
local RANGES = { { "24h", 86400 }, { "3 dni", 3 * 86400 }, { "7 dni", 7 * 86400 }, { "30 dni", 30 * 86400 }, { "Wszystko", nil } }

-- kursor: pionowa linia, punkty na seriach i odczyt wartosci najblizszego pomiaru (w trybie swiec: O/H/L/C doby)
local function ChartHover(chart)
    local g = chart.geom
    local function off()
        chart.cursor:Hide()
        chart.dotMin:Hide()
        chart.dotMkt:Hide()
        chart.hover:SetText("")
    end
    if not g or not chart:IsMouseOver() then off(); return end
    local cx = GetCursorPosition()
    local x = cx / chart:GetEffectiveScale() - chart:GetLeft()
    if x < g.padL or x > g.padL + g.plotW then off(); return end

    if chart.candles and g.candles and #g.candles > 0 then
        local bestC, bd
        for _, c in ipairs(g.candles) do
            local d = math.abs(g.X(c.t) - x)
            if not bd or d < bd then bestC, bd = c, d end
        end
        local px = g.X(bestC.t)
        chart.cursor:SetStartPoint("BOTTOMLEFT", chart, px, g.padB)
        chart.cursor:SetEndPoint("BOTTOMLEFT", chart, px, g.padB + g.plotH)
        chart.cursor:Show()
        chart.dotMin:Hide()
        chart.dotMkt:Hide()
        chart.hover:SetText(string.format("%s    otw.%s %s    max %s    min %s    zamk. %s",
            date("%d.%m.%Y", bestC.t), bestC.syn and "~" or "", ns.Money(bestC.o), ns.Money(bestC.h),
            ns.Money(bestC.l), ns.Money(bestC.c)))
        return
    end

    local best, bd
    for _, p in ipairs(g.pts) do
        local d = math.abs(g.X(p[1]) - x)
        if not bd or d < bd then best, bd = p, d end
    end
    if not best then off(); return end

    local px = g.X(best[1])
    chart.cursor:SetStartPoint("BOTTOMLEFT", chart, px, g.padB)
    chart.cursor:SetEndPoint("BOTTOMLEFT", chart, px, g.padB + g.plotH)
    chart.cursor:Show()

    local function dot(tex, v)
        if v and v > 0 then
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", chart, "BOTTOMLEFT", px, g.Y(v))
            tex:Show()
        else
            tex:Hide()
        end
    end
    dot(chart.dotMin, best[2])
    dot(chart.dotMkt, best[3])

    chart.hover:SetText(string.format("%s    |cff33e666min|r %s    |cffffd100rynek|r %s",
        date("%d.%m.%Y %H:%M", best[1]),
        (best[2] and best[2] > 0) and ns.Money(best[2]) or "--",
        (best[3] and best[3] > 0) and ns.Money(best[3]) or "--"))
end

local function ToggleText(btn, label, on)
    btn:SetText((on and "[x] " or "[ ] ") .. label)
end

local function BuildBigChart()
    local W, H = 880, 548
    local f = CreateFrame("Frame", "TsmAnalizeBigChart", UIParent, "BackdropTemplate")
    ns.bigChart = f
    f:SetSize(W, H)
    local cp = ns.db.chartPos
    if cp then f:SetPoint(cp[1], UIParent, cp[2], cp[3], cp[4]) else f:SetPoint("CENTER") end
    f:SetFrameStrata("DIALOG")
    ns.DarkBackdrop(f, 0.97)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        ns.db.chartPos = { p, rp, x, y }   -- pozycja zapamietana miedzy sesjami
    end)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeBigChart") end   -- Esc zamyka

    f.title = MakeFS(f, 16)
    f.title:SetPoint("TOPLEFT", 14, -10)
    f.title:SetWidth(W - 480)
    f.title:SetWordWrap(false)

    f.stats = MakeFS(f, 11)
    f.stats:SetPoint("TOPLEFT", 14, -34)
    f.stats:SetWidth(W - 28)

    f.hover = MakeFS(f, 12)
    f.hover:SetPoint("TOPLEFT", 14, -54)
    f.hover:SetWidth(W - 28)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local chart = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.chart = chart
    chart.big = true
    chart.pool = {}
    chart:SetSize(W - 24, H - 138)
    chart:SetPoint("TOPLEFT", 12, -76)
    chart:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    chart:SetBackdropColor(0.02, 0.03, 0.04, 0.9)

    chart.empty = MakeFS(chart, 13, "CENTER")
    chart.empty:SetPoint("CENTER")
    chart.empty:SetText("|cff888888Za malo punktow w tym zakresie (zapis historii co " .. ns.db.histEveryMin .. " min)|r")
    chart.hi = MakeFS(chart, 10)   -- wymagane przez DrawChart; w duzym wykresie nieuzywane
    chart.lo = MakeFS(chart, 10)
    chart.xl = MakeFS(chart, 10)
    chart.hover = f.hover

    chart.cursor = chart:CreateLine(nil, "OVERLAY")
    chart.cursor:SetThickness(1)
    chart.cursor:SetColorTexture(1, 1, 1, 0.45)
    chart.cursor:Hide()
    chart.dotMin = chart:CreateTexture(nil, "OVERLAY")
    chart.dotMin:SetSize(8, 8)
    chart.dotMin:SetColorTexture(0.2, 0.9, 0.4, 1)
    chart.dotMin:Hide()
    chart.dotMkt = chart:CreateTexture(nil, "OVERLAY")
    chart.dotMkt:SetSize(8, 8)
    chart.dotMkt:SetColorTexture(1, 0.82, 0, 1)
    chart.dotMkt:Hide()
    chart:SetScript("OnUpdate", ChartHover)

    -- zakres czasu
    f.rangeBtns = {}
    local prev
    for i = #RANGES, 1, -1 do
        local r = RANGES[i]
        local b = ns.MakeButton(f, r[1], (i == #RANGES) and 74 or 58, 20)
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", -34, -8) end
        b:SetScript("OnClick", function()
            chart.range = r[2]
            ns.UpdateBigChart()
        end)
        f.rangeBtns[i] = b
        prev = b
    end

    -- linia / swiece dobowe
    local cb = ns.MakeButton(f, "Swiece", 70, 20)
    cb:SetPoint("RIGHT", prev, "LEFT", -14, 0)
    cb:SetScript("OnClick", function()
        chart.candles = not chart.candles
        ns.UpdateBigChart()
    end)
    f.candleBtn = cb

    -- nakladki: mediana, srednia ruchoma 24h, cena zakupu, linie odniesienia TSM, porownanie z innym przedmiotem
    local function Overlay(label, w, x, field)
        local b = ns.MakeButton(f, "", w, 20)
        b:SetPoint("BOTTOMLEFT", x, 34)
        b:SetScript("OnClick", function()
            chart[field] = not chart[field]
            ns.UpdateBigChart()
        end)
        b.field, b.label = field, label
        return b
    end
    f.overlayBtns = {
        Overlay("Mediana", 84, 14, "showMedian"),
        Overlay("Srednia ruchoma 24h", 150, 102, "showSMA"),
        Overlay("Moj zakup", 96, 256, "showCost"),
        Overlay("Ref. TSM", 90, 676, "showTSM"),
    }

    local cmpLbl = MakeFS(f, 10)
    cmpLbl:SetPoint("BOTTOMLEFT", 370, 38)
    cmpLbl:SetText(GRAY .. "Porownaj z (ID/link):|r")
    f.cmpBox = ns.MakeInput(f, 150)
    f.cmpBox:SetPoint("BOTTOMLEFT", 480, 33)
    f.cmpBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local txt = self:GetText()
        chart.compare = (txt ~= "") and ns.ResolveItem(txt) or nil
        if txt ~= "" and not chart.compare then ns.Print("Nie rozpoznano przedmiotu do porownania.") end
        ns.UpdateBigChart()
    end)
    local clr = ns.MakeButton(f, "x", 24, 20)
    clr:SetPoint("LEFT", f.cmpBox, "RIGHT", 6, 0)
    clr:SetScript("OnClick", function()
        chart.compare = nil
        f.cmpBox:SetText("")
        ns.UpdateBigChart()
    end)

    local legend = MakeFS(f, 10)
    legend:SetPoint("BOTTOMLEFT", 14, 12)
    legend:SetWidth(W - 28)
    legend:SetText("|cff33e666--|r min (swiece: zielona = wzrost doby, czerwona = spadek; otw.~ = zamkniecie poprzedniej doby)   |cffffd100--|r rynek   |cffff4040--|r break-even   |cff4da6ff--|r alert   |cfff29933--|r TSM 60d   |cff99c759--|r TSM region"
        .. "   |cff9aa0a6Starsze dni pochodza z archiwum (dobowe). Esc = zamknij.|r")
end

function ns.UpdateBigChart()
    local f = ns.bigChart
    if not f or not f:IsShown() then return end
    local db = ns.db
    local s = db.selected
    local chart = f.chart
    chart.refLines = nil
    for i, b in ipairs(f.rangeBtns) do b:SetEnabled(chart.range ~= RANGES[i][2]) end
    f.candleBtn:SetText(chart.candles and "Linia" or "Swiece")
    for _, b in ipairs(f.overlayBtns) do ToggleText(b, b.label, chart[b.field]) end

    if not s then
        f.title:SetText("Brak wybranego przedmiotu")
        f.stats:SetText("")
        chart.costPrice = nil
        ns.DrawChart(chart, nil)
        return
    end
    f.title:SetText(ns.ItemName(s))
    chart.costPrice = chart.showCost and db.buyPrice[s] or nil

    local base
    local hs = ns.HistStats(s)
    if hs then
        base = string.format("Zakres %dd (%d pkt): %s / %s / %s   mediana %s   zmienn. %.0f%%   trend %s",
            db.histDays, hs.n, ns.Money(hs.min), ns.Money(hs.avg), ns.Money(hs.max), ns.Money(hs.median),
            hs.stdevPct, TrendText(hs))
    else
        base = "|cff888888Zbieram dane...|r"
    end

    local breakEven
    local tsmNote
    if ns.HasTSM() then
        local d = ns.cache[s] or ns.FetchTSM(s)
        local r = ns.Analyze(s, d, (ns.EffectiveBuy(s, d)))
        breakEven = r.breakEven

        -- linie odniesienia z TSM: DBHistorical (srednia 60 dni z DBMarket) i DBRegionMarketAvg (region)
        if chart.showTSM then
            local refs = {}
            if d.historical then
                refs[#refs + 1] = { v = d.historical, label = "TSM 60d", c = { 0.95, 0.60, 0.20 } }
            end
            if d.regionMarket then
                refs[#refs + 1] = { v = d.regionMarket, label = "TSM region", c = { 0.60, 0.78, 0.35 } }
            end
            if #refs > 0 then
                chart.refLines = refs
            else
                tsmNote = "   |cff9aa0a6TSM nie ma DBHistorical / DBRegionMarketAvg dla tego przedmiotu|r"
            end
        end
    end
    ns.DrawChart(chart, s, breakEven, db.alerts[s])

    -- zmiana w widocznym zakresie
    local g = chart.geom
    if g and #g.pts >= 2 then
        local first, last
        for _, p in ipairs(g.pts) do
            if p[2] and p[2] > 0 then first = first or p[2]; last = p[2] end
        end
        if first and last and first > 0 then
            base = base .. "   zmiana w zakresie " .. PctStr((last / first - 1) * 100)
        end
    end
    f.stats:SetText(base .. (tsmNote or ""))
end

function ns.ToggleBigChart()
    if not ns.bigChart then BuildBigChart() end
    local f = ns.bigChart
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        ns.UpdateBigChart()
    end
end

------------------------------------------------------------------
-- Przycisk przy minimapie (lewy = HUD, prawy = panel, Shift+lewy = wykres, przeciaganie = przesuniecie)
------------------------------------------------------------------
local function PlaceMinimap()
    local b = ns.minimapBtn
    if not b then return end
    local a = math.rad((ns.db.minimap and ns.db.minimap.angle) or 215)
    local r = (Minimap:GetWidth() / 2) + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function BuildMinimap()
    local b = CreateFrame("Button", "TsmAnalizeMinimapButton", Minimap)
    ns.minimapBtn = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    b:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then
            if ns.TogglePanel then ns.TogglePanel() end
        elseif IsShiftKeyDown() then
            if ns.ToggleBigChart then ns.ToggleBigChart() end
        else
            ns.Toggle()
        end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local sc = Minimap:GetEffectiveScale()
            local atan = math.atan2 or math.atan
            ns.db.minimap = ns.db.minimap or {}
            ns.db.minimap.angle = math.deg(atan(cy / sc - my, cx / sc - mx))
            PlaceMinimap()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("TSM Analize", 1, 1, 1)
        GameTooltip:AddLine("Lewy klik: HUD", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Prawy klik: panel (okazje, dziennik, craft)", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Shift + lewy: duzy wykres", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Przeciagnij: przesun przycisk", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimap()
end

function ns.ApplyMinimap()
    if not ns.db then return end
    if not ns.minimapBtn then
        if not ns.db.minimapShow then return end
        BuildMinimap()
    end
    PlaceMinimap()
    ns.minimapBtn:SetShown(ns.db.minimapShow and true or false)
end

-- Addon Compartment (menu addonow przy minimapie w nowych klientach); funkcje wskazane w .toc
function TsmAnalize_OnCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then
        if ns.TogglePanel then ns.TogglePanel() end
    else
        if ns.Toggle then ns.Toggle() end
    end
end

function TsmAnalize_OnCompartmentEnter(_, frame)
    GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
    GameTooltip:SetText("TSM Analize", 1, 1, 1)
    GameTooltip:AddLine("Lewy klik: HUD   Prawy klik: panel", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function TsmAnalize_OnCompartmentLeave()
    GameTooltip:Hide()
end

------------------------------------------------------------------
-- Budowa okna
------------------------------------------------------------------
function ns.BuildUI()
    local db = ns.db

    local f = CreateFrame("Frame", "TsmAnalizeFrame", UIParent, "BackdropTemplate")
    ns.frame = f
    f:SetSize(WIDTH, HEIGHT)
    f:SetScale(db.scale or 1)
    if db.pos then
        f:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
    end
    ns.DarkBackdrop(f, 0.95)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        db.pos = { p, rp, x, y }
    end)
    f:SetShown(db.shown)

    local u = {}
    f.ui = u

    ---------------- pasek tytulowy + przyciski ----------------
    local title = MakeFS(f, 15)
    title:SetPoint("TOPLEFT", 14, -9)
    title:SetText(BLUE .. "TSMA|r")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() f:Hide(); db.shown = false end)

    -- Panel, Lista, Rynek, ML i Ustawienia otwierasz zakladkami z boku okna (plik Dock.lua)
    local refresh = ns.MakeButton(f, "Odswiez", 64, 20)
    refresh:SetPoint("TOPRIGHT", -34, -6)
    refresh:SetScript("OnClick", function() ns.Safe("refresh", ns.RefreshAll) end)

    ---------------- wybor przedmiotu ----------------
    local itemLbl = MakeFS(f, 10)
    itemLbl:SetPoint("TOPLEFT", 16, -34)
    itemLbl:SetText(GRAY .. "PRZEDMIOT (Shift+klik, ID lub nazwa)|r")

    local itemBox = ns.MakeInput(f, 270)
    itemBox:SetPoint("TOPLEFT", 22, -48)
    ns.itemBox = itemBox

    local buyLbl = MakeFS(f, 10)
    buyLbl:SetPoint("TOPLEFT", 16, -76)
    buyLbl:SetText(GRAY .. "CENA ZAKUPU (puste = akt. min)|r")

    local alertLbl = MakeFS(f, 10)
    alertLbl:SetPoint("TOPLEFT", 216, -76)
    alertLbl:SetText(GRAY .. "ALERT GDY MIN <=|r")

    local buyBox = ns.MakeInput(f, 178)
    buyBox:SetPoint("TOPLEFT", 22, -90)
    ns.buyBox = buyBox

    local alertBox = ns.MakeInput(f, 170)
    alertBox:SetPoint("TOPLEFT", 222, -90)
    ns.alertBox = alertBox

    local dirtyBuy, dirtyAlert = false, false
    buyBox:SetScript("OnTextChanged", function(_, user) if user then dirtyBuy = true end end)
    alertBox:SetScript("OnTextChanged", function(_, user) if user then dirtyAlert = true end end)

    local function Apply()
        local txt = itemBox:GetText()
        local s = ns.ResolveItem(txt)
        if not s and txt ~= "" then
            ns.Print("Nie rozpoznano przedmiotu.")
            return
        end
        s = s or db.selected
        if not s then
            ns.Print("Wpisz przedmiot.")
            return
        end

        if dirtyBuy then
            local bt = buyBox:GetText()
            if bt == "" then
                db.buyPrice[s] = nil
            else
                local v = ns.ParseMoney(bt)
                if v then db.buyPrice[s] = v else ns.Print("Nie rozumiem ceny zakupu. Przyklad: 12g 50s 3c") end
            end
        end
        if dirtyAlert then
            local at = alertBox:GetText()
            if at == "" then
                db.alerts[s] = nil
            else
                local v = ns.ParseMoney(at)
                if v then db.alerts[s] = v else ns.Print("Nie rozumiem progu alertu. Przyklad: 5g 20s") end
            end
            ns.alertState[s] = nil
        end

        itemBox:ClearFocus()
        buyBox:ClearFocus()
        alertBox:ClearFocus()
        ns.Select(s)
    end
    ns.ApplyInputs = Apply

    itemBox:SetScript("OnEnterPressed", Apply)
    buyBox:SetScript("OnEnterPressed", Apply)
    alertBox:SetScript("OnEnterPressed", Apply)

    -- po wyborze przedmiotu wczytaj jego zapisane wartosci do pol
    ns.onSelect = function(s)
        buyBox:SetText(ns.MoneyPlain(db.buyPrice[s]))
        alertBox:SetText(ns.MoneyPlain(db.alerts[s]))
        itemBox:SetText(s)
        itemBox:SetCursorPosition(0)
        dirtyBuy, dirtyAlert = false, false
    end

    local analyze = ns.MakeButton(f, "Analizuj", 108, 22)
    analyze:SetPoint("TOPLEFT", 298, -48)
    analyze:SetScript("OnClick", Apply)

    ---------------- obserwowane + dom aukcyjny ----------------
    local watchBtn = ns.MakeButton(f, "Obserwuj", 100, 22)
    watchBtn:SetPoint("TOPLEFT", 16, -120)
    watchBtn:SetScript("OnClick", function()
        local s = db.selected
        if not s then return end
        local i = ns.IsWatched(s)
        if i then table.remove(db.watch, i) else table.insert(db.watch, s) end
        ns.UpdateUI()
    end)
    u.watchBtn = watchBtn

    local function Cycle(step)
        local n = #db.watch
        if n == 0 then ns.Print("Lista obserwowanych jest pusta."); return end
        local i = (db.selected and ns.IsWatched(db.selected)) or 0
        i = ((i - 1 + step) % n) + 1
        ns.Select(db.watch[i])
    end

    local prev = ns.MakeButton(f, "<", 32, 22)
    prev:SetPoint("LEFT", watchBtn, "RIGHT", 4, 0)
    prev:SetScript("OnClick", function() Cycle(-1) end)

    local nxt = ns.MakeButton(f, ">", 32, 22)
    nxt:SetPoint("LEFT", prev, "RIGHT", 3, 0)
    nxt:SetScript("OnClick", function() Cycle(1) end)

    local houseBtn = ns.MakeButton(f, "Dom: frakcyjny (5%)", 220, 22)
    houseBtn:SetPoint("TOPLEFT", 186, -120)
    houseBtn:SetScript("OnClick", function()
        db.house = (db.house == "neutral") and "faction" or "neutral"
        ns.UpdateUI()
    end)
    u.houseBtn = houseBtn

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.25, 0.27, 0.32, 1)
    sep:SetPoint("TOPLEFT", 16, -149)
    sep:SetSize(WIDTH - 32, 1)

    ---------------- naglowek przedmiotu: ikona, nazwa, plakietki ----------------
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(38, 38)
    icon:SetPoint("TOPLEFT", 16, -158)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    u.icon = icon

    u.name = MakeFS(f, 15)
    u.name:SetPoint("TOPLEFT", 62, -160)
    u.name:SetWidth(206)
    u.name:SetWordWrap(false)

    u.sub = MakeFS(f, 10)
    u.sub:SetPoint("TOPLEFT", 62, -182)
    u.sub:SetWidth(206)
    u.sub:SetWordWrap(false)

    u.verdictBadge = MakeBadge(f, 130, 22, 11)
    u.verdictBadge:SetPoint("TOPLEFT", 274, -158)
    u.riskBadge = MakeBadge(f, 130, 18, 9)
    u.riskBadge:SetPoint("TOPLEFT", 274, -184)

    ---------------- karty glowne ----------------
    u.card1 = MakeCard(f, 16, -208, 124, 62, "KUPUJ DO")
    u.card2 = MakeCard(f, 146, -208, 124, 62, "WYSTAW ZA")
    u.card3 = MakeCard(f, 276, -208, 124, 62, "ZYSK NETTO")

    ---------------- zakladki ----------------
    u.tabs = {}
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(96, 22)
        b:SetPoint("TOPLEFT", 16 + (i - 1) * 98, -278)
        b.key, b.label = t[1], t[2]
        b.text = MakeFS(b, 11, "CENTER")
        b.text:SetPoint("CENTER", 0, 0)
        b.line = b:CreateTexture(nil, "ARTWORK")
        b.line:SetColorTexture(0.2, 0.67, 1, 1)
        b.line:SetPoint("BOTTOMLEFT", 6, 0)
        b.line:SetPoint("BOTTOMRIGHT", -6, 0)
        b.line:SetHeight(2)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        b:SetScript("OnClick", function()
            db.hudTab = t[1]
            ns.UpdateUI()
        end)
        u.tabs[i] = b
    end
    local tabLine = f:CreateTexture(nil, "ARTWORK")
    tabLine:SetColorTexture(0.25, 0.27, 0.32, 1)
    tabLine:SetPoint("TOPLEFT", 16, -300)
    tabLine:SetSize(WIDTH - 32, 1)

    u.rows = MakeStatRows(f, STAT_ROWS, CONTENT_W, STAT_H, 16, -304)

    u.notes = MakeFS(f, 11)
    u.notes:SetPoint("TOPLEFT", 22, -310)
    u.notes:SetWidth(CONTENT_W - 12)
    u.notes:SetSpacing(2)
    u.notes:Hide()

    ---------------- wykres ----------------
    local chart = CreateFrame("Frame", nil, f, "BackdropTemplate")
    chart:SetSize(WIDTH - 32, 86)
    chart:SetPoint("BOTTOMLEFT", 16, 26)
    chart:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    chart:SetBackdropColor(0.02, 0.03, 0.04, 0.9)
    chart.pool = {}

    chart.empty = MakeFS(chart, 10, "CENTER")
    chart.empty:SetPoint("CENTER")
    chart.empty:SetText("|cff888888Wykres pojawi sie po zebraniu 2+ punktow (zapis co " .. db.histEveryMin .. " min)|r")

    chart.hi = MakeFS(chart, 10)
    chart.hi:SetPoint("TOPLEFT", 4, -3)
    chart.lo = MakeFS(chart, 10)
    chart.lo:SetPoint("BOTTOMLEFT", 4, 3)
    chart.xl = MakeFS(chart, 10, "RIGHT")
    chart.xl:SetPoint("BOTTOMRIGHT", -4, 3)
    chart.xl:SetTextColor(0.6, 0.6, 0.6)
    u.chart = chart

    -- klik = duzy wykres na srodku ekranu
    chart:EnableMouse(true)
    chart:SetScript("OnMouseUp", function(_, btn)
        if btn == "LeftButton" and ns.ToggleBigChart then ns.ToggleBigChart() end
    end)
    chart:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Kliknij, aby otworzyc duzy wykres", 1, 1, 1)
        GameTooltip:Show()
    end)
    chart:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local legend = MakeFS(f, 10)
    legend:SetPoint("BOTTOMLEFT", chart, "TOPLEFT", 0, 3)
    legend:SetText("|cff33e666--|r min   |cffffd100--|r rynek   |cffff4040--|r break-even   |cff4da6ff--|r alert")

    local footer = MakeFS(f, 10)
    footer:SetPoint("BOTTOMLEFT", 16, 8)
    footer:SetTextColor(0.55, 0.55, 0.55)
    u.footer = footer

    -- Shift+klik na przedmiot wstawia link do pola, gdy ma focus
    local function OnLink(link)
        if type(link) == "string" and itemBox:HasFocus() then
            itemBox:SetText(link)
        end
    end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnLink)
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", OnLink)
    end
    if HandleModifiedItemClick then
        hooksecurefunc("HandleModifiedItemClick", OnLink)
    end

    ns.Safe("minimap", ns.ApplyMinimap)

    if db.selected then ns.onSelect(db.selected) end
    ns.UpdateUI()
end

function ns.Toggle()
    local f = ns.frame
    if not f then return end
    local show = not f:IsShown()
    f:SetShown(show)
    ns.db.shown = show
end

table.insert(ns.TOGGLES, { key = "colorblind", label = "Tryb dla daltonistow (niebieski/pomaranczowy)",
    set = function(v)
        ns.db.colorblind = v
        if ns.UpdateUI then ns.UpdateUI() end
        if ns.UpdatePanel then ns.UpdatePanel() end
    end })