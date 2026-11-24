local ADDON, ns = ...

------------------------------------------------------------------
-- HUB AUKCJI: duze, samodzielne okno, ktore zastepuje okno domu aukcyjnego Blizzarda
--  * lewa kolumna: Torby (Twoje przedmioty do sprzedazy, bez zwiazanych) albo Wyniki AH (wyszukiwarka)
--  * klik w przedmiot: zywe oferty z AH, wykres, drabina z pozycja Twojej ceny, analiza ryzyka
--  * Wystaw: wystawia przedmiot z toreb (cena, ilosc, czas aukcji)
--  * Okno otwiera sie samo przy domu aukcyjnym (Ustawienia: "AH: Hub zastepuje okno aukcji").
--    Przycisk "Okno Blizzard" wraca do standardowego okna (kupowanie, anulowanie aukcji).
--    Przycisk HUB przy prawej krawedzi okna AH otwiera Hub z powrotem.
-- Wymaga: Widgets.lua, Chart.lua (ns.NewChart), Core.lua. Dodaj do .toc po Focus.lua.
------------------------------------------------------------------

local GRAY, GREEN, RED, BLUE, YELLOW, ORANGE = "|cff9aa0a6", "|cff33dd66", "|cffff4040", "|cff33aaff", "|cffffcc33", "|cffffa040"
local W, H = 1040, 700
local LEFT_W, ROW_H, LAD = 270, 30, 7
local NROWS = 19

local panel, tabBtn
local rows, lad = {}, {}
local S = { results = {}, offset = 0, mode = "bags", cur = nil, price = nil, qty = 1, dur = 3,
    boxDirty = true, status = "", msg = "" }
local bagList, bagById, bagView = {}, {}, {}
local live = {}
local lastSend = 0
local hooked = {}
local ahOpen = false
local bagPending = false

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

local function tsm(src, s)
    if not ns.HasTSM() then return nil end
    local ok, v = pcall(TSM_API.GetCustomPriceValue, src, s)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil
end

local valCache = {}
local function UnitValue(id)
    local c = valCache[id]
    local now = GetTime()
    if c and now - c.t < 90 then return c.v end
    local s = "i:" .. id
    local v = tsm("DBMinBuyout", s) or tsm("DBMarket", s)
    valCache[id] = { t = now, v = v }
    return v
end

