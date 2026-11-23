local ADDON, ns = ...

------------------------------------------------------------------
-- ZAKLADKA "HUB" W DOMU AUKCYJNYM (obok Buy / Sell / Auctions / TSM)
--  * lewa kolumna: wyszukiwarka jak w AH (nazwa albo ID), lista wynikow (cena min, ilosc)
--  * klik w przedmiot: addon sam wysyla zapytanie do AH i pobiera zywe oferty
--  * prawa strona: wykres (TSMA / Blizzard wg ustawien), aktualna cena, drabina ofert z pozycja TWOJEJ ceny
--    (ile sztuk jest PRZED Toba = taniej, ile ZA Toba = drozej), pelna analiza ryzyka dla wpisanej ceny i ilosci
-- Wymaga: Widgets.lua, Chart.lua (ns.NewChart), Core.lua. Dodaj do .toc po Focus.lua.
------------------------------------------------------------------

local GRAY, GREEN, RED, BLUE, YELLOW, ORANGE = "|cff9aa0a6", "|cff33dd66", "|cffff4040", "|cff33aaff", "|cffffcc33", "|cffffa040"
local LEFT_W, ROW_H, LAD = 252, 30, 7

local panel, tabBtn
local rows = {}
local lad = {}
local S = { results = {}, offset = 0, cur = nil, price = nil, qty = 1, boxDirty = true, status = "" }
local live = {}
local lastSend = 0
local hooked = {}
local NROWS = 12

local function AH() return _G.C_AuctionHouse end
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function PriceSort()
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    return {}
end

local function KeyInfo(key)
    local A = AH()
    if not (A and A.GetItemKeyInfo and key) then return nil end
    local ok, info = pcall(A.GetItemKeyInfo, key)
    if ok and type(info) == "table" then return info end
    return nil
end

local function Label(parent, x, y, text, size, w, justify)
    local fs = ns.MakeFS(parent, size or 10, justify)
    fs:SetPoint("TOPLEFT", x, y)
    if w then fs:SetWidth(w) end
    fs:SetWordWrap(false)
    fs:SetText(text or "")
    return fs
end

