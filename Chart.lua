local ADDON, ns = ...

------------------------------------------------------------------
-- WYKRES: jeden silnik (ns.NewChart) dla duzego wykresu i miniwykresu w Liscie
-- Uklad bez nakladania: osie po lewej i na dole, ETYKIETY LINII (break-even, alert, mediana, TSM...) w osobnej
-- rynnie po prawej (rozsuwane, zeby sie nie zaslanialy), odczyt kursora w osobnym wierszu nad wykresem, legenda pod wykresem,
-- przyciski w rozwijanych menu (Zakres, Typ, Nakladki, Zrodlo) w jednym pasku nad wykresem.
-- Zrodlo danych (TSMA / Blizzard) wg db.chartBlizz (patrz Source.lua), zrodla nie sa mieszane.
------------------------------------------------------------------

local GRAY, GREEN, RED, BLUE, WHITE, ORANGE = "|cff9aa0a6", "|cff33dd66", "|cffff4040", "|cff33aaff", "|cffffffff", "|cffffa040"

local function PalLine()
    if ns.db and ns.db.colorblind then
        return { up = { 0.30, 0.65, 1.0 }, down = { 1.0, 0.55, 0.10 }, min = { 0.30, 0.65, 1.0 }, be = { 1.0, 0.55, 0.10 } }
    end
    return { up = { 0.2, 0.9, 0.4 }, down = { 1.0, 0.3, 0.3 }, min = { 0.2, 0.9, 0.4 }, be = { 1.0, 0.35, 0.35 } }
end

local function MoneyAxis(v)
    if v >= 10000 then
        return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r", math.floor(v / 10000), math.floor((v % 10000) / 100))
    end
    return ns.Money(v)
end