------------------------------------------------------------------
-- Torby
------------------------------------------------------------------
local function ScanBags()
    local list, byId = {}, {}
    local C = _G.C_Container
    local getN = (C and C.GetContainerNumSlots) or _G.GetContainerNumSlots
    if getN then
        local maxBag = (_G.NUM_BAG_SLOTS or 4) + (_G.NUM_REAGENTBAG_SLOTS or 0)
        for bag = 0, maxBag do
            for slot = 1, (getN(bag) or 0) do
                local id, count, bound
                if C and C.GetContainerItemInfo then
                    local i = C.GetContainerItemInfo(bag, slot)
                    if i then id, count, bound = i.itemID, i.stackCount, i.isBound end
                elseif _G.GetContainerItemInfo then
                    local _, c, _, _, _, _, _, _, _, itemID, isBound = _G.GetContainerItemInfo(bag, slot)
                    id, count, bound = itemID, c, isBound
                end
                if id and count and count > 0 and not bound then
                    local e = byId[id]
                    if not e then
                        e = { id = id, s = "i:" .. id, qty = 0, bag = bag, slot = slot }
                        byId[id] = e
                        list[#list + 1] = e
                    end
                    e.qty = e.qty + count
                end
            end
        end
    end
    for _, e in ipairs(list) do
        e.name = ns.ItemName(e.s)
        e.unit = UnitValue(e.id)
        e.value = (e.unit or 0) * e.qty
    end
    table.sort(list, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return list, byId
end

local function BuildView()
    bagView = {}
    local q = panel and trim(panel.search:GetText()):lower() or ""
    if q:find("|h", 1, true) or q:find("item:", 1, true) then q = "" end   -- wklejony link nie jest filtrem
    for _, e in ipairs(bagList) do
        if q == "" or e.name:lower():find(q, 1, true) or tostring(e.id) == q then
            bagView[#bagView + 1] = e
        end
    end
end

local function RebuildBags()
    bagList, bagById = ScanBags()
    BuildView()
    local c = S.cur
    local b = c and bagById[c.id]
    if b and (S.qty or 1) > b.qty then S.qty, S.boxDirty = b.qty, true end
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
-- Wybor przedmiotu i wyszukiwanie
------------------------------------------------------------------
local Refresh, RefreshList

local function Pick(key)
    if not (key and key.itemID) then return end
    S.cur = { key = key, id = key.itemID, s = "i:" .. key.itemID }
    local b = bagById[key.itemID]
    S.price, S.boxDirty, S.qty = nil, true, (b and b.qty) or 1
    S.searching = false
    S.msg = ""
    if ns.Select then ns.Select(S.cur.s) end   -- HUD i reszta addonu widza ten sam przedmiot
    Request(true)
    Refresh()
end

local function DoSearch(text)
    text = trim(text)
    local A = AH()
    if text == "" then
        S.mode, S.offset = "bags", 0
        BuildView()
        RefreshList()
        return
    end
    if not A then return end
    -- link (Shift+klik), ID albo i:ID -> wprost do przedmiotu
    local id = tonumber(text) or tonumber(text:match("item:(%d+)")) or tonumber(text:match("^i:(%d+)"))
    if id and A.MakeItemKey then
        Pick(A.MakeItemKey(id))
        return
    end
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Name then
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }
    end
    S.mode, S.status, S.offset = "ah", "Szukam...", 0
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
        ((A.HasFullBrowseResults and not A.HasFullBrowseResults()) and " (przewin po wiecej)" or ""))
    RefreshList()
end

------------------------------------------------------------------
-- Lista po lewej
------------------------------------------------------------------
function RefreshList()
    if not (panel and panel:IsShown()) then return end
    local bags = (S.mode == "bags")
    local list = bags and bagView or S.results
    if bags then
        panel.status:SetText(GRAY .. #bagView .. " z " .. #bagList .. " przedmiotow z toreb (bez zwiazanych)|r")
    else
        panel.status:SetText(GRAY .. (S.status or "") .. "|r")
    end
    ns.SetActive(panel.modeBags, bags)
    ns.SetActive(panel.modeAH, not bags)
    S.offset = math.min(S.offset, math.max(0, #list - NROWS))
    for i = 1, NROWS do
        local row, it = rows[i], list[S.offset + i]
        row.bag, row.res = nil, nil
        if it and bags then
            row.bag = it
            row:Show()
            row.icon:SetTexture(ns.ItemIcon(it.s))
            row.name:SetText(it.name .. (it.qty > 1 and (GRAY .. "  x" .. it.qty .. "|r") or ""))
            if it.unit then
                row.sub:SetText(GRAY .. "szt. |r" .. ns.Money(it.unit) .. GRAY .. "   razem ~" .. ns.MoneyPlain(it.value) .. "|r")
            else
                row.sub:SetText(GRAY .. "brak ceny TSM|r")
            end
            row.sel:SetShown(S.cur and S.cur.id == it.id or false)
        elseif it and it.itemKey then
            local key = it.itemKey
            local s = "i:" .. key.itemID
            local info = KeyInfo(key)
            row.res = it
            row:Show()
            row.icon:SetTexture((info and info.iconFileID) or ns.ItemIcon(s))
            row.name:SetText((info and info.itemName) or ns.ItemName(s))
            row.sub:SetText(GRAY .. "od |r" .. ns.Money(it.minPrice) .. GRAY .. "   x" .. tostring(it.totalQuantity or 0) .. "|r")
            row.sel:SetShown(S.cur and S.cur.id == key.itemID or false)
        else
            row:Hide()
        end
    end
end

------------------------------------------------------------------
-- Analiza ryzyka (zwiezle linie)
------------------------------------------------------------------
local function RiskText(s, d, price, qty, lv)
    if not ns.HasTSM() then return GRAY .. "TSM nie wykryte - brak analizy.|r" end
    local ok, r = pcall(ns.Analyze, s, d, (ns.EffectiveBuy(s, d)))
    if not ok or type(r) ~= "table" or r.verdict == "NODATA" or not r.risk then
        return GRAY .. "Brak danych TSM do analizy.|r"
    end
    local db = ns.db
    local rk = r.risk
    local keep = 1 - ns.Cut() / 100
    local L = {}
    local function add(t) L[#L + 1] = t end

    add("Ocena: " .. ns.VERDICT_SHORT[r.verdict] .. "   ryzyko " .. ns.RISK_TEXT[rk.level] .. string.format(" (%d/100)", rk.score))
    local pc = (rk.p >= 0.7 and GREEN) or (rk.p >= 0.5 and YELLOW) or RED
    add("Szansa sprzedazy: " .. pc .. string.format("%.0f%%|r", rk.p * 100) ..
        (rk.pLo and (GRAY .. string.format("  (%.0f-%.0f%%)|r", rk.pLo * 100, rk.pHi * 100)) or ""))

    if price and price > 0 then
        local recv = price * qty * keep
        add(string.format("Dostaniesz: %s %s(prowizja %s%%)|r", ns.MoneyPlain(recv), GRAY, tostring(ns.Cut())))
        add("Depozyt: " .. ns.MoneyPlain((r.deposit or 0) * qty))
        if r.buyIsOwn and r.buy then
            local net = price * keep - r.buy
            add(string.format("Zysk/szt.: %s%s|r (%+.0f%%)  razem %s", net >= 0 and GREEN or RED,
                ns.MoneyPlain(net), net / r.buy * 100, ns.MoneyPlain(net * qty)))
        else
            add(GRAY .. "Zysk: brak ceny zakupu (wpisz w HUD)|r")
        end
        if r.sellRef and r.sellRef > 0 then
            add(string.format("Cena vs ref. (%s): %+.0f%%", ns.MoneyPlain(r.sellRef), (price / r.sellRef - 1) * 100))
        end
        if r.breakEven and price < r.breakEven then
            add(RED .. "Ponizej break-even (" .. ns.MoneyPlain(r.breakEven) .. ")|r")
        elseif r.minList and price < r.minList then
            add(ORANGE .. "Ponizej progu zysku (" .. ns.MoneyPlain(r.minList) .. ")|r")
        end
        if d.minbuy and price < d.minbuy * 0.5 then
            add(ORANGE .. "Cena <50% min - literowka?|r")
        end
    end

    local perDay = d.perDay and (d.perDay / (db.perDayDiv or 1))
    if perDay and perDay > 0 then
        local days = qty / (perDay * (db.riskShare or 0.5))
        local txt = (days < 1) and string.format("~%.0f h", days * 24) or string.format("~%.1f dnia", days)
        local col = (days > 4 and RED) or (days > 2 and YELLOW) or GREEN
        add(string.format("Czas sprzedazy: %s%s|r %s(rynek ~%.0f/dzien)|r", col, txt, GRAY, perDay))
    else
        add(ORANGE .. "Tempo sprzedazy: brak danych TSM|r")
    end

    local x = rk.extra
    if x and x.buffer then
        local bc = (x.bufferSigma < 1 and RED) or (x.bufferSigma < 2 and YELLOW) or GREEN
        add(string.format("Bufor spadku: %s%.0f%% (%.1fx zmienn.)|r", bc, x.buffer, x.bufferSigma))
    end
    if lv and lv.real and r.sellRef and lv.real > r.sellRef * 1.25 then
        add(ORANGE .. "Rynek 25%+ nad ref. (skok?)|r")
    end
    if rk.why and #rk.why > 0 then
        local top = {}
        for i = 1, math.min(2, #rk.why) do top[#top + 1] = rk.why[i] end
        add(GRAY .. "Powody: " .. table.concat(top, "; ") .. "|r")
    end
    return table.concat(L, "\n")
end

------------------------------------------------------------------
-- Wystawianie
------------------------------------------------------------------
local function DoPost()
    local c = S.cur
    if not c then return end
    local A = AH()
    if not (ahOpen and A) then ns.Print("Otworz dom aukcyjny, zeby wystawiac."); return end
    RebuildBags()
    local e = bagById[c.id]
    if not e then ns.Print("Nie masz tego przedmiotu w torbach."); RefreshList(); return end
    local price = S.price or (panel.presets and panel.presets.fast)
    local qty = math.max(0, math.min(S.qty or 0, e.qty))
    if not price or price <= 0 or qty <= 0 then ns.Print("Podaj cene i ilosc."); return end
    if not (_G.ItemLocation and ItemLocation.CreateFromBagAndSlot) then ns.Print("Brak ItemLocation w tym kliencie."); return end
    local loc = ItemLocation:CreateFromBagAndSlot(e.bag, e.slot)
    if not (loc and loc:IsValid()) then
        ns.Print("Przedmiot zmienil miejsce w torbie - odswiezam liste.")
        RefreshList()
        return
    end
    local commodity = true
    if A.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
        local st = A.GetItemCommodityStatus(loc)
        if st == Enum.ItemCommodityStatus.Item then commodity = false end
    end
    local ok, err
    if commodity then
        ok, err = pcall(A.PostCommodity, loc, S.dur, qty, price)
    else
        ok, err = pcall(A.PostItem, loc, S.dur, qty, nil, price * qty)
    end
    if not ok then
        ns.Print("Nie udalo sie wystawic: " .. tostring(err))
        return
    end
    S.msg = string.format("Wystawiono %d x %s po %s za szt.", qty, ns.ItemName(c.s), ns.MoneyPlain(price))
    S.price, S.boxDirty = nil, true
    live[c.id] = nil
    C_Timer.After(1.0, function()
        if S.cur and S.cur.id == c.id then Request(true) end
    end)
    Refresh()
end

------------------------------------------------------------------
-- Prawa strona
------------------------------------------------------------------
local function UpdateDur()
    if not panel then return end
    for i, b in ipairs(panel.durBtns) do
        b.text:SetText((ns.db.durLabels and ns.db.durLabels[i]) or tostring(i))
        ns.SetActive(b, S.dur == i)
    end
end

local function Clear()
    panel.name:SetText(GRAY .. "Wybierz przedmiot z listy po lewej (Torby) albo wyszukaj w AH.|r")
    panel.stats:SetText("")
    panel.icon:SetTexture(134400)
    panel.chart:SetItem(nil)
    panel.chart:Redraw()
    panel.ba:SetText("")
    panel.risk:SetText("")
    panel.post:SetText("Wystaw")
    panel.post:SetEnabled(false)
    panel.msg:SetText(GRAY .. (S.msg or "") .. "|r")
    for _, l in ipairs(lad) do l.price:SetText(""); l.qty:SetText(""); l.note:SetText("") end
    panel.ladNote:SetText("")
end

function Refresh()
    RefreshList()
    if not (panel and panel:IsShown()) then return end
    UpdateDur()
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
        statsTxt = GRAY .. "Najtaniej: |r" .. ns.Money(real) .. GRAY .. "   poziomow: " .. #lv.rows ..
            "   sztuk: " .. lv.total .. "   (AH " .. math.max(0, time() - lv.t) .. " s temu)|r"
    elseif S.searching then
        statsTxt = ORANGE .. "Pobieram oferty z AH...|r"
    else
        statsTxt = GRAY .. "Min wg TSM: |r" .. ns.Money(d.minbuy) .. GRAY .. "  (Odswiez = zywe oferty)|r"
    end
    panel.stats:SetText(statsTxt)

    -- wykres
    panel.chart.st = db.ahSt
    panel.chart:SetItem(s)
    panel.chart:Redraw()
    for _, b in ipairs(panel.rangeBtns) do ns.SetActive(b, (db.ahSt.range or 0) == b.range) end

    -- presety
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

    local bag = bagById[id]
    if bag and (S.qty or 1) > bag.qty then S.qty, S.boxDirty = bag.qty, true end
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
        b.text:SetText(b.label .. (presets and ("\n" .. ns.MoneyPlain(presets[b.key])) or ""))
        ns.SetActive(b, presets and price and presets[b.key] == price or false)
    end

    -- przycisk Wystaw
    if bag then
        panel.post:SetText(string.format("Wystaw %d x %s", math.min(qty, bag.qty), ns.ItemName(s)))
    else
        panel.post:SetText("Brak w torbach")
    end
    panel.post:SetEnabled(ahOpen and bag ~= nil and price ~= nil and price > 0 and qty > 0)
    panel.msg:SetText(GRAY .. (S.msg or "") .. "|r")

    -- drabina + pozycja Twojej ceny
    if lv and price then
        local before, after, same, nBefore, nAfter = 0, 0, 0, 0, 0
        local entries, markerAt = {}, nil
        for _, m in ipairs(lv.rows) do
            if m.price < price then
                before, nBefore = before + m.qty, nBefore + 1
            elseif m.price == price then
                same = same + m.qty
            else
                after, nAfter = after + m.qty, nAfter + 1
            end
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
                l.note:SetText(GREEN .. "<< TWOJA|r")
            else
                l.price:SetText(ns.Money(e.price))
                l.qty:SetText(tostring(e.qty))
                l.note:SetText(e.own and (ORANGE .. "Twoja aukcja|r") or "")
            end
        end
        panel.ladNote:SetText(start > 1 and (GRAY .. "(od #" .. start .. ")|r") or "")
        local share = lv.total > 0 and (qty / (lv.total + qty) * 100) or 0
        panel.ba:SetText(string.format(
            "%sPrzed Toba (taniej):|r %d szt. / %d ofert\n%sTyle samo:|r %d szt.\n%sZa Toba (drozej):|r %d szt. / %d ofert\n%sTwoja pozycja:|r #%d z %d\n%sUdzial w podazy:|r ~%.0f%%",
            GRAY, before, nBefore, GRAY, same, GRAY, after, nAfter, GRAY, nBefore + 1, #lv.rows + 1, GRAY, share))
    else
        for _, l in ipairs(lad) do l.price:SetText(""); l.qty:SetText(""); l.note:SetText("") end
        panel.ladNote:SetText("")
        panel.ba:SetText(GRAY .. "Brak zywych ofert - kliknij Odswiez.|r")
    end

    panel.risk:SetText(RiskText(s, d, price, qty, lv))
end

------------------------------------------------------------------
-- Zamykanie
------------------------------------------------------------------
local function CloseAll()
    if panel then panel:Hide() end
    local f = _G.AuctionHouseFrame
    if f and f:IsShown() then
        if _G.HideUIPanel then pcall(_G.HideUIPanel, f) else f:Hide() end
    end
end

------------------------------------------------------------------
-- Budowa okna
------------------------------------------------------------------
local function BuildPanel()
    local db = ns.db
    db.ahSt = db.ahSt or { range = 7 * 86400, be = true, alert = true, ov = {} }
    db.ahSt.ov = db.ahSt.ov or {}
    S.dur = db.postDur or 3

    panel = CreateFrame("Frame", "TsmAnalizeAHTab", UIParent, "BackdropTemplate")
    panel:SetSize(W, H)
    local pp = db.ahPanelPos
    if pp then panel:SetPoint(pp[1], UIParent, pp[2], pp[3], pp[4]) else panel:SetPoint("CENTER") end
    panel:SetFrameStrata("HIGH")
    ns.DarkBackdrop(panel, 0.98)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:EnableMouseWheel(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        db.ahPanelPos = { p, rp, x, y }
    end)
    panel:EnableKeyboard(true)
    panel:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
            CloseAll()
        elseif self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    panel:Hide()

    ------- pasek tytulowy
    local title = ns.MakeFS(panel, 15)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText(BLUE .. "TSMA|r  Aukcje")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", CloseAll)

    local blizz = ns.MakeButton(panel, "Okno Blizzard", 110, 20)
    blizz:SetPoint("TOPRIGHT", -40, -7)
    blizz:SetScript("OnClick", function() panel:Hide() end)
    ns.Tip(blizz, "Chowa Hub i pokazuje standardowe okno AH (kupowanie, anulowanie aukcji). Przycisk HUB przy oknie AH wraca.")

    ------- lewa kolumna
    panel.search = ns.MakeInput(panel, 190)
    panel.search:SetPoint("TOPLEFT", 16, -40)
    panel.search:SetScript("OnEnterPressed", function(self) DoSearch(self:GetText()); self:ClearFocus() end)
    panel.search:SetScript("OnTextChanged", function(_, user)
        if not user then return end
        S.mode, S.offset = "bags", 0
        BuildView()
        RefreshList()
    end)
    local sb = ns.MakeButton(panel, "Szukaj w AH", 80, 22)
    sb:SetPoint("TOPLEFT", 200, -40)
    sb:SetScript("OnClick", function() DoSearch(panel.search:GetText()) end)
    ns.Tip(sb, "Wpisana nazwa filtruje Torby na biezaco. Szukaj w AH (albo Enter) przeszukuje dom aukcyjny. Link lub ID otwiera przedmiot od razu.")

    panel.status = Label(panel, 14, -66, "", 10, LEFT_W - 10)

    panel.modeBags = ns.FlatButton(panel, 128, 20)
    panel.modeBags:SetPoint("TOPLEFT", 12, -84)
    panel.modeBags.text:SetText("Torby")
    panel.modeBags:SetScript("OnClick", function() S.mode, S.offset = "bags", 0; BuildView(); RefreshList() end)
    panel.modeAH = ns.FlatButton(panel, 128, 20)
    panel.modeAH:SetPoint("TOPLEFT", 144, -84)
    panel.modeAH.text:SetText("Wyniki AH")
    panel.modeAH:SetScript("OnClick", function() S.mode, S.offset = "ah", 0; RefreshList() end)

    -- Shift+klik na przedmiocie wpisuje link do pola i od razu otwiera przedmiot
    local function OnLink(link)
        if type(link) ~= "string" or not (panel and panel.search:HasFocus()) then return end
        local now = GetTime()
        if S.lastLink == link and S.lastLinkT and now - S.lastLinkT < 0.5 then return end
        S.lastLink, S.lastLinkT = link, now
        panel.search:SetText(link)
        DoSearch(link)
    end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnLink)
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", OnLink)
    end
    if HandleModifiedItemClick then
        hooksecurefunc("HandleModifiedItemClick", OnLink)
    end

    for i = 1, NROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(LEFT_W, ROW_H - 1)
        row:SetPoint("TOPLEFT", 8, -110 - (i - 1) * ROW_H)
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
            local A = AH()
            if self.bag then
                if A and A.MakeItemKey then Pick(A.MakeItemKey(self.bag.id)) end
            elseif self.res and self.res.itemKey then
                Pick(self.res.itemKey)
            end
        end)
        row:Hide()
        rows[i] = row
    end

    panel:SetScript("OnMouseWheel", function(_, delta)
        S.offset = math.max(0, S.offset - delta * 3)
        if S.mode == "ah" then
            local A = AH()
            if A and A.HasFullBrowseResults and A.RequestMoreBrowseResults
                and not A.HasFullBrowseResults() and S.offset + NROWS >= #S.results - 3 then
                pcall(A.RequestMoreBrowseResults)
            end
        end
        RefreshList()
    end)

    ------- prawa strona
    local rx = LEFT_W + 24
    local rw = W - rx - 16
    local colL = 290                      -- kolumna drabiny ofert
    local colR = rw - colL - 20           -- kolumna "Twoja oferta" + analiza

    panel.icon = panel:CreateTexture(nil, "ARTWORK")
    panel.icon:SetSize(30, 30)
    panel.icon:SetPoint("TOPLEFT", rx, -40)
    panel.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    panel.name = Label(panel, rx + 38, -40, "", 15, rw - 170)
    panel.stats = Label(panel, rx + 38, -62, "", 10, rw - 38)

    local refresh = ns.MakeButton(panel, "Odswiez", 80, 20)
    refresh:SetPoint("TOPRIGHT", -16, -40)
    refresh:SetScript("OnClick", function() RebuildBags(); Request(true); Refresh() end)

    -- zakres wykresu
    panel.rangeBtns = {}
    local defs = { { "7d", 7 * 86400 }, { "30d", 30 * 86400 }, { "Wszystko", 0 } }
    local bx = rx
    for i, dfn in ipairs(defs) do
        local b = ns.FlatButton(panel, (i == 3) and 66 or 40, 18)
        b:SetPoint("TOPLEFT", bx, -86)
        bx = bx + ((i == 3) and 70 or 44)
        b.text:SetText(dfn[1])
        b.range = dfn[2]
        b:SetScript("OnClick", function() db.ahSt.range = dfn[2]; Refresh() end)
        panel.rangeBtns[i] = b
    end
    local bigBtn = ns.FlatButton(panel, 100, 18)
    bigBtn:SetPoint("TOPLEFT", bx + 6, -86)
    bigBtn.text:SetText("Duzy wykres")
    bigBtn:SetScript("OnClick", function() if ns.ToggleBigChart then ns.ToggleBigChart() end end)

    panel.chart = ns.NewChart(panel, rw, 176, { padL = 80, gutter = 120, st = db.ahSt })
    panel.chart:SetPoint("TOPLEFT", rx, -116)

    -- sekcja 1: drabina ofert
    local ly = -326
    Label(panel, rx, ly, BLUE .. "Oferty w AH|r", 11, 100)
    panel.ladNote = Label(panel, rx + 110, ly - 1, "", 9, 100)
    Label(panel, rx, ly - 18, GRAY .. "Cena za szt.|r", 9, 100)
    Label(panel, rx + 104, ly - 18, GRAY .. "Ilosc|r", 9, 60)
    for i = 1, LAD do
        local y = ly - 32 - (i - 1) * 16
        lad[i] = {
            price = Label(panel, rx, y, "", 11, 100),
            qty = Label(panel, rx + 104, y, "", 11, 60),
            note = Label(panel, rx + 170, y, "", 10, colL - 170),
        }
    end
    panel.ba = ns.MakeFS(panel, 10)
    panel.ba:SetPoint("TOPLEFT", rx, ly - 32 - LAD * 16 - 8)
    panel.ba:SetWidth(colL)
    panel.ba:SetSpacing(3)

    -- sekcja 2: Twoja oferta, wystawianie, analiza
    local cx = rx + colL + 20
    Label(panel, cx, ly, BLUE .. "Twoja oferta|r", 11, 160)
    Label(panel, cx, ly - 18, GRAY .. "Cena za szt. (np. 2g 14s)|r", 9, 170)
    panel.priceBox = ns.MakeInput(panel, 150)
    panel.priceBox:SetPoint("TOPLEFT", cx + 6, ly - 30)
    panel.priceBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        S.price = ns.ParseMoney(self:GetText())
        Refresh()
    end)
    panel.priceBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Label(panel, cx + 176, ly - 18, GRAY .. "Ilosc|r", 9, 50)
    panel.qtyBox = ns.MakeInput(panel, 60)
    panel.qtyBox:SetPoint("TOPLEFT", cx + 180, ly - 30)
    panel.qtyBox:SetNumeric(true)
    panel.qtyBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        S.qty = math.max(1, tonumber(self:GetText()) or 1)
        Refresh()
    end)
    panel.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local all = ns.MakeButton(panel, "Wszystko", 72, 22)
    all:SetPoint("TOPLEFT", cx + 250, ly - 30)
    all:SetScript("OnClick", function()
        local b = S.cur and bagById[S.cur.id]
        if b then S.qty, S.boxDirty = b.qty, true; Refresh() end
    end)

    -- czas trwania aukcji
    Label(panel, cx, ly - 66, GRAY .. "Czas aukcji:|r", 10, 80)
    panel.durBtns = {}
    for i = 1, 3 do
        local b = ns.FlatButton(panel, 52, 22)
        b:SetPoint("TOPLEFT", cx + 84 + (i - 1) * 56, ly - 62)
        b:SetScript("OnClick", function()
            S.dur = i
            ns.db.postDur = i
            Refresh()
        end)
        panel.durBtns[i] = b
    end

    -- presety: dwie linie (nazwa / cena)
    panel.presetBtns = {}
    local pw = math.floor((colR - 8) / 3)
    for i, p in ipairs({ { "fast", "Szybko" }, { "typical", "Typowo" }, { "patient", "Cierpliwie" } }) do
        local b = ns.FlatButton(panel, pw, 30)
        b:SetPoint("TOPLEFT", cx + (i - 1) * (pw + 4), ly - 94)
        b.key, b.label = p[1], p[2]
        b.text:SetFont(STANDARD_TEXT_FONT, 10, "")
        b.text:SetWidth(pw - 4)
        b:SetScript("OnClick", function()
            if panel.presets and panel.presets[b.key] then
                S.price, S.boxDirty = panel.presets[b.key], true
                Refresh()
            end
        end)
        panel.presetBtns[i] = b
    end

    panel.post = ns.MakeButton(panel, "Wystaw", colR, 28)
    panel.post:SetPoint("TOPLEFT", cx, ly - 132)
    panel.post:SetScript("OnClick", DoPost)

    panel.msg = ns.MakeFS(panel, 10)
    panel.msg:SetPoint("TOPLEFT", cx, ly - 164)
    panel.msg:SetWidth(colR)

    Label(panel, cx, ly - 186, BLUE .. "Analiza|r", 11, 100)
    panel.risk = ns.MakeFS(panel, 10)
    panel.risk:SetPoint("TOPLEFT", cx, ly - 202)
    panel.risk:SetWidth(colR)
    panel.risk:SetSpacing(3)

    panel:SetScript("OnShow", function(self)
        self:SetScale(ns.db.scale or 1)
        local f = _G.AuctionHouseFrame
        if f then f:SetAlpha(0) end   -- okno Blizzarda zostaje pod spodem (niewidoczne), Hub je zastepuje
        ns.Safe("ahtab", RebuildBags)
        if S.cur then Request(false) end
        ns.Safe("ahtab", Refresh)
    end)
    panel:SetScript("OnHide", function()
        local f = _G.AuctionHouseFrame
        if f then f:SetAlpha(1) end
    end)
end

local function ShowPanel()
    if not ns.db then return end
    if not panel then ns.Safe("ahtab", BuildPanel) end
    if not panel then return end
    local f = _G.AuctionHouseFrame
    ahOpen = (f and f:IsShown()) and true or false
    panel:Show()
end

------------------------------------------------------------------
-- Przycisk HUB przy prawej krawedzi okna AH
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
    -- zakladki innych (TSM itd.) tylko dostaja hook zamykajacy Hub; ich pozycji nie ruszamy
    for _, b in ipairs(CollectTabs(f)) do
        if not hooked[b] then
            hooked[b] = true
            b:HookScript("OnClick", HidePanel)
        end
    end
    -- HUB: kotwica wylacznie do ramki AH (X: mniej ujemne = bardziej w prawo)
    tabBtn:ClearAllPoints()
    tabBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, -30)
    tabBtn:SetFrameLevel(f:GetFrameLevel() + 5)
    tabBtn:Show()
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
        if panel and panel:IsShown() then panel:Hide() else ShowPanel() end
    end)
end

local function Setup()
    if not (ns.db and _G.AuctionHouseFrame) then return end
    local f = _G.AuctionHouseFrame
    ahOpen = true
    if not tabBtn then BuildTab() end
    PlaceTab()
    if not hooked.ahframe then
        hooked.ahframe = true
        f:HookScript("OnHide", function()
            ahOpen = false
            if panel and panel:IsShown() then panel:Hide() end
        end)
    end
    -- TSM dodaje swoja zakladke z opoznieniem: ustaw ponownie
    C_Timer.After(0.7, function() ns.Safe("ahtab", PlaceTab) end)
    C_Timer.After(2.5, function() ns.Safe("ahtab", PlaceTab) end)
    if ns.db.ahReplace ~= false then
        C_Timer.After(0.05, function() ns.Safe("ahtab", ShowPanel) end)   -- po tym, jak Blizzard pokaze swoje okno
    end
end

------------------------------------------------------------------
-- Ustawienia i zdarzenia
------------------------------------------------------------------
table.insert(ns.TOGGLES, { key = "ahReplace", label = "AH: Hub zastepuje okno aukcji (otwiera sie sam)",
    get = function() return ns.db.ahReplace ~= false end,
    set = function(v) ns.db.ahReplace = v and true or false end })

if ns.UpdateUI then
    hooksecurefunc(ns, "UpdateUI", function()
        if panel and panel:IsShown() then ns.Safe("ahtab", Refresh) end
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "ITEM_KEY_ITEM_INFO_RECEIVED", "BAG_UPDATE_DELAYED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(self, event, a1)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")
        if ns.db and ns.db.ahReplace == nil then ns.db.ahReplace = true end
    elseif event == "AUCTION_HOUSE_SHOW" then
        ns.Safe("ahtab", Setup)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        S.searching = false
        if panel and panel:IsShown() then panel:Hide() end
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
    elseif event == "BAG_UPDATE_DELAYED" then
        if panel and panel:IsShown() and not bagPending then
            bagPending = true
            C_Timer.After(0.3, function()
                bagPending = false
                if panel and panel:IsShown() then
                    ns.Safe("ahtab", RebuildBags)
                    ns.Safe("ahtab", Refresh)
                end
            end)
        end
    end
end)