------------------------------------------------------------------
-- Zywe oferty
------------------------------------------------------------------
local function Ingest(id, list, commodity)
    table.sort(list, function(a, b) return a.price < b.price end)
    local merged, last, total = {}, nil, 0
    for _, r in ipairs(list) do
        total = total + r.qty
        if last and last.price == r.price then
            last.qty = last.qty + r.qty
            last.own = last.own or r.own
        else
            last = { price = r.price, qty = r.qty, own = r.own }
            merged[#merged + 1] = last
        end
    end
    local real, typical, cum = nil, nil, 0
    local target = math.max(1, total * 0.2)
    for _, m in ipairs(merged) do
        if not m.own and not real then real = m.price end
        cum = cum + m.qty
        if not typical and cum >= target then typical = m.price end
    end
    live[id] = { t = time(), rows = merged, total = total, real = real, typical = typical, commodity = commodity }
end

local function OnCommodity(id)
    local A = AH()
    if not (A and A.GetNumCommoditySearchResults and id) then return end
    local n = A.GetNumCommoditySearchResults(id) or 0
    local list = {}
    for i = 1, math.min(n, 500) do
        local r = A.GetCommoditySearchResultInfo(id, i)
        if r and r.unitPrice then
            list[#list + 1] = { price = r.unitPrice, qty = r.quantity or 1,
                own = (r.containsOwnerItem or (r.numOwnerItems or 0) > 0) and true or false }
        end
    end
    Ingest(id, list, true)
end

local function OnItemResults(key)
    local A = AH()
    local id = key and key.itemID
    if not (A and A.GetNumItemSearchResults and id) then return end
    local n = A.GetNumItemSearchResults(key) or 0
    local list = {}
    for i = 1, math.min(n, 500) do
        local r = A.GetItemSearchResultInfo(key, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 then
            local q = r.quantity or 1
            list[#list + 1] = { price = math.floor(r.buyoutAmount / q), qty = q, own = r.containsOwnerItem and true or false }
        end
    end
    Ingest(id, list, false)
end

local function Request(force)
    local c, A = S.cur, AH()
    if not (c and A and A.SendSearchQuery) then return end
    local lv = live[c.id]
    if not force and lv and time() - lv.t < 30 then return end
    local now = GetTime()
    if now - lastSend < 1.2 then
        C_Timer.After(1.3, function() if S.cur == c then Request(force) end end)
        return
    end
    lastSend = now
    S.searching = true
    pcall(A.SendSearchQuery, c.key, PriceSort(), true)
end

------------------------------------------------------------------
-- Wyszukiwanie (jak w AH) i wybor przedmiotu
------------------------------------------------------------------
local Refresh, RefreshList

local function Pick(key)
    if not (key and key.itemID) then return end
    S.cur = { key = key, id = key.itemID, s = "i:" .. key.itemID }
    S.price, S.boxDirty, S.qty = nil, true, 1
    S.searching = false
    if ns.Select then ns.Select(S.cur.s) end   -- HUD i reszta addonu widza ten sam przedmiot
    Request(true)
    Refresh()
end

local function DoSearch(text)
    text = trim(text)
    local A = AH()
    if text == "" or not A then return end
    local id = tonumber(text) or tonumber(text:match("item:(%d+)"))
    if id and A.MakeItemKey then
        Pick(A.MakeItemKey(id))
        return
    end
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Name then
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }
    end
    S.status, S.offset = "Szukam...", 0
    local ok, err = pcall(A.SendBrowseQuery, { searchString = text, sorts = sorts, filters = {}, itemClassFilters = {} })
    if not ok then S.status = RED .. "Blad zapytania: " .. tostring(err) .. "|r" end
    RefreshList()
end

local function OnBrowse()
    local A = AH()
    if not (A and A.GetBrowseResults) then return end
    local ok, list = pcall(A.GetBrowseResults)
    if ok and type(list) == "table" then S.results = list end
    S.status = (#S.results == 0) and "Brak wynikow." or (#S.results .. " wynikow" ..
        ((A.HasFullBrowseResults and not A.HasFullBrowseResults()) and " (przewin, zeby wczytac wiecej)" or ""))
    RefreshList()
end

------------------------------------------------------------------
-- Rysowanie listy wynikow
------------------------------------------------------------------
function RefreshList()
    if not (panel and panel:IsShown()) then return end
    panel.status:SetText(GRAY .. (S.status or "") .. "|r")
    S.offset = math.min(S.offset, math.max(0, #S.results - NROWS))
    for i = 1, NROWS do
        local row, res = rows[i], S.results[S.offset + i]
        row.res = res
        if res and res.itemKey then
            local key = res.itemKey
            local s = "i:" .. key.itemID
            local info = KeyInfo(key)
            row:Show()
            row.icon:SetTexture((info and info.iconFileID) or ns.ItemIcon(s))
            row.name:SetText((info and info.itemName) or ns.ItemName(s))
            row.sub:SetText(GRAY .. "od |r" .. ns.Money(res.minPrice) .. GRAY .. "   x" .. tostring(res.totalQuantity or 0) .. "|r")
            row.sel:SetShown(S.cur and S.cur.id == key.itemID or false)
        else
            row:Hide()
        end
    end
end

------------------------------------------------------------------
-- Analiza ryzyka dla wpisanej ceny i ilosci
------------------------------------------------------------------
local function RiskText(s, d, price, qty, lv)
    if not ns.HasTSM() then return GRAY .. "TSM nie wykryte - brak analizy ryzyka.|r" end
    local ok, r = pcall(ns.Analyze, s, d, (ns.EffectiveBuy(s, d)))
    if not ok or type(r) ~= "table" or r.verdict == "NODATA" or not r.risk then
        return GRAY .. "Brak danych TSM do analizy ryzyka.|r"
    end
    local db = ns.db
    local rk = r.risk
    local keep = 1 - ns.Cut() / 100
    local L = {}
    local function add(t) L[#L + 1] = t end

    add("Ocena: " .. ns.VERDICT_SHORT[r.verdict] .. "   ryzyko " .. ns.RISK_TEXT[rk.level] .. string.format(" (%d/100)", rk.score))
    local pc = (rk.p >= 0.7 and GREEN) or (rk.p >= 0.5 and YELLOW) or RED
    add("Szansa sprzedazy: " .. pc .. string.format("%.0f%%|r", rk.p * 100) ..
        (rk.pLo and (GRAY .. string.format("  (%.0f-%.0f%%, %s)|r", rk.pLo * 100, rk.pHi * 100, rk.pSrc or "")) or ""))

    if price and price > 0 then
        local recv = price * qty * keep
        add(string.format("Dostaniesz po prowizji (%s%%): %s", tostring(ns.Cut()), ns.MoneyPlain(recv)))
        add("Depozyt: " .. ns.MoneyPlain((r.deposit or 0) * qty) .. GRAY .. " (tracisz, gdy aukcja wygasnie)|r")
        if r.buyIsOwn and r.buy then
            local net = price * keep - r.buy
            add(string.format("Zysk vs Twoj zakup: %s%s|r  (%+.0f%%)  razem %s", net >= 0 and GREEN or RED,
                ns.MoneyPlain(net), net / r.buy * 100, ns.MoneyPlain(net * qty)))
        else
            add(GRAY .. "Zysk: brak ceny zakupu (wpisz ja w HUD).|r")
        end
        if r.sellRef and r.sellRef > 0 then
            local diff = (price / r.sellRef - 1) * 100
            add(string.format("Twoja cena vs ref. (%s): %+.0f%%", ns.MoneyPlain(r.sellRef), diff))
        end
        if r.breakEven and price < r.breakEven then
            add(RED .. "UWAGA: cena PONIZEJ break-even (" .. ns.MoneyPlain(r.breakEven) .. ")|r")
        elseif r.minList and price < r.minList then
            add(ORANGE .. "Cena ponizej progu min. zysku (" .. ns.MoneyPlain(r.minList) .. ")|r")
        end
        if d.minbuy and price < d.minbuy * 0.5 then
            add(ORANGE .. "Cena to <50% aktualnej min - literowka?|r")
        end
    end

    local perDay = d.perDay and (d.perDay / (db.perDayDiv or 1))
    if perDay and perDay > 0 then
        local days = qty / (perDay * (db.riskShare or 0.5))
        local txt = (days < 1) and string.format("~%.0f h", days * 24) or string.format("~%.1f dnia", days)
        local col = (days > 4 and RED) or (days > 2 and YELLOW) or GREEN
        add(string.format("Czas sprzedazy %d szt.: %s%s|r  (rynek ~%.1f szt./dzien)", qty, col, txt, perDay))
    else
        add(ORANGE .. "Tempo sprzedazy: brak danych z TSM|r")
    end

    local x = rk.extra
    if x and x.buffer then
        local bc = (x.bufferSigma < 1 and RED) or (x.bufferSigma < 2 and YELLOW) or GREEN
        add(string.format("Bufor spadku: %s%.0f%% = %.1fx zmiennosci|r", bc, x.buffer, x.bufferSigma))
    end
    if lv and lv.real and r.sellRef and lv.real > r.sellRef * 1.25 then
        add(ORANGE .. "Rynek jest 25%+ nad ref. - mozliwy chwilowy skok.|r")
    end
    if rk.why and #rk.why > 0 then
        local top = {}
        for i = 1, math.min(3, #rk.why) do top[#top + 1] = rk.why[i] end
        add(GRAY .. "Skladniki: " .. table.concat(top, "; ") .. ".|r")
    end
    if r.notes and r.notes[1] then add(GRAY .. r.notes[1] .. "|r") end
    return table.concat(L, "\n")
end

------------------------------------------------------------------
-- Prawa strona: naglowek, wykres, drabina ofert, pozycja Twojej ceny, ryzyko
------------------------------------------------------------------
local function Clear()
    panel.name:SetText(GRAY .. "Wyszukaj i wybierz przedmiot z listy po lewej.|r")
    panel.stats:SetText("")
    panel.icon:SetTexture(134400)
    panel.chart:SetItem(nil)
    panel.chart:Redraw()
    panel.ba:SetText("")
    panel.risk:SetText("")
    for _, l in ipairs(lad) do l.price:SetText(""); l.qty:SetText(""); l.note:SetText("") end
    panel.ladNote:SetText("")
end

function Refresh()
    RefreshList()
    if not (panel and panel:IsShown()) then return end
    local c = S.cur
    if not c then Clear(); return end
    local s, id = c.s, c.id
    local db = ns.db
    local d = ns.cache[s] or ns.FetchTSM(s)
    local lv = live[id]

    panel.icon:SetTexture(ns.ItemIcon(s))
    panel.name:SetText(ns.ItemName(s))

    local statsTxt
    if lv then
        local real = lv.real or (lv.rows[1] and lv.rows[1].price)
        statsTxt = GRAY .. "Teraz najtaniej: |r" .. ns.Money(real) .. GRAY .. "   poziomow: " .. #lv.rows ..
            "   sztuk: " .. lv.total .. "   (z AH " .. math.max(0, time() - lv.t) .. " s temu)|r"
    elseif S.searching then
        statsTxt = ORANGE .. "Pobieram oferty z AH...|r"
    else
        statsTxt = GRAY .. "Min wg TSM: |r" .. ns.Money(d.minbuy) .. GRAY .. "  (kliknij Odswiez, zeby pobrac zywe oferty)|r"
    end
    panel.stats:SetText(statsTxt)

    -- wykres
    panel.chart.st = db.ahSt
    panel.chart:SetItem(s)
    panel.chart:Redraw()
    for _, b in ipairs(panel.rangeBtns) do ns.SetActive(b, (db.ahSt.range or 0) == b.range) end

    -- cena domyslna: podbicie najtanszej realnej oferty
    local anchor = (lv and lv.real) or d.minbuy
    local under = math.max(0, db.undercut or 1)
    local presets = nil
    if anchor then
        local fast = math.max(1, anchor - under)
        local typical = (lv and lv.typical) or d.market or anchor
        if typical < fast then typical = fast end
        local patient = math.max(typical + 1, math.floor(typical * 1.10 + 0.5))
        presets = { fast = fast, typical = typical, patient = patient }
    end
    panel.presets = presets
    if S.boxDirty then
        local pv = S.price or (presets and presets.fast)
        panel.priceBox:SetText(pv and ns.MoneyPlain(pv) or "")
        panel.priceBox:SetCursorPosition(0)
        panel.qtyBox:SetText(tostring(S.qty or 1))
        S.boxDirty = false
    end
    local price = S.price or (presets and presets.fast)
    local qty = math.max(1, S.qty or 1)
    for _, b in ipairs(panel.presetBtns) do
        b.text:SetText(b.label .. (presets and (" " .. ns.MoneyPlain(presets[b.key])) or ""))
        ns.SetActive(b, presets and price and presets[b.key] == price or false)
    end

    -- drabina + pozycja Twojej ceny
    if lv and price then
        local before, after, same, nBefore, nAfter = 0, 0, 0, 0, 0
        local entries, markerAt = {}, nil
        for _, m in ipairs(lv.rows) do
            if m.price < price then before, nBefore = before + m.qty, nBefore + 1
            elseif m.price == price then same = same + m.qty
            else after, nAfter = after + m.qty, nAfter + 1 end
            if not markerAt and m.price >= price then
                entries[#entries + 1] = { mine = true }
                markerAt = #entries
            end
            entries[#entries + 1] = m
        end
        if not markerAt then entries[#entries + 1] = { mine = true }; markerAt = #entries end
        local start = math.max(1, math.min(markerAt - 3, #entries - LAD + 1))
        start = math.max(1, start)
        for i = 1, LAD do
            local e, l = entries[start + i - 1], lad[i]
            if not e then
                l.price:SetText(""); l.qty:SetText(""); l.note:SetText("")
            elseif e.mine then
                l.price:SetText(GREEN .. ns.MoneyPlain(price) .. "|r")
                l.qty:SetText(GREEN .. qty .. "|r")
                l.note:SetText(GREEN .. "<< TWOJA OFERTA|r")
            else
                l.price:SetText(ns.Money(e.price))
                l.qty:SetText(tostring(e.qty))
                l.note:SetText(e.own and (ORANGE .. "Twoja aukcja|r") or "")
            end
        end
        panel.ladNote:SetText(start > 1 and (GRAY .. "(od oferty #" .. start .. ")|r") or "")
        local share = lv.total > 0 and (qty / (lv.total + qty) * 100) or 0
        panel.ba:SetText(string.format(
            "%sPrzed Toba (taniej):|r %d szt. w %d ofertach\n%sTyle samo:|r %d szt.\n%sZa Toba (drozej):|r %d szt. w %d ofertach\n%sTwoja pozycja:|r #%d z %d poziomow   %sudzial w podazy ~%.0f%%|r",
            GRAY, before, nBefore, GRAY, same, GRAY, after, nAfter, GRAY, nBefore + 1, #lv.rows + 1, GRAY, share))
    else
        for _, l in ipairs(lad) do l.price:SetText(""); l.qty:SetText(""); l.note:SetText("") end
        panel.ladNote:SetText("")
        panel.ba:SetText(GRAY .. "Brak zywych ofert - kliknij Odswiez (AH musi byc otwarty).|r")
    end

    panel.risk:SetText(RiskText(s, d, price, qty, lv))
end

------------------------------------------------------------------
-- Budowa panelu
------------------------------------------------------------------
local function BuildPanel()
    local f = _G.AuctionHouseFrame
    local db = ns.db
    db.ahSt = db.ahSt or { range = 7 * 86400, be = true, alert = true, ov = {} }
    db.ahSt.ov = db.ahSt.ov or {}

    local W, H = f:GetWidth() - 8, f:GetHeight() - 54
    panel = CreateFrame("Frame", "TsmAnalizeAHTab", f, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -26)
    panel:SetSize(W, H)
    panel:SetFrameStrata(f:GetFrameStrata())
    panel:SetFrameLevel(f:GetFrameLevel() + 60)
    ns.DarkBackdrop(panel, 1)
    panel:EnableMouse(true)
    panel:EnableMouseWheel(true)
    panel:Hide()

    ------- lewa kolumna
    Label(panel, 12, -8, BLUE .. "HUB|r  " .. GRAY .. "szukaj przedmiotu (nazwa albo ID)|r", 11, 240)
    panel.search = ns.MakeInput(panel, 170)
    panel.search:SetPoint("TOPLEFT", 16, -26)
    panel.search:SetScript("OnEnterPressed", function(self) DoSearch(self:GetText()); self:ClearFocus() end)
    local sb = ns.MakeButton(panel, "Szukaj", 66, 22)
    sb:SetPoint("TOPLEFT", 192, -26)
    sb:SetScript("OnClick", function() DoSearch(panel.search:GetText()) end)
    panel.status = Label(panel, 12, -52, "", 10, LEFT_W - 8)

    NROWS = math.max(5, math.floor((H - 76) / ROW_H))
    for i = 1, NROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(LEFT_W, ROW_H - 1)
        row:SetPoint("TOPLEFT", 8, -68 - (i - 1) * ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.2, 0.5, 1, 0.22)
        row.sel:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 3, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name = ns.MakeFS(row, 11)
        row.name:SetPoint("TOPLEFT", 34, -2)
        row.name:SetWidth(LEFT_W - 40)
        row.name:SetWordWrap(false)
        row.sub = ns.MakeFS(row, 9)
        row.sub:SetPoint("TOPLEFT", 34, -15)
        row.sub:SetWidth(LEFT_W - 40)
        row.sub:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if self.res and self.res.itemKey then Pick(self.res.itemKey) end
        end)
        row:Hide()
        rows[i] = row
    end

    panel:SetScript("OnMouseWheel", function(_, delta)
        S.offset = math.max(0, S.offset - delta * 3)
        local A = AH()
        if A and A.HasFullBrowseResults and A.RequestMoreBrowseResults
            and not A.HasFullBrowseResults() and S.offset + NROWS >= #S.results - 3 then
            pcall(A.RequestMoreBrowseResults)
        end
        RefreshList()
    end)

    ------- prawa strona
    local rx = LEFT_W + 20
    local rw = W - rx - 12
    local colW = math.floor(rw / 2) - 6

    panel.icon = panel:CreateTexture(nil, "ARTWORK")
    panel.icon:SetSize(30, 30)
    panel.icon:SetPoint("TOPLEFT", rx, -8)
    panel.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    panel.name = Label(panel, rx + 38, -8, "", 15, rw - 200)
    panel.stats = Label(panel, rx + 38, -28, "", 10, rw - 38)

    local refresh = ns.MakeButton(panel, "Odswiez", 70, 20)
    refresh:SetPoint("TOPRIGHT", -12, -8)
    refresh:SetScript("OnClick", function() Request(true); Refresh() end)

    -- zakres wykresu
    panel.rangeBtns = {}
    local defs = { { "7d", 7 * 86400 }, { "30d", 30 * 86400 }, { "Wszystko", 0 } }
    local bx = rx
    for i, dfn in ipairs(defs) do
        local b = ns.FlatButton(panel, (i == 3) and 66 or 40, 18)
        b:SetPoint("TOPLEFT", bx, -48)
        bx = bx + ((i == 3) and 70 or 44)
        b.text:SetText(dfn[1])
        b.range = dfn[2]
        b:SetScript("OnClick", function() db.ahSt.range = dfn[2]; Refresh() end)
        panel.rangeBtns[i] = b
    end
    local bigBtn = ns.FlatButton(panel, 100, 18)
    bigBtn:SetPoint("TOPLEFT", bx + 6, -48)
    bigBtn.text:SetText("Duzy wykres")
    bigBtn:SetScript("OnClick", function() if ns.ToggleBigChart then ns.ToggleBigChart() end end)

    panel.chart = ns.NewChart(panel, rw, 112, { padL = 70, gutter = 100, mini = true, st = db.ahSt })
    panel.chart:SetPoint("TOPLEFT", rx, -88)

    -- drabina ofert (lewa polowa dolu)
    local ly = -228
    Label(panel, rx, ly, BLUE .. "Oferty w AH|r", 11, 120)
    panel.ladNote = Label(panel, rx + 100, ly - 1, "", 9, 120)
    Label(panel, rx, ly - 18, GRAY .. "Cena za szt.|r", 9, 110)
    Label(panel, rx + 112, ly - 18, GRAY .. "Ilosc|r", 9, 50)
    for i = 1, LAD do
        local y = ly - 32 - (i - 1) * 16
        lad[i] = {
            price = Label(panel, rx, y, "", 11, 110),
            qty = Label(panel, rx + 112, y, "", 11, 50),
            note = Label(panel, rx + 162, y, "", 10, colW - 160),
        }
    end
    panel.ba = ns.MakeFS(panel, 10)
    panel.ba:SetPoint("TOPLEFT", rx, ly - 32 - LAD * 16 - 6)
    panel.ba:SetWidth(colW)
    panel.ba:SetSpacing(2)

    -- cena / ilosc / presety / ryzyko (prawa polowa dolu)
    local cx = rx + colW + 12
    Label(panel, cx, ly, BLUE .. "Twoja oferta|r", 11, 160)
    Label(panel, cx, ly - 18, GRAY .. "Cena za szt. (np. 2g 14s)|r", 9, 150)
    panel.priceBox = ns.MakeInput(panel, 120)
    panel.priceBox:SetPoint("TOPLEFT", cx + 6, ly - 30)
    panel.priceBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        S.price = ns.ParseMoney(self:GetText())
        Refresh()
    end)
    panel.priceBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Label(panel, cx + 140, ly - 18, GRAY .. "Ilosc|r", 9, 50)
    panel.qtyBox = ns.MakeInput(panel, 54)
    panel.qtyBox:SetPoint("TOPLEFT", cx + 144, ly - 30)
    panel.qtyBox:SetNumeric(true)
    panel.qtyBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        S.qty = math.max(1, tonumber(self:GetText()) or 1)
        Refresh()
    end)
    panel.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    panel.presetBtns = {}
    for i, p in ipairs({ { "fast", "Szybko" }, { "typical", "Typowo" }, { "patient", "Cierpliwie" } }) do
        local b = ns.FlatButton(panel, math.floor((colW - 8) / 3), 20)
        b:SetPoint("TOPLEFT", cx + (i - 1) * (math.floor((colW - 8) / 3) + 4), ly - 58)
        b.key, b.label = p[1], p[2]
        b.text:SetFont(STANDARD_TEXT_FONT, 9, "")
        b:SetScript("OnClick", function()
            if panel.presets and panel.presets[b.key] then
                S.price, S.boxDirty = panel.presets[b.key], true
                Refresh()
            end
        end)
        panel.presetBtns[i] = b
    end

    panel.risk = ns.MakeFS(panel, 10)
    panel.risk:SetPoint("TOPLEFT", cx, ly - 86)
    panel.risk:SetWidth(colW)
    panel.risk:SetSpacing(2)

    panel:SetScript("OnShow", function()
        if S.cur then Request(false) end
        ns.Safe("ahtab", Refresh)
    end)
end

------------------------------------------------------------------
-- Przycisk zakladki obok TSM
------------------------------------------------------------------
local function CollectTabs(f)
    local list, seen = {}, {}
    local function add(b)
        if b and b ~= tabBtn and b ~= panel and not seen[b] and b.IsObjectType and b:IsObjectType("Button") then
            seen[b] = true
            list[#list + 1] = b
        end
    end
    if type(f.Tabs) == "table" then
        for _, b in ipairs(f.Tabs) do add(b) end
    end
    local fb = f:GetBottom()
    for _, c in ipairs({ f:GetChildren() }) do
        if c ~= panel and c ~= tabBtn and c.IsObjectType and c:IsObjectType("Button") then
            local b = c:GetBottom()
            if fb and b and b < fb + 4 then add(c) end   -- zakladki wisza przy dolnej krawedzi okna
        end
    end
    return list
end

local function HidePanel() if panel and panel:IsShown() then panel:Hide() end end

local function PlaceTab()
    local f = _G.AuctionHouseFrame
    if not (f and tabBtn) then return end
    local tabs = CollectTabs(f)
    local rightmost, best
    for _, b in ipairs(tabs) do
        local r = b:GetRight()
        if r and (not best or r > best) then rightmost, best = b, r end
        if not hooked[b] then
            hooked[b] = true
            b:HookScript("OnClick", HidePanel)   -- wybor innej zakladki (Buy / Sell / Auctions / TSM) zamyka HUB
        end
    end
    tabBtn:ClearAllPoints()
    if rightmost then
        tabBtn:SetPoint("LEFT", rightmost, "RIGHT", 4, 0)
    else
        tabBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 330, -30)
    end
end

local function BuildTab()
    local f = _G.AuctionHouseFrame
    for _, tpl in ipairs({ "AuctionHouseFrameDisplayModeTabTemplate", "PanelTabButtonTemplate" }) do
        local ok, b = pcall(CreateFrame, "Button", "TsmAnalizeAHTabButton", f, tpl)
        if ok and b then tabBtn = b; break end
    end
    if tabBtn then
        tabBtn:SetText("HUB")
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tabBtn, 0) end
    else
        tabBtn = ns.FlatButton(f, 70, 24)
        tabBtn.text:SetText("HUB")
    end
    tabBtn:SetScript("OnClick", function()
        if not panel then ns.Safe("ahtab", BuildPanel) end
        if not panel then return end
        if panel:IsShown() then panel:Hide() else panel:Show() end
    end)
end

local function Setup()
    if not (ns.db and _G.AuctionHouseFrame) then return end
    if not tabBtn then BuildTab() end
    PlaceTab()
    -- TSM dodaje swoja zakladke z opoznieniem: ustaw ponownie
    C_Timer.After(0.7, function() ns.Safe("ahtab", PlaceTab) end)
    C_Timer.After(2.5, function() ns.Safe("ahtab", PlaceTab) end)
end

------------------------------------------------------------------
-- Zdarzenia
------------------------------------------------------------------
if ns.UpdateUI then
    hooksecurefunc(ns, "UpdateUI", function()
        if panel and panel:IsShown() then ns.Safe("ahtab", Refresh) end
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1)
    if event == "AUCTION_HOUSE_SHOW" then
        ns.Safe("ahtab", Setup)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        S.searching = false
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        ns.Safe("ahtab", OnBrowse)
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        ns.Safe("ahtab", OnCommodity, a1)
        S.searching = false
        ns.Safe("ahtab", Refresh)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        ns.Safe("ahtab", OnItemResults, a1)
        S.searching = false
        ns.Safe("ahtab", Refresh)
    elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
        ns.Safe("ahtab", RefreshList)
    end
end)