local function FlatButton(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.12, 0.13, 0.17, 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.text = ns.MakeFS(b, 11, "CENTER")
    b.text:SetPoint("CENTER", 0, 0)
    return b
end

local function Median(vals)
    local n = #vals
    if n == 0 then return nil end
    table.sort(vals)
    if n % 2 == 1 then return vals[(n + 1) / 2] end
    return (vals[n / 2] + vals[n / 2 + 1]) / 2
end

------------------------------------------------------------------
-- Dane: punkty {t, min, rynek, [4]=2 dla archiwum, [5]={min doby, max doby}}
------------------------------------------------------------------
local function Points(s)
    local db = ns.db
    local pts = {}
    if db.chartBlizz then
        for _, p in ipairs((db.blizzHist and db.blizzHist[s]) or {}) do
            pts[#pts + 1] = { p[1], p[2], p[3] or 0 }
        end
        return pts
    end
    local rec = db.items[s]
    local saved = (rec and rec.hist) or {}
    local first = saved[1] and saved[1][1] or math.huge
    local id = tonumber((s or ""):match("^i:(%d+)"))
    if id and db.arc and ns.ArchivePoints then
        for _, p in ipairs(ns.ArchivePoints(id) or {}) do
            if p[1] < first then pts[#pts + 1] = { p[1], p[2], 0, 2, { p[3], p[4] } } end
        end
    end
    for _, p in ipairs(saved) do pts[#pts + 1] = p end
    return pts
end

-- swiece dobowe: otwarcie, zamkniecie, max, min (punkty z archiwum maja prawdziwe min/max doby)
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

local function BuildCompare(s2, pts, t0)
    local m0
    for _, p in ipairs(pts) do
        if p[2] and p[2] > 0 then m0 = p[2]; break end
    end
    if not m0 then return nil end
    local list = {}
    for _, p in ipairs(Points(s2)) do
        if p[1] >= t0 and p[2] and p[2] > 0 then list[#list + 1] = p end
    end
    if #list < 2 then return nil end
    local ratio = m0 / list[1][2]
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = { p[1], p[2] * ratio } end
    return out
end

------------------------------------------------------------------
-- Rysowanie
------------------------------------------------------------------
local function GetLine(c, i)
    local l = c.pool[i]
    if not l then
        l = c:CreateLine(nil, "ARTWORK")
        c.pool[i] = l
    end
    l:Show()
    return l
end

local function GetLabel(c, i)
    local fs = c.labels[i]
    if not fs then
        fs = ns.MakeFS(c, c.o.mini and 9 or 10)
        c.labels[i] = fs
    end
    fs:ClearAllPoints()
    fs:SetWordWrap(false)
    fs:Show()
    return fs
end

local function Redraw(c)
    local db, st = ns.db, c.st
    for _, l in pairs(c.pool) do l:Hide() end
    for _, fs in pairs(c.labels) do fs:Hide() end
    c.cursor:Hide()
    c.dotMin:Hide()
    c.dotMkt:Hide()
    c.empty:Hide()
    c.readout:SetText("")
    c.legend:SetText("")
    c.geom = nil
    c.offscale = {}

    local function empty(msg)
        c.empty:SetText("|cff888888" .. msg .. "|r")
        c.empty:Show()
    end

    local s = c.item
    if not s then empty("Wybierz przedmiot"); return end
    local all = Points(s)
    if #all < 2 then
        if db.chartBlizz then
            empty(_G.TsmAnalizeBlizz and "Blizzard: za malo punktow (potrzeba 2+ eksportow AuctionEngine)"
                or "Brak danych Blizzarda (BlizzData.lua)")
        else
            empty("Za malo punktow w historii (zapis co " .. tostring(db.histEveryMin) .. " min)")
        end
        return
    end

    local now = time()
    local range = (st.range and st.range > 0) and st.range or nil
    local t0 = all[1][1]
    if range and now - range > t0 then t0 = now - range end
    if now <= t0 then empty("Za malo punktow w tym zakresie"); return end
    local pts = {}
    for _, p in ipairs(all) do
        if p[1] >= t0 then pts[#pts + 1] = p end
    end
    if #pts < 2 then empty("Za malo punktow w tym zakresie"); return end

    local PL = PalLine()
    local ov = st.ov or {}

    -- zakres serii (do oceny, ktore linie referencyjne mieszcza sie w skali)
    local slo, shi
    local function inc(v)
        if v and v > 0 then
            slo = slo and math.min(slo, v) or v
            shi = shi and math.max(shi, v) or v
        end
    end
    for _, p in ipairs(pts) do
        inc(p[2]); inc(p[3])
        if p[5] then inc(p[5][1]); inc(p[5][2]) end
    end
    if not slo then empty("Brak cen w tym zakresie"); return end

    -- nakladki
    local med, sma, cmp, cmpName
    if ov.median then
        local vals = {}
        for _, p in ipairs(pts) do
            if p[2] and p[2] > 0 then vals[#vals + 1] = p[2] end
        end
        med = Median(vals)
    end
    if ov.sma then
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
    if st.compare and st.compare ~= s then
        cmp = BuildCompare(st.compare, pts, t0)
        if cmp then cmpName = ns.ItemName(st.compare) end
    end

    -- linie poziome (etykiety w rynnie po prawej)
    local refs = {}
    local function addRef(v, name, r, g, b)
        if not v or v <= 0 then return end
        if v < slo * 0.4 or v > shi * 2.5 then
            c.offscale[#c.offscale + 1] = name
            return
        end
        refs[#refs + 1] = { v = v, name = name, r = r, g = g, b = b }
    end
    local d = ns.HasTSM() and (ns.cache[s] or ns.FetchTSM(s)) or nil
    if st.be ~= false and d then
        local ok, an = pcall(ns.Analyze, s, d, (ns.EffectiveBuy(s, d)))
        if ok and an and an.breakEven then addRef(an.breakEven, "break-even", PL.be[1], PL.be[2], PL.be[3]) end
    end
    if st.alert ~= false and db.alerts[s] then addRef(db.alerts[s], "alert", 0.4, 0.7, 1.0) end
    if med then addRef(med, "mediana", 0.8, 0.8, 0.8) end
    if ov.cost and db.buyPrice[s] then addRef(db.buyPrice[s], "moj zakup", 0.75, 0.55, 1.0) end
    if ov.ref and d then
        addRef(d.historical, "TSM 60d", 1.0, 0.6, 0.2)
        addRef(d.regionMarket, "TSM region", 0.6, 0.9, 1.0)
    end

    local lo, hi = slo, shi
    local function inc2(v)
        if v and v > 0 then lo = math.min(lo, v); hi = math.max(hi, v) end
    end
    for _, r in ipairs(refs) do inc2(r.v) end
    if sma then for _, p in ipairs(sma) do inc2(p[2]) end end
    if cmp then for _, p in ipairs(cmp) do inc2(p[2]) end end
    if hi == lo then hi = lo * 1.05 + 1; lo = lo * 0.95 end
    local m = (hi - lo) * 0.06
    lo = math.max(0, lo - m)
    hi = hi + m

    local w, ht = c:GetWidth(), c:GetHeight()
    local mini = c.o.mini
    local padL, padR, padT, padB = c.padL, c.gutter, 10, mini and 18 or 24
    local plotW, plotH = w - padL - padR, ht - padT - padB
    local function X(t) return padL + (t - t0) / (now - t0) * plotW end
    local function Y(v) return padB + (v - lo) / (hi - lo) * plotH end

    local idx, nl = 0, 0
    local function seg(x1, y1, x2, y2, r, g, b, a, th)
        idx = idx + 1
        local l = GetLine(c, idx)
        l:SetThickness(th or 1.5)
        l:SetColorTexture(r, g, b, a or 1)
        l:SetStartPoint("BOTTOMLEFT", c, x1, y1)
        l:SetEndPoint("BOTTOMLEFT", c, x2, y2)
    end
    local function label(x, y, point, text, r, g, b)
        nl = nl + 1
        local fs = GetLabel(c, nl)
        fs:SetPoint(point, c, "BOTTOMLEFT", x, y)
        fs:SetTextColor(r or 0.8, g or 0.8, b or 0.8)
        fs:SetText(text)
        return fs
    end

    -- siatka + osie
    local ny = mini and 3 or 5
    for i = 0, ny do
        local v = lo + (hi - lo) * i / ny
        local y = Y(v)
        seg(padL, y, padL + plotW, y, 0.4, 0.42, 0.48, 0.35, 1)
        local fs = label(padL - 6, y, "RIGHT", MoneyAxis(v))
        fs:SetJustifyH("RIGHT")
    end
    local fmt = (now - t0 <= 3 * 86400) and "%d.%m %H:%M" or "%d.%m"
    local nx = mini and 4 or 5
    for i = 0, nx do
        local t = t0 + (now - t0) * i / nx
        local x = X(t)
        seg(x, padB, x, padB + plotH, 0.4, 0.42, 0.48, 0.2, 1)
        local fs = label(x, padB - 4, "TOP", i == nx and "teraz" or date(fmt, t))
        fs:SetJustifyH("CENTER")
    end

    -- linie referencyjne
    for _, r in ipairs(refs) do
        seg(padL, Y(r.v), padL + plotW, Y(r.v), r.r, r.g, r.b, 0.85, 1.2)
    end

    -- serie
    local function series(k, r, g, b, th)
        local px, py
        for _, p in ipairs(pts) do
            local v = p[k]
            if v and v > 0 then
                local x, y = X(p[1]), Y(v)
                if px then seg(px, py, x, y, r, g, b, 0.95, th) end
                px, py = x, y
            else
                px, py = nil, nil
            end
        end
    end
    local mktName = db.chartBlizz and "mediana" or "rynek"
    series(3, 1.0, 0.82, 0.0, mini and 1.2 or 1.5)
    local candles
    if st.candles and not mini then
        candles = BuildCandles(pts)
        local bw = math.max(3, math.min(24, plotW / math.max(#candles, 1) * 0.5))
        for _, cd in ipairs(candles) do
            local x = X(cd.t)
            local col = (cd.c >= cd.o) and PL.up or PL.down
            seg(x, Y(cd.l), x, Y(cd.h), col[1], col[2], col[3], 1, 1)
            local yo, yc = Y(cd.o), Y(cd.c)
            if math.abs(yo - yc) < 2 then yo, yc = yo - 1, yc + 1 end
            seg(x, yo, x, yc, col[1], col[2], col[3], 1, bw)
        end
    else
        series(2, PL.min[1], PL.min[2], PL.min[3], mini and 1.5 or 2)
    end
    if sma then
        local px, py
        for _, p in ipairs(sma) do
            local x, y = X(p[1]), Y(p[2])
            if px then seg(px, py, x, y, 0.3, 0.95, 0.95, 0.95, 1.5) end
            px, py = x, y
        end
    end
    local cmpLabel
    if cmp then
        local px, py
        for _, p in ipairs(cmp) do
            local x, y = X(p[1]), Y(p[2])
            if px then seg(px, py, x, y, 1.0, 0.45, 0.9, 0.95, 1.5) end
            px, py = x, y
        end
        cmpLabel = { v = cmp[#cmp][2], name = (cmpName or "?") .. " (norm.)", r = 1, g = 0.55, b = 0.9 }
        refs[#refs + 1] = cmpLabel
    end

    -- etykiety linii w rynnie po prawej, rozsuniete tak, zeby sie nie zaslanialy
    local labs = {}
    for _, r in ipairs(refs) do
        labs[#labs + 1] = { y = Y(r.v), ly = Y(r.v), r = r, isCmp = (r == cmpLabel) }
    end
    table.sort(labs, function(a, b) return a.y > b.y end)
    local GAP = 13
    for i = 2, #labs do
        if labs[i - 1].ly - labs[i].ly < GAP then labs[i].ly = labs[i - 1].ly - GAP end
    end
    if #labs > 0 and labs[#labs].ly < 8 then labs[#labs].ly = 8 end
    for i = #labs - 1, 1, -1 do
        if labs[i].ly - labs[i + 1].ly < GAP then labs[i].ly = labs[i + 1].ly + GAP end
    end
    local gx = padL + plotW
    for _, lb in ipairs(labs) do
        local r = lb.r
        if math.abs(lb.ly - lb.y) > 1 then seg(gx, lb.y, gx + 5, lb.ly, r.r, r.g, r.b, 0.8, 1) end
        local fs = label(gx + 7, lb.ly, "LEFT", r.name .. " " .. ns.MoneyPlain(r.v), r.r, r.g, r.b)
        fs:SetJustifyH("LEFT")
        fs:SetWidth(c.gutter - 8)
    end

    -- legenda pod wykresem (tylko aktywne serie)
    local lg = {}
    if candles then
        lg[#lg + 1] = (db.colorblind and "|cff4da6ff" or "|cff33e666") .. "-|r wzrost doby  " .. (db.colorblind and "|cffff8c1a" or "|cffff4040") .. "-|r spadek"
    else
        lg[#lg + 1] = "|cff33e666-|r min"
    end
    lg[#lg + 1] = "|cffffd100-|r " .. mktName
    if sma then lg[#lg + 1] = "|cff4de6e6-|r srednia 24h" end
    if cmp then lg[#lg + 1] = "|cffff73e6-|r porownanie" end
    local txt = table.concat(lg, "   ")
    if #c.offscale > 0 then
        txt = txt .. "   " .. GRAY .. "poza skala: " .. table.concat(c.offscale, ", ") .. "|r"
    end
    if db.chartBlizz then txt = txt .. "   " .. BLUE .. "zrodlo: Blizzard|r" end
    c.legend:SetText(txt)

    c.geom = { X = X, Y = Y, pts = pts, candles = candles, padL = padL, padB = padB, plotW = plotW, plotH = plotH,
        mkt = mktName }
end

-- kursor: pionowa linia, punkty na seriach i odczyt w osobnym wierszu nad wykresem
local function Hover(c)
    local g = c.geom
    local function off()
        c.cursor:Hide()
        c.dotMin:Hide()
        c.dotMkt:Hide()
        if c.readout:GetText() ~= "" then c.readout:SetText("") end
    end
    if not g or not c:IsMouseOver() then off(); return end
    local cx = GetCursorPosition()
    local x = cx / c:GetEffectiveScale() - c:GetLeft()
    if x < g.padL or x > g.padL + g.plotW then off(); return end

    local function vline(px)
        c.cursor:SetStartPoint("BOTTOMLEFT", c, px, g.padB)
        c.cursor:SetEndPoint("BOTTOMLEFT", c, px, g.padB + g.plotH)
        c.cursor:Show()
    end

    if g.candles and #g.candles > 0 then
        local best, bd
        for _, cd in ipairs(g.candles) do
            local dd = math.abs(g.X(cd.t) - x)
            if not bd or dd < bd then best, bd = cd, dd end
        end
        vline(g.X(best.t))
        c.dotMin:Hide()
        c.dotMkt:Hide()
        c.readout:SetText(string.format("%s    otw.%s %s    max %s    min %s    zamk. %s",
            date("%d.%m.%Y", best.t), best.syn and "~" or "", ns.Money(best.o), ns.Money(best.h),
            ns.Money(best.l), ns.Money(best.c)))
        return
    end

    local best, bd
    for _, p in ipairs(g.pts) do
        local dd = math.abs(g.X(p[1]) - x)
        if not bd or dd < bd then best, bd = p, dd end
    end
    if not best then off(); return end
    local px = g.X(best[1])
    vline(px)
    local function dot(tex, v)
        if v and v > 0 then
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", c, "BOTTOMLEFT", px, g.Y(v))
            tex:Show()
        else
            tex:Hide()
        end
    end
    dot(c.dotMin, best[2])
    dot(c.dotMkt, best[3])
    c.readout:SetText(string.format("%s    |cff33e666min|r %s    |cffffd100%s|r %s",
        date("%d.%m.%Y %H:%M", best[1]),
        (best[2] and best[2] > 0) and ns.Money(best[2]) or "--", g.mkt,
        (best[3] and best[3] > 0) and ns.Money(best[3]) or "--"))
end

-- o = { padL, gutter, mini, st = { range, candles, be, alert, ov = {median, sma, cost, ref}, compare } }
function ns.NewChart(parent, w, h, o)
    o = o or {}
    local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    c:SetSize(w, h)
    c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    c:SetBackdropColor(0.02, 0.03, 0.04, 0.92)
    c.o = o
    c.st = o.st or { range = 7 * 86400, ov = {} }
    c.st.ov = c.st.ov or {}
    c.padL = o.padL or 76
    c.gutter = o.gutter or 128
    c.pool, c.labels, c.offscale = {}, {}, {}

    c.empty = ns.MakeFS(c, 12, "CENTER")
    c.empty:SetPoint("CENTER")
    c.readout = ns.MakeFS(c, o.mini and 10 or 12)
    c.readout:SetPoint("BOTTOMLEFT", c, "TOPLEFT", c.padL, 3)
    c.readout:SetWordWrap(false)
    c.legend = ns.MakeFS(c, 10)
    c.legend:SetPoint("TOPLEFT", c, "BOTTOMLEFT", c.padL, -4)
    c.legend:SetWidth(w - c.padL)
    c.legend:SetWordWrap(false)

    c.cursor = c:CreateLine(nil, "OVERLAY")
    c.cursor:SetThickness(1)
    c.cursor:SetColorTexture(1, 1, 1, 0.45)
    c.cursor:Hide()
    c.dotMin = c:CreateTexture(nil, "OVERLAY")
    c.dotMin:SetSize(8, 8)
    c.dotMin:SetColorTexture(0.2, 0.9, 0.4, 1)
    c.dotMin:Hide()
    c.dotMkt = c:CreateTexture(nil, "OVERLAY")
    c.dotMkt:SetSize(8, 8)
    c.dotMkt:SetColorTexture(1, 0.82, 0, 1)
    c.dotMkt:Hide()
    c:EnableMouse(true)
    c:SetScript("OnUpdate", Hover)

    function c:SetItem(s) self.item = s end
    function c:Redraw() Redraw(self) end
    return c
end

------------------------------------------------------------------
-- Rozwijane menu (Zakres, Typ, Nakladki, Zrodlo)
------------------------------------------------------------------
-- items: { text, check = function() -> bool, click = function(), keepOpen } albo { edit = true, apply = function(txt) }
local function Dropdown(parent, x, y, w, title, valueText, items, onChange)
    local btn = FlatButton(parent, w, 24)
    btn:SetPoint("TOPLEFT", x, y)
    function btn.Update() btn.text:SetText(title .. ": " .. valueText() .. "  v") end

    local PW = math.max(w, 230)
    local pop = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pop:SetFrameStrata("FULLSCREEN_DIALOG")
    pop:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    ns.DarkBackdrop(pop, 0.99)
    pop:Hide()
    pop.rows = {}
    local y0 = -4
    for _, it in ipairs(items) do
        if it.edit then
            local lbl = ns.MakeFS(pop, 10)
            lbl:SetPoint("TOPLEFT", 10, y0 - 4)
            lbl:SetText(GRAY .. "Porownaj z (ID / link):|r")
            local eb = ns.MakeInput(pop, PW - 60)
            eb:SetPoint("TOPLEFT", 16, y0 - 18)
            eb:SetScript("OnEnterPressed", function(self)
                self:ClearFocus()
                it.apply(self:GetText())
                pop:Hide()
            end)
            local clr = ns.MakeButton(pop, "x", 24, 20)
            clr:SetPoint("LEFT", eb, "RIGHT", 6, 0)
            clr:SetScript("OnClick", function() eb:SetText(""); it.apply("") end)
            pop.edit = eb
            y0 = y0 - 48
        else
            local r = FlatButton(pop, PW - 8, 22)
            r:SetPoint("TOPLEFT", 4, y0)
            r.text:ClearAllPoints()
            r.text:SetPoint("LEFT", 8, 0)
            r.text:SetJustifyH("LEFT")
            r.it = it
            r:SetScript("OnClick", function()
                it.click()
                if not it.keepOpen then pop:Hide() end
                if onChange then onChange() end
            end)
            pop.rows[#pop.rows + 1] = r
            y0 = y0 - 22
        end
    end
    pop:SetSize(PW, -y0 + 4)

    function pop.Refresh()
        for _, r in ipairs(pop.rows) do
            local it = r.it
            local mark = it.check and (it.check() and (GREEN .. "[x]|r ") or "[ ] ") or ""
            r.text:SetText(mark .. it.text)
        end
    end
    btn:SetScript("OnClick", function()
        if pop:IsShown() then pop:Hide() else pop.Refresh(); pop:Show() end
    end)
    pop:SetScript("OnShow", function() pop.Refresh() end)
    pop:SetScript("OnUpdate", function(self, el)
        if pop.edit and pop.edit:HasFocus() then self.t = 0; return end
        if self:IsMouseOver() or btn:IsMouseOver() then
            self.t = 0
        else
            self.t = (self.t or 0) + (el or 0)
            if self.t > 0.5 then self:Hide() end
        end
    end)
    btn.pop = pop
    return btn
end

------------------------------------------------------------------
-- Duzy wykres
------------------------------------------------------------------
local RANGES = { { "24 godziny", 86400 }, { "3 dni", 3 * 86400 }, { "7 dni", 7 * 86400 }, { "30 dni", 30 * 86400 }, { "Wszystko", 0 } }

local function RangeName(v)
    for _, r in ipairs(RANGES) do
        if r[2] == (v or 0) then return r[1] end
    end
    return "Wszystko"
end

local function TrendWord(hs)
    if not hs.trend then return "--" end
    local col, word = GRAY, "stabilny"
    if hs.trend > 1 then col, word = GREEN, "rosnie" elseif hs.trend < -1 then col, word = RED, "spada" end
    return string.format("%s%s %+.1f%%/d|r", col, word, hs.trend)
end

local function BuildBig()
    local W, H = 980, 600
    local db = ns.db
    db.bigSt = db.bigSt or {}
    local st = db.bigSt
    if st.range == nil then st.range = 7 * 86400 end
    if st.be == nil then st.be = true end
    if st.alert == nil then st.alert = true end
    st.ov = st.ov or {}

    local f = CreateFrame("Frame", "TsmAnalizeBigChart", UIParent, "BackdropTemplate")
    ns.bigChart = f
    f:SetSize(W, H)
    local cp = db.chartPos
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
        db.chartPos = { p, rp, x, y }
    end)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeBigChart") end

    -- naglowek: ikona + nazwa
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(24, 24)
    f.icon:SetPoint("TOPLEFT", 14, -8)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.title = ns.MakeFS(f, 16)
    f.title:SetPoint("TOPLEFT", 46, -11)
    f.title:SetWidth(W - 120)
    f.title:SetWordWrap(false)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local chart = ns.NewChart(f, W - 24, H - 104 - 46, { padL = 84, gutter = 132, st = st })
    chart:SetPoint("TOPLEFT", 12, -104)
    f.chart = chart

    local function Update() ns.UpdateBigChart() end

    -- pasek rozwijanych menu
    local dds = {}
    dds[1] = Dropdown(f, 14, -38, 170, "Zakres", function() return RangeName(st.range) end, (function()
        local items = {}
        for _, r in ipairs(RANGES) do
            items[#items + 1] = { text = r[1], check = function() return (st.range or 0) == r[2] end,
                click = function() st.range = r[2] end }
        end
        return items
    end)(), Update)
    dds[2] = Dropdown(f, 190, -38, 150, "Typ", function() return st.candles and "Swiece" or "Linia" end, {
        { text = "Linia", check = function() return not st.candles end, click = function() st.candles = false end },
        { text = "Swiece dobowe", check = function() return st.candles and true or false end, click = function() st.candles = true end },
    }, Update)
    dds[3] = Dropdown(f, 346, -38, 150, "Nakladki", function()
        local n = 0
        for _, k in ipairs({ "median", "sma", "cost", "ref" }) do
            if st.ov[k] then n = n + 1 end
        end
        if st.compare then n = n + 1 end
        return n > 0 and (n .. " wl.") or "brak"
    end, {
        { text = "Break-even", keepOpen = true, check = function() return st.be ~= false end, click = function() st.be = (st.be == false) end },
        { text = "Alert (prog ceny)", keepOpen = true, check = function() return st.alert ~= false end, click = function() st.alert = (st.alert == false) end },
        { text = "Mediana zakresu", keepOpen = true, check = function() return st.ov.median and true or false end, click = function() st.ov.median = not st.ov.median end },
        { text = "Srednia ruchoma 24h", keepOpen = true, check = function() return st.ov.sma and true or false end, click = function() st.ov.sma = not st.ov.sma end },
        { text = "Moj zakup", keepOpen = true, check = function() return st.ov.cost and true or false end, click = function() st.ov.cost = not st.ov.cost end },
        { text = "Ref. TSM (60d i region)", keepOpen = true, check = function() return st.ov.ref and true or false end, click = function() st.ov.ref = not st.ov.ref end },
        { edit = true, apply = function(txt)
            txt = txt or ""
            st.compare = (txt ~= "") and ns.ResolveItem(txt) or nil
            if txt ~= "" and not st.compare then ns.Print("Nie rozpoznano przedmiotu do porownania.") end
            Update()
        end },
    }, Update)
    dds[4] = Dropdown(f, 502, -38, 190, "Zrodlo", function() return (db.chartBlizz and "Blizzard") or "TSMA" end, {
        { text = "TSMA (TSM + archiwum)", check = function() return not db.chartBlizz end, click = function() ns.SetChartSource(false) end },
        { text = "Blizzard (AuctionEngine)", check = function() return db.chartBlizz and true or false end, click = function() ns.SetChartSource(true) end },
    }, nil)
    f.dds = dds

    f.stats = ns.MakeFS(f, 11)
    f.stats:SetPoint("TOPLEFT", 14, -70)
    f.stats:SetWidth(W - 28)
    f.stats:SetWordWrap(false)

    local hint = ns.MakeFS(f, 10)
    hint:SetPoint("BOTTOMLEFT", 14, 8)
    hint:SetText(GRAY .. "Menu u gory: zakres, typ, nakladki, zrodlo. Najedz kursorem na wykres, zeby zobaczyc wartosci. Esc = zamknij.|r")
end

function ns.UpdateBigChart()
    local f = ns.bigChart
    if not (f and f:IsShown()) then return end
    local db = ns.db
    local st = db.bigSt
    local s = db.selected
    for _, b in ipairs(f.dds) do b.Update() end

    f.chart.st = st
    f.chart:SetItem(s)
    if not s then
        f.title:SetText("Brak wybranego przedmiotu")
        f.icon:SetTexture(134400)
        f.stats:SetText("")
        f.chart:Redraw()
        return
    end
    f.title:SetText(ns.ItemName(s))
    f.icon:SetTexture(ns.ItemIcon(s))
    f.chart:Redraw()

    local base
    if db.chartBlizz then
        base = (ns.BlizzStats and ns.BlizzStats(s, (st.range and st.range > 0) and st.range or nil)) or ""
    else
        local hs = ns.HistStats(s)
        if hs then
            base = string.format("Zakres %dd (%d pkt): %s / %s / %s   mediana %s   zmienn. %.0f%%   trend %s",
                db.histDays, hs.n, ns.Money(hs.min), ns.Money(hs.avg), ns.Money(hs.max), ns.Money(hs.median),
                hs.stdevPct, TrendWord(hs))
        else
            base = "|cff888888Zbieram dane...|r"
        end
        local g = f.chart.geom
        if g and #g.pts >= 2 then
            local first, last
            for _, p in ipairs(g.pts) do
                if p[2] and p[2] > 0 then first = first or p[2]; last = p[2] end
            end
            if first and last and first > 0 then
                local ch = (last / first - 1) * 100
                base = base .. string.format("   zmiana w zakresie %s%+.1f%%|r", ch >= 0 and GREEN or RED, ch)
            end
        end
    end
    f.stats:SetText(base)
end

function ns.ToggleBigChart()
    if not ns.bigChart then BuildBig() end
    local f = ns.bigChart
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        ns.UpdateBigChart()
    end
end
