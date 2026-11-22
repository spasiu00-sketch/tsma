local ADDON, ns = ...

------------------------------------------------------------------
-- HUB w stylu Goldwright: jedno duze okno z zakladkami
--  * Sprzedaj: lista przedmiotow z toreb (wartosc, "NPC placi wiecej"), rynek (TSM + zywe oferty z AH),
--    presety ceny Szybko / Typowo / Cierpliwie, ilosc, czas, razem / prowizja / depozyt / zysk, przycisk Wystaw
--  * Moje aukcje: Twoje aktywne aukcje, status podbicia, zysk na szt., czas, Anuluj
--  * Lista (Watch.lua): obserwowane + zakupy w jednym miejscu (cel ceny = alert, ilosc); Dodaj z Luk cenowych jednym klikiem
--  * Luki cenowe: Kup / Sprzedaj za / Zysk / Zabierz / Sloty / Profit (TSM, TSM<->Blizz z BlizzData.lua)
-- Nie dotyka aplikacji zewnetrznej: dane Blizzarda tylko odczytuje (_G.TsmAnalizeBlizz).
------------------------------------------------------------------

local W, H = 980, 660
local BT_W = 340 / 24   -- szerokosc slupka godziny na wykresie "Najlepsza pora"
local PAGE_Y = -62

local GRAY, GREEN, YELLOW, RED, BLUE, WHITE, ORANGE =
    "|cff9aa0a6", "|cff33dd66", "|cffffcc33", "|cffff4040", "|cff33aaff", "|cffffffff", "|cffffa040"

local DEFAULTS = {
    hubAuto = false,          -- otwieraj Hub razem z AH
    hubTab = "sell",
    postDur = 3,              -- 1/2/3 = krotki/sredni/dlugi czas aukcji
    gapMinProfit = 20000,     -- Luki: min. zysk z jednego transportu (2g)
    durLabels = { "2h", "8h", "24h" },
}

local win
local view = "sell"
local pages, tabBtns, wheel = {}, {}, {}
local ahOpen = false
local live = {}               -- [itemID] = zywe oferty z AH
local searchLog = {}
local hubCache = {}
local lastSend = 0
local sell = { list = {}, offset = 0, cur = nil, price = nil, qty = 1, dur = 3, lastMsg = "", dirty = true }
local own = { offset = 0 }
local gaps = { mode = "tsm", kind = "reagent", rows = {}, offset = 0, running = false, token = 0, status = "" }

local ROWS_SELL, OWN_ROWS, GROWS = 15, 16, 15

local RefreshHub, RefreshList, RefreshDetail, RefreshTotals, RefreshOwn, RefreshGaps
local SelectSell, RebuildSell, RequestLive, StartGaps

------------------------------------------------------------------
-- Pomocnicze
------------------------------------------------------------------
local function tsm(src, s)
    if not ns.HasTSM() then return nil end
    local ok, v = pcall(TSM_API.GetCustomPriceValue, src, s)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil
end

local function keepRate() return 1 - (ns.Cut() or 5) / 100 end
local function itemId(s) return tonumber((s or ""):match("^i:(%d+)")) end
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function Tip(btn, text)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

local function Active(b, on)
    b.bg:SetColorTexture(on and 0.14 or 0.12, on and 0.30 or 0.13, on and 0.52 or 0.17, 1)
end

local function Label(parent, x, y, text, size, w, justify, noWrap)
    local fs = ns.MakeFS(parent, size or 10, justify)
    fs:SetPoint("TOPLEFT", x, y)
    if w then fs:SetWidth(w) end
    if noWrap then fs:SetWordWrap(false) end
    fs:SetText(text or "")
    return fs
end

local function Ago(sec)
    if sec < 60 then return "przed chwila" end
    if sec < 3600 then return math.floor(sec / 60) .. " min temu" end
    return math.floor(sec / 3600) .. " h temu"
end

local function SellTime(qty, d)
    local perDay = d and d.perDay and (d.perDay / (ns.db.perDayDiv or 1))
    if not perDay or perDay <= 0 then return "brak danych" end
    local rate = perDay * (ns.db.riskShare or 0.5)
    local days = qty / rate
    if days < 1 / 24 then return "ponizej godziny" end
    if days < 1 then return string.format("~%.0f h", days * 24) end
    return string.format("~%.1f dnia", days)
end

local function Blizz(s)
    local d = _G.TsmAnalizeBlizz
    local e = d and d.items and d.items[s]
    if e then return e.m, e.q end
    return nil
end

-- lekkie dane TSM do list (cache 90 s)
local function Light(s)
    local c = hubCache[s]
    local now = GetTime()
    if c and now - c.t < 90 then return c end
    c = { t = now, min = tsm("DBMinBuyout", s), market = tsm("DBMarket", s), vendor = tsm("vendorSell", s) }
    hubCache[s] = c
    return c
end

------------------------------------------------------------------
-- Torby
------------------------------------------------------------------
local function BagItems()
    local list, byId = {}, {}
    local C = _G.C_Container
    local getN = (C and C.GetContainerNumSlots) or _G.GetContainerNumSlots
    if not getN then return list end
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
    return list
end

function RebuildSell()
    local keep = keepRate()
    local out, total, skipped = {}, 0, 0
    for _, e in ipairs(BagItems()) do
        local L = Light(e.s)
        local unit = L.min or L.market
        if unit then
            e.unit, e.L = unit, L
            e.value = unit * e.qty * keep
            e.vendorMore = (L.vendor and L.vendor >= unit * keep) and true or false
            if not e.vendorMore then total = total + e.value end
            out[#out + 1] = e
        else
            skipped = skipped + 1
        end
    end
    table.sort(out, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.id < b.id
    end)
    sell.list, sell.total, sell.skipped, sell.dirty = out, total, skipped, false

    local keepCur
    if sell.cur then
        for _, e in ipairs(out) do
            if e.id == sell.cur.id then keepCur = e; break end
        end
    end
    if keepCur then
        sell.cur = keepCur
        if sell.qty > keepCur.qty or sell.justPosted then sell.qty = keepCur.qty; sell.qtyDirty = true end
    else
        sell.cur = nil
        if #out > 0 then
            local pick
            for _, e in ipairs(out) do
                if not e.vendorMore then pick = e; break end
            end
            SelectSell(pick or out[1], true)
        end
    end
    sell.justPosted = false
end

function SelectSell(e, noRefresh)
    sell.cur = e
    sell.price, sell.boxDirty, sell.qtyDirty = nil, true, true
    sell.qty = e and e.qty or 1
    if not e then return end
    if not noRefresh then
        if ns.db.selected ~= e.s then
            ns.Select(e.s)   -- odswiezy tez Hub przez UpdateUI
        else
            RefreshHub()
        end
    elseif ns.db.selected ~= e.s then
        ns.db.selected = e.s
    end
    RequestLive(e.id)
end

------------------------------------------------------------------
-- Zywe oferty z AH
------------------------------------------------------------------
------------------------------------------------------------------
-- Podaz i ceny wg godziny doby (wykres "Najlepsza pora wystawienia")
------------------------------------------------------------------
local function RecordSupply(id, total)
    local db = ns.db
    if not db or not total then return end
    db.supply = db.supply or {}
    local rec = db.supply[id]
    if not rec then
        rec = { h = {}, t = 0 }
        db.supply[id] = rec
        local n, oid, ot = 0, nil, nil
        for k, v in pairs(db.supply) do
            n = n + 1
            if k ~= id and (not ot or (v.t or 0) < ot) then oid, ot = k, v.t or 0 end
        end
        if n > 400 and oid then db.supply[oid] = nil end   -- limit rozmiaru zapisu
    end
    if time() - (rec.t or 0) < 600 then return end         -- jedna probka na 10 min
    local hr = tonumber(date("%H"))
    local b = rec.h[hr]
    if not b then b = { 0, 0 }; rec.h[hr] = b end
    b[1], b[2] = b[1] + total, b[2] + 1
    if b[2] > 30 then b[1], b[2] = b[1] * 29 / 30, 29 end  -- stare probki stopniowo wygasaja
    rec.t = time()
end

-- srednie odchylenie ceny min od sredniej doby, wg godziny (z historii; tylko godziny, w ktorych grasz)
local function HourProfile(s)
    local rec = ns.ChartRec and ns.ChartRec(s) or ns.db.items[s]
    if not (rec and rec.hist) then return nil end
    local byDay = {}
    for _, p in ipairs(rec.hist) do
        local v = p[2]
        if v and v > 0 then
            local k = date("%Y%m%d", p[1])
            local g = byDay[k]
            if not g then g = { pts = {}, sum = 0, n = 0 }; byDay[k] = g end
            local y = math.log(v)
            g.pts[#g.pts + 1] = { p[1], y }
            g.sum, g.n = g.sum + y, g.n + 1
        end
    end
    local hours, days = {}, 0
    for _, g in pairs(byDay) do
        if g.n >= 3 then
            days = days + 1
            local m = g.sum / g.n
            for _, q in ipairs(g.pts) do
                local h = tonumber(date("%H", q[1]))
                local b = hours[h]
                if not b then b = { 0, 0 }; hours[h] = b end
                b[1], b[2] = b[1] + (q[2] - m), b[2] + 1
            end
        end
    end
    if days < 2 then return nil end
    local out = {}
    for h = 0, 23 do
        local b = hours[h]
        if b and b[2] >= 2 then out[h] = math.exp(b[1] / b[2]) - 1 end
    end
    return out
end

local function Ingest(id, rows, commodity)
    table.sort(rows, function(a, b) return a.price < b.price end)
    local merged, last, total = {}, nil, 0
    for _, r in ipairs(rows) do
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
    live[id] = { t = time(), rows = merged, total = total, real = real, typical = typical,
        listings = #merged, commodity = commodity }
    RecordSupply(id, total)
end

local function OnCommodity(id)
    local AH = _G.C_AuctionHouse
    if not (AH and AH.GetNumCommoditySearchResults and id) then return end
    local n = AH.GetNumCommoditySearchResults(id) or 0
    local rows = {}
    for i = 1, math.min(n, 400) do
        local r = AH.GetCommoditySearchResultInfo(id, i)
        if r and r.unitPrice then
            rows[#rows + 1] = { price = r.unitPrice, qty = r.quantity or 1,
                own = (r.containsOwnerItem or (r.numOwnerItems or 0) > 0) and true or false }
        end
    end
    Ingest(id, rows, true)
end

local function OnItemResults(itemKey)
    local AH = _G.C_AuctionHouse
    local id = itemKey and itemKey.itemID
    if not (AH and AH.GetNumItemSearchResults and id) then return end
    local n = AH.GetNumItemSearchResults(itemKey) or 0
    local rows = {}
    for i = 1, math.min(n, 400) do
        local r = AH.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 then
            rows[#rows + 1] = { price = r.buyoutAmount, qty = r.quantity or 1, own = r.containsOwnerItem and true or false }
        end
    end
    Ingest(id, rows, false)
end

function RequestLive(id, force)
    if not id or not ahOpen then return end
    local AH = _G.C_AuctionHouse
    if not (AH and AH.SendSearchQuery and AH.MakeItemKey) then return end
    local lv = live[id]
    if not force and lv and time() - lv.t < 60 then return end
    local now = GetTime()
    if now - lastSend < 1.5 then
        C_Timer.After(1.6, function()
            if sell.cur and sell.cur.id == id then RequestLive(id, force) end
        end)
        return
    end
    lastSend = now
    searchLog[#searchLog + 1] = now
    pcall(AH.SendSearchQuery, AH.MakeItemKey(id), {}, true)
end

local function SearchesPerMinute()
    local now, n, keep = GetTime(), 0, {}
    for _, t in ipairs(searchLog) do
        if now - t < 60 then n = n + 1; keep[#keep + 1] = t end
    end
    searchLog = keep
    return n
end

------------------------------------------------------------------
-- Presety ceny: Szybko / Typowo / Cierpliwie
------------------------------------------------------------------
local function Presets(s, d, r)
    local lv = live[itemId(s)]
    local anchor = (lv and lv.real) or d.minbuy
    local ref = (r and r.sellRef) or d.market or d.recent
    anchor = anchor or ref
    if not anchor then return nil end
    local under = math.max(0, ns.db.undercut or 1)
    local fast = math.max(1, anchor - under)
    local typical = (lv and lv.typical) or ref or anchor
    if typical < fast then typical = fast end
    local patient = math.max(typical + 1, math.floor(typical * 1.10 + 0.5))
    return { fast = fast, typical = typical, patient = patient, anchor = anchor, ref = ref, under = under }
end

------------------------------------------------------------------
-- Wystawianie
------------------------------------------------------------------
local function DoPost()
    local e, c = sell.cur, sell.ctx
    if not (e and c) then return end
    local AH = _G.C_AuctionHouse
    if not (ahOpen and AH) then ns.Print("Otworz dom aukcyjny, zeby wystawiac."); return end
    local price = sell.price or (c.pr and c.pr.typical)
    local qty = math.max(0, math.min(sell.qty or 0, e.qty))
    if not price or price <= 0 or qty <= 0 then ns.Print("Podaj cene i ilosc."); return end
    if not (_G.ItemLocation and ItemLocation.CreateFromBagAndSlot) then ns.Print("Brak ItemLocation w tym kliencie."); return end
    local loc = ItemLocation:CreateFromBagAndSlot(e.bag, e.slot)
    if not (loc and loc:IsValid()) then
        ns.Print("Przedmiot zmienil miejsce w torbie - odswiezam liste.")
        sell.dirty = true
        RebuildSell()
        RefreshHub()
        return
    end
    local commodity = true
    if AH.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
        local st = AH.GetItemCommodityStatus(loc)
        if st == Enum.ItemCommodityStatus.Item then commodity = false end
    end
    local ok, err
    if commodity then
        ok, err = pcall(AH.PostCommodity, loc, sell.dur, qty, price)
    else
        ok, err = pcall(AH.PostItem, loc, sell.dur, qty, nil, price * qty)
    end
    if not ok then
        ns.Print("Nie udalo sie wystawic: " .. tostring(err))
        return
    end
    sell.lastMsg = string.format("Wystawiono %d x %s po %s za szt.", qty, ns.ItemName(e.s), ns.MoneyPlain(price))
    sell.justPosted = true
    sell.price, sell.boxDirty = nil, true
    live[e.id] = nil
    C_Timer.After(1.0, function() if sell.cur and sell.cur.id == e.id then RequestLive(e.id, true) end end)
end

------------------------------------------------------------------
-- Strona: SPRZEDAJ
------------------------------------------------------------------
local function AvgText(id)
    if ns.db.chartBlizz then
        local h = ns.db.blizzHist and ns.db.blizzHist["i:" .. id]
        local cut, sum, n = time() - 30 * 86400, 0, 0
        for _, p in ipairs(h or {}) do
            if p[1] >= cut and p[2] then sum, n = sum + p[2], n + 1 end
        end
        if n < 2 then return "" end
        return GRAY .. "sr. 30d: " .. ns.MoneyPlain(sum / n) .. "|r"
    end
    if not ns.ArchivePoints then return "" end
    local pts = ns.ArchivePoints(id)
    local cut, sum, n = time() - 30 * 86400, 0, 0
    for _, p in ipairs(pts or {}) do
        if p[1] >= cut and p[2] then sum, n = sum + p[2], n + 1 end
    end
    if n < 3 then return "" end
    return GRAY .. "srednia 30d: " .. ns.MoneyPlain(sum / n) .. "|r"
end

local function BestTimeHover(self)
    local d = self.data
    if not (d and self:IsMouseOver()) then
        if self.tipOn then GameTooltip:Hide(); self.tipOn = false end
        return
    end
    local cx = GetCursorPosition()
    local x = cx / self:GetEffectiveScale() - self:GetLeft()
    local h = math.floor((x - 2) / BT_W)
    if h < 0 or h > 23 then
        if self.tipOn then GameTooltip:Hide(); self.tipOn = false end
        return
    end
    if self.tipOn and self.tipH == h then return end
    self.tipOn, self.tipH = true, h
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(string.format("%02d:00-%02d:00", h, (h + 1) % 24), 1, 1, 1)
    if d.supply[h] then
        GameTooltip:AddLine(string.format("Podaz: ~%d ofert", math.floor(d.supply[h] + 0.5)), 0.8, 0.8, 0.8)
    else
        GameTooltip:AddLine("Podaz: brak zapisow", 0.5, 0.5, 0.5)
    end
    if d.price[h] then
        GameTooltip:AddLine(string.format("Cena: %+.1f%% wzgledem sredniej doby", d.price[h] * 100), 1, 0.82, 0)
    end
    GameTooltip:Show()
end

-- slupki = srednia podaz (z Twoich skanow AH) w danej godzinie, zolta linia = cena; zielone = najspokojniejsze 4 godziny
local function DrawBestTime(S, e)
    local bt = S.bt
    if not bt then return end
    for _, l in ipairs(bt.lines) do l:Hide() end
    if not e then
        for h = 1, 24 do
            bt.bars[h]:SetHeight(2)
            bt.bars[h]:SetColorTexture(0.2, 0.22, 0.27, 0.8)
        end
        bt.top:SetText("")
        S.btText:SetText("")
        bt.data = nil
        return
    end
    local sup = ns.db.supply and ns.db.supply[e.id]
    local avgS, maxS, nS, sumS = {}, 0, 0, 0
    if sup then
        for h = 0, 23 do
            local b = sup.h[h]
            if b and b[2] > 0 then
                local v = b[1] / b[2]
                avgS[h] = v
                nS, sumS = nS + 1, sumS + v
                if v > maxS then maxS = v end
            end
        end
    end
    local prof = HourProfile(e.s) or {}
    local meanS = (nS > 0) and (sumS / nS) or 0

    local lowSet, bestH, bestAvg = {}, nil, nil
    if nS >= 8 then
        for h0 = 0, 23 do
            local s, c = 0, 0
            for k = 0, 3 do
                local v = avgS[(h0 + k) % 24]
                if v then s, c = s + v, c + 1 end
            end
            if c >= 3 then
                local m = s / c
                if not bestAvg or m < bestAvg then bestAvg, bestH = m, h0 end
            end
        end
        if bestH and meanS > 0 and bestAvg < meanS * 0.95 then
            for k = 0, 3 do lowSet[(bestH + k) % 24] = true end
        else
            bestH = nil
        end
    end

    local nowH = tonumber(date("%H"))
    for h = 0, 23 do
        local tx = bt.bars[h + 1]
        local v = avgS[h]
        tx:SetHeight(v and math.max(2, v / maxS * 64) or 2)
        if not v then tx:SetColorTexture(0.2, 0.22, 0.27, 0.8)
        elseif lowSet[h] then tx:SetColorTexture(0.2, 0.7, 0.4, 0.95)
        elseif h == nowH then tx:SetColorTexture(0.45, 0.6, 0.95, 0.95)
        else tx:SetColorTexture(0.25, 0.35, 0.6, 0.9) end
    end

    local lo, hi, nP = nil, nil, 0
    for h = 0, 23 do
        local v = prof[h]
        if v then
            nP = nP + 1
            lo = lo and math.min(lo, v) or v
            hi = hi and math.max(hi, v) or v
        end
    end
    if nP >= 6 and hi > lo then
        local idx, px, py = 0, nil, nil
        for h = 0, 23 do
            local v = prof[h]
            if v then
                local x = 2 + h * BT_W + 6
                local y = 4 + (v - lo) / (hi - lo) * 60
                if px then
                    idx = idx + 1
                    local l = bt.lines[idx]
                    if not l then l = bt:CreateLine(nil, "OVERLAY"); bt.lines[idx] = l end
                    l:SetThickness(1.5)
                    l:SetColorTexture(1, 0.82, 0, 0.95)
                    l:SetStartPoint("BOTTOMLEFT", bt, px, py)
                    l:SetEndPoint("BOTTOMLEFT", bt, x, y)
                    l:Show()
                end
                px, py = x, y
            else
                px, py = nil, nil
            end
        end
    end

    bt.top:SetText(nS > 0 and (GRAY .. string.format("do ~%d ofert", math.floor(maxS + 0.5)) .. "|r") or "")
    bt.data = { supply = avgS, price = prof }

    local lines = {}
    if bestH then
        lines[#lines + 1] = GREEN .. string.format("Podaz najnizsza %d:00-%d:00 (%.0f%% ponizej sredniej): oferty schodza najszybciej.",
            bestH, (bestH + 4) % 24, (1 - bestAvg / meanS) * 100) .. "|r"
    elseif nS < 8 then
        lines[#lines + 1] = GRAY .. string.format("Podaz: zbieram dane (%d/24 godzin). Otwieraj AH i szukaj tego przedmiotu o roznych porach.", nS) .. "|r"
    else
        lines[#lines + 1] = GRAY .. "Podaz rowno rozlozona w ciagu doby - brak wyraznej luki." .. "|r"
    end
    if nP >= 6 then
        local hiH, loH
        for h = 0, 23 do
            local v = prof[h]
            if v then
                if v == hi then hiH = h end
                if v == lo then loH = h end
            end
        end
        lines[#lines + 1] = GRAY .. string.format("Cena najwyzsza ok. %d:00 (%+.1f%%), najnizsza ok. %d:00 (%+.1f%%)", hiH, hi * 100, loH, lo * 100) .. "|r"
    end
    S.btText:SetText(table.concat(lines, "\n"))
end

local function BuildSell(p)
    local S = {}
    p.S = S

    -- 1) lista
    Label(p, 12, 0, BLUE .. "1 · Wybierz|r", 11)
    S.rows = {}
    for i = 1, ROWS_SELL do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(262, 29)
        row:SetPoint("TOPLEFT", 8, -20 - (i - 1) * 30)
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
        row.name:SetWidth(224)
        row.name:SetWordWrap(false)
        row.sub = ns.MakeFS(row, 9)
        row.sub:SetPoint("TOPLEFT", 34, -16)
        row.sub:SetWidth(224)
        row.sub:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if self.e then SelectSell(self.e) end
        end)
        row:Hide()
        S.rows[i] = row
    end
    S.sum = Label(p, 12, -484, "", 10, 262, nil, true)

    -- 2) rynek
    local x = 284
    Label(p, x, 0, BLUE .. "2 · Rynek|r", 11)
    S.icon = p:CreateTexture(nil, "ARTWORK")
    S.icon:SetSize(36, 36)
    S.icon:SetPoint("TOPLEFT", x, -20)
    S.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    S.name = Label(p, x + 44, -20, "", 16, 290, nil, true)
    S.sub = Label(p, x + 44, -42, "", 10, 290, nil, true)

    S.searchBtn = ns.MakeButton(p, "Szukaj w AH", 96, 20)
    S.searchBtn:SetPoint("TOPLEFT", x + 244, 0)
    S.searchBtn:SetScript("OnClick", function()
        if sell.cur then RequestLive(sell.cur.id, true) end
    end)
    Tip(S.searchBtn, "Pobiera zywe oferty tego przedmiotu z domu aukcyjnego (AH musi byc otwarty).")

    Label(p, x, -70, GRAY .. "TYPOWA CENA|r", 9)
    Label(p, x + 112, -70, GRAY .. "NAJTANSZA REALNA|r", 9)
    Label(p, x + 232, -70, GRAY .. "OFERT (POZIOMOW)|r", 9)
    S.cTyp = Label(p, x, -83, "", 13, 108, nil, true)
    S.cReal = Label(p, x + 112, -83, "", 13, 116, nil, true)
    S.cList = Label(p, x + 232, -83, "", 13, 100, nil, true)
    S.cBz = Label(p, x, -102, "", 10, 340, nil, true)

    Label(p, x, -122, BLUE .. "Najtansze oferty|r", 11)
    S.liveNote = Label(p, x + 110, -124, "", 10, 230, "RIGHT", true)
    Label(p, x, -142, GRAY .. "Cena za szt.|r", 10)
    Label(p, x + 130, -142, GRAY .. "Ilosc|r", 10)
    Label(p, x + 200, -142, GRAY .. "Uwaga|r", 10)
    S.mrows = {}
    for i = 1, 6 do
        local y = -158 - (i - 1) * 18
        S.mrows[i] = {
            price = Label(p, x, y, "", 11, 124, nil, true),
            qty = Label(p, x + 130, y, "", 11, 64, nil, true),
            note = Label(p, x + 200, y, "", 10, 140, nil, true),
        }
    end

    -- historia cen (7d / 30d), jak w Goldwright
    Label(p, x, -270, BLUE .. "Historia cen|r", 11)
    S.avg = Label(p, x + 84, -272, "", 10, 96, nil, true)
    S.srcBtn = FlatButton(p, 78, 16)
    S.srcBtn:SetPoint("TOPLEFT", x + 182, -268)
    S.srcBtn:SetScript("OnClick", function()
        if ns.SetChartSource then ns.SetChartSource(not ns.db.chartBlizz) end
    end)
    Tip(S.srcBtn, "Zrodlo wykresow: TSMA (TSM + archiwum) albo Blizzard (AuctionEngine). Zrodla nie sa mieszane.")
    S.rangeBtns = {}
    for i, rg in ipairs({ { "7d", 7 * 86400 }, { "30d", 30 * 86400 } }) do
        local b = FlatButton(p, 36, 16)
        b:SetPoint("TOPLEFT", x + 264 + (i - 1) * 40, -268)
        b.text:SetText(rg[1])
        b.range = rg[2]
        b:SetScript("OnClick", function(self)
            S.chart.range = self.range
            ns.db.hubRange = self.range
            RefreshDetail()
        end)
        S.rangeBtns[i] = b
    end
    local chart = CreateFrame("Frame", nil, p, "BackdropTemplate")
    chart:SetSize(340, 80)
    chart:SetPoint("TOPLEFT", x, -288)
    chart:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    chart:SetBackdropColor(0.02, 0.03, 0.04, 0.9)
    chart.pool = {}
    chart.range = (ns.db and ns.db.hubRange) or (7 * 86400)
    chart.empty = ns.MakeFS(chart, 10, "CENTER")
    chart.empty:SetPoint("CENTER")
    chart.empty:SetText("|cff888888Brak historii tego przedmiotu|r")
    chart.hi = ns.MakeFS(chart, 10)
    chart.hi:SetPoint("TOPLEFT", 4, -3)
    chart.lo = ns.MakeFS(chart, 10)
    chart.lo:SetPoint("BOTTOMLEFT", 4, 3)
    chart.xl = ns.MakeFS(chart, 10, "RIGHT")
    chart.xl:SetPoint("BOTTOMRIGHT", -4, 3)
    chart.xl:SetTextColor(0.6, 0.6, 0.6)
    chart:EnableMouse(true)
    chart:SetScript("OnMouseUp", function(_, btn)
        if btn == "LeftButton" and ns.ToggleBigChart then ns.ToggleBigChart() end
    end)
    Tip(chart, "Kliknij, aby otworzyc duzy wykres (swiece, nakladki).")
    S.chart = chart

    -- najlepsza pora wystawienia: podaz wg godziny + linia ceny
    Label(p, x, -376, BLUE .. "Najlepsza pora wystawienia|r", 11)
    Label(p, x + 200, -378, GRAY .. "godziny wg Twojego czasu|r", 9, 140, "RIGHT", true)
    local bt = CreateFrame("Frame", nil, p, "BackdropTemplate")
    bt:SetSize(340, 72)
    bt:SetPoint("TOPLEFT", x, -392)
    bt:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    bt:SetBackdropColor(0.02, 0.03, 0.04, 0.9)
    bt.bars, bt.lines = {}, {}
    for h = 0, 23 do
        local tx = bt:CreateTexture(nil, "ARTWORK")
        tx:SetPoint("BOTTOMLEFT", 2 + h * BT_W, 2)
        tx:SetSize(12, 2)
        tx:SetColorTexture(0.2, 0.22, 0.27, 0.8)
        bt.bars[h + 1] = tx
    end
    bt.top = ns.MakeFS(bt, 9)
    bt.top:SetPoint("TOPLEFT", 4, -3)
    for _, h in ipairs({ 0, 6, 12, 18 }) do
        Label(p, x + 2 + h * BT_W, -466, GRAY .. h .. ":00|r", 9, 40, nil, true)
    end
    bt:EnableMouse(true)
    bt:SetScript("OnUpdate", BestTimeHover)
    S.bt = bt
    S.btText = Label(p, x, -480, "", 10, 340)
    S.risk = Label(p, 650, -372, "", 10, 318)

    -- 3) oferta
    local rx = 650
    Label(p, rx, 0, BLUE .. "3 · Twoja oferta|r", 11)
    S.presetBtns = {}
    local pdefs = { { "fast", "Szybko" }, { "typical", "Typowo" }, { "patient", "Cierpliwie" } }
    for i, def in ipairs(pdefs) do
        local b = FlatButton(p, 100, 44)
        b:SetPoint("TOPLEFT", rx + (i - 1) * 107, -20)
        b.key = def[1]
        b.text:SetPoint("CENTER", 0, 10)
        b.text:SetText(def[2])
        b.price = ns.MakeFS(b, 10, "CENTER")
        b.price:SetPoint("CENTER", 0, -8)
        b:SetScript("OnClick", function(self)
            local pr = sell.ctx and sell.ctx.pr
            if pr and pr[self.key] then
                sell.price, sell.boxDirty = pr[self.key], true
                RefreshDetail()
            end
        end)
        S.presetBtns[i] = b
    end
    S.hint = Label(p, rx, -70, "", 9, 318)

    Label(p, rx, -98, GRAY .. "Cena za szt. (wlasna, np. 2g 14s)|r", 10)
    S.priceBox = ns.MakeInput(p, 170)
    S.priceBox:SetPoint("TOPLEFT", rx + 6, -112)
    S.priceBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        sell.price = ns.ParseMoney(self:GetText())
        RefreshTotals()
    end)
    S.priceBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    S.pctHint = Label(p, rx + 186, -118, "", 10, 130, nil, true)

    Label(p, rx, -142, GRAY .. "Ilosc|r", 10)
    S.qtyBox = ns.MakeInput(p, 56)
    S.qtyBox:SetPoint("TOPLEFT", rx + 6, -156)
    S.qtyBox:SetNumeric(true)
    S.qtyBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        sell.qty = tonumber(self:GetText()) or 0
        RefreshTotals()
    end)
    S.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local all = ns.MakeButton(p, "Wszystko", 62, 22)
    all:SetPoint("TOPLEFT", rx + 72, -156)
    all:SetScript("OnClick", function()
        if sell.cur then sell.qty, sell.qtyDirty = sell.cur.qty, true; RefreshDetail() end
    end)

    Label(p, rx + 150, -142, GRAY .. "Czas trwania|r", 10)
    S.durBtns = {}
    for i = 1, 3 do
        local b = FlatButton(p, 52, 22)
        b:SetPoint("TOPLEFT", rx + 148 + (i - 1) * 56, -156)
        b:SetScript("OnClick", function()
            sell.dur = i
            ns.db.postDur = i
            RefreshTotals()
        end)
        S.durBtns[i] = b
    end

    S.warn = Label(p, rx, -188, "", 10, 318)

    S.t = {}
    local labels = { "Razem za oferte", "Prowizja AH", "Otrzymasz po sprzedazy", "Depozyt (wraca po sprzedazy)",
        "Czas sprzedazy przy tej cenie", "Zysk vs Twoj zakup" }
    for i, l in ipairs(labels) do
        local y = -232 - (i - 1) * 22
        Label(p, rx + 4, y, GRAY .. l .. "|r", 10, 180, nil, true)
        S.t[i] = Label(p, rx + 184, y, "", 11, 134, "RIGHT", true)
    end

    S.post = ns.MakeButton(p, "Wystaw", 318, 30)
    S.post:SetPoint("TOPLEFT", rx, -440)
    S.post:SetScript("OnClick", DoPost)
    S.msg = Label(p, rx, -478, "", 10, 318)
    S.hint2 = Label(p, rx, -508, GRAY .. "Jedna oferta na klikniecie, potem nastepny przedmiot jest gotowy.|r", 9, 318)

    wheel.sell = function(delta)
        sell.offset = math.max(0, sell.offset - delta * 3)
        RefreshList()
    end
end

function RefreshList()
    local p = pages.sell
    if not (p and p.S) then return end
    local S, list = p.S, sell.list
    sell.offset = math.min(sell.offset, math.max(0, #list - ROWS_SELL))
    for i = 1, ROWS_SELL do
        local row, e = S.rows[i], list[sell.offset + i]
        row.e = e
        if e then
            row:Show()
            row.icon:SetTexture(ns.ItemIcon(e.s))
            row.name:SetText(ns.ItemName(e.s) .. (e.qty > 1 and (" " .. GRAY .. "x" .. e.qty .. "|r") or ""))
            local sub = GRAY .. "okolo " .. ns.MoneyPlain(e.value) .. "|r"
            if e.vendorMore then sub = sub .. "   " .. ORANGE .. "NPC placi wiecej|r" end
            row.sub:SetText(sub)
            row.sel:SetShown(sell.cur and sell.cur.id == e.id or false)
        else
            row:Hide()
        end
    end
    S.sum:SetText(string.format("%d przedmiotow do sprzedazy  ·  okolo %s%s", #list, ns.MoneyPlain(sell.total or 0),
        (sell.skipped or 0) > 0 and ("  ·  bez ceny: " .. sell.skipped) or ""))
end

local function ClearDetail(S)
    S.name:SetText(GRAY .. "Brak przedmiotow do sprzedazy w torbach (z cena TSM).|r")
    S.sub:SetText("")
    S.icon:SetTexture(134400)
    S.cTyp:SetText("")
    S.cReal:SetText("")
    S.cList:SetText("")
    S.cBz:SetText("")
    S.liveNote:SetText("")
    S.hint:SetText("")
    S.risk:SetText("")
    S.warn:SetText("")
    S.msg:SetText(GRAY .. (sell.lastMsg or "") .. "|r")
    for _, r in ipairs(S.mrows) do r.price:SetText(""); r.qty:SetText(""); r.note:SetText("") end
    for _, t in ipairs(S.t) do t:SetText("") end
    for _, b in ipairs(S.presetBtns) do b.price:SetText(""); Active(b, false) end
    S.pctHint:SetText("")
    S.post:SetText("Wystaw")
    S.post:SetEnabled(false)
    ns.DrawChart(S.chart, nil)
    S.avg:SetText("")
    S.srcBtn.text:SetText(ns.ChartSourceText and ns.ChartSourceText() or "")
    DrawBestTime(S, nil)
end

function RefreshDetail()
    local p = pages.sell
    if not (p and p.S) then return end
    local S, e = p.S, sell.cur
    if not e then sell.ctx = nil; ClearDetail(S); return end

    local s = e.s
    local d = ns.cache[s] or ns.FetchTSM(s)
    local ok, r = pcall(ns.Analyze, s, d, (ns.EffectiveBuy(s, d)))
    if not ok or type(r) ~= "table" then r = { notes = {} } end
    local pr = Presets(s, d, r)
    sell.ctx = { d = d, r = r, pr = pr }

    local lv = live[e.id]
    S.icon:SetTexture(ns.ItemIcon(s))
    S.name:SetText(ns.ItemName(s))
    S.sub:SetText(GRAY .. "Masz " .. e.qty ..
        (lv and (lv.commodity and "  ·  towar: jedna oferta na dowolna ilosc" or "  ·  przedmiot: osobne aukcje") or "") .. "|r")

    S.cTyp:SetText(ns.Money(pr and pr.typical))
    S.cReal:SetText(ns.Money((lv and lv.real) or d.minbuy))
    S.cList:SetText(lv and tostring(lv.listings) or "|cff888888--|r")
    local bm, bq = Blizz(s)
    S.cBz:SetText(bm and (GRAY .. "Blizz AH: min |r" .. ns.Money(bm) .. GRAY .. "  x" .. tostring(bq or "?") .. "|r") or "")

    if lv then
        S.liveNote:SetText(GRAY .. "z AH " .. Ago(time() - lv.t) .. "|r")
    else
        S.liveNote:SetText(ahOpen and (ORANGE .. "kliknij Szukaj w AH|r") or (GRAY .. "dane TSM (AH zamkniety)|r"))
    end

    local mrows = S.mrows
    if lv then
        local typMarked, realMarked = false, false
        for i = 1, 6 do
            local m, row = lv.rows[i], mrows[i]
            if m then
                row.price:SetText(ns.Money(m.price))
                row.qty:SetText(tostring(m.qty))
                local note = ""
                if m.own then
                    note = ORANGE .. "Twoja aukcja|r"
                elseif not realMarked then
                    note = BLUE .. "najtansza realna|r"
                    realMarked = true
                end
                if not typMarked and lv.typical and m.price >= lv.typical then
                    note = (note ~= "" and (note .. ", ") or "") .. GRAY .. "typowa cena|r"
                    typMarked = true
                end
                row.note:SetText(note)
            else
                row.price:SetText(""); row.qty:SetText(""); row.note:SetText("")
            end
        end
    else
        local info = {
            { "Min. rynku (TSM)", d.minbuy }, { "DBMarket (~14d)", d.market }, { "Ostatnia (DBRecent)", d.recent },
            { "Sr. sprzedazy (region)", d.regionSale },
        }
        for i = 1, 6 do
            local row, it = mrows[i], info[i]
            if it then
                row.price:SetText(ns.Money(it[2]))
                row.qty:SetText("")
                row.note:SetText(GRAY .. it[1] .. "|r")
            else
                row.price:SetText(""); row.qty:SetText(""); row.note:SetText("")
            end
        end
    end

    if r.verdict and r.verdict ~= "NODATA" and r.risk then
        S.risk:SetText(GRAY .. "Ocena przy zakupie po " .. (r.buyIsOwn and "Twojej cenie" or "akt. min") .. ": |r" ..
            ns.VERDICT_SHORT[r.verdict] .. "   ryzyko " .. ns.RISK_TEXT[r.risk.level] ..
            (r.maxBuy and ("   kupuj do " .. ns.MoneyPlain(r.maxBuy)) or ""))
    else
        S.risk:SetText("")
    end
    ns.DrawChart(S.chart, s, r.breakEven, ns.db.alerts[s])
    for _, b in ipairs(S.rangeBtns) do Active(b, S.chart.range == b.range) end
    S.avg:SetText(AvgText(e.id))
    S.srcBtn.text:SetText(ns.ChartSourceText and ns.ChartSourceText() or "")
    Active(S.srcBtn, ns.db.chartBlizz and true or false)
    DrawBestTime(S, e)

    -- presety
    for _, b in ipairs(S.presetBtns) do
        b.price:SetText(pr and ns.Money(pr[b.key]) or "--")
    end
    if pr then
        S.hint:SetText(GRAY .. string.format("Szybko: %s pod najtansza %s (%s). Typowo: %s. Cierpliwie: +10%%.",
            ns.MoneyPlain(pr.under), lv and "realna" or "oferta", ns.MoneyPlain(pr.anchor),
            lv and "cena, przy ktorej schodzi ~20% podazy" or "cena odniesienia") .. "|r")
    else
        S.hint:SetText(GRAY .. "Brak ceny odniesienia - wpisz cene recznie.|r")
    end

    if sell.boxDirty or (sell.price == nil and not S.priceBox:HasFocus()) then
        local pv = sell.price or (pr and pr.typical)
        S.priceBox:SetText(pv and ns.MoneyPlain(pv) or "")
        S.priceBox:SetCursorPosition(0)
        sell.boxDirty = false
    end
    if sell.qtyDirty then
        S.qtyBox:SetText(tostring(math.min(sell.qty or e.qty, e.qty)))
        sell.qtyDirty = false
    end
    for i = 1, 3 do
        S.durBtns[i].text:SetText((ns.db.durLabels and ns.db.durLabels[i]) or tostring(i))
    end
    S.msg:SetText(GRAY .. (sell.lastMsg or "") .. "|r")
    RefreshTotals()
end

function RefreshTotals()
    local p = pages.sell
    if not (p and p.S) then return end
    local S, c, e = p.S, sell.ctx, sell.cur
    if not (e and c) then return end
    local db = ns.db
    local pr, d, r = c.pr, c.d, c.r
    local price = sell.price or (pr and pr.typical)
    local qty = math.max(0, math.min(sell.qty or 0, e.qty))

    for _, b in ipairs(S.presetBtns) do
        Active(b, pr and price and pr[b.key] == price or false)
    end
    for i, b in ipairs(S.durBtns) do Active(b, sell.dur == i) end

    S.post:SetText(string.format("Wystaw %d x %s", qty, ns.ItemName(e.s)))
    S.post:SetEnabled(ahOpen and price ~= nil and price > 0 and qty > 0)

    if not price or price <= 0 or qty <= 0 then
        for _, t in ipairs(S.t) do t:SetText("") end
        S.warn:SetText("")
        S.pctHint:SetText("")
        return
    end

    local keep = keepRate()
    local total = price * qty
    local cut = math.floor(total * (1 - keep) + 0.5)
    local recv = total - cut

    local dep, est = nil, true
    local AH = _G.C_AuctionHouse
    if ahOpen and AH and AH.CalculateCommodityDeposit then
        local ok, v = pcall(AH.CalculateCommodityDeposit, e.id, sell.dur, qty)
        if ok and type(v) == "number" then dep, est = v, false end
    end
    if not dep then dep = (ns.DepositPerUnit(d, e.s) or 0) * qty end

    S.t[1]:SetText(ns.Money(total))
    S.t[2]:SetText(ns.Money(-cut))
    S.t[3]:SetText(ns.Money(recv))
    S.t[4]:SetText(ns.Money(dep) .. (est and (GRAY .. " ~|r") or ""))
    local tt = SellTime(qty, d)
    if pr and price > pr.typical * 1.05 then tt = tt .. " " .. ORANGE .. "(wolniej)|r"
    elseif pr and price <= pr.fast then tt = tt .. " " .. GREEN .. "(szybko)|r" end
    S.t[5]:SetText(tt)
    local buy = db.buyPrice[e.s]
    if buy then
        local net = recv - buy * qty
        S.t[6]:SetText(ns.Money(net) .. string.format(" %s(%+.0f%%)|r", net >= 0 and GREEN or RED, net / (buy * qty) * 100))
    else
        S.t[6]:SetText("|cff888888brak ceny zakupu|r")
    end

    if pr and pr.typical > 0 then
        local diff = (price / pr.typical - 1) * 100
        S.pctHint:SetText(string.format("%s%+.0f%%|r %svs typowa|r", diff >= 0 and GREEN or ORANGE, diff, GRAY))
    end

    local warn = {}
    if buy then
        local be = math.ceil(buy / keep)
        if price < be then
            warn[#warn + 1] = RED .. "Cena PONIZEJ break-even (" .. ns.MoneyPlain(be) .. ") - sprzedasz ze strata.|r"
        end
    end
    if d.minbuy and price < d.minbuy * 0.5 then
        warn[#warn + 1] = ORANGE .. string.format("Cena to %.0f%% aktualnej min - literowka?|r", price / d.minbuy * 100)
    end
    local lv = live[e.id]
    if lv and lv.real and price > lv.real * 1.5 then
        warn[#warn + 1] = ORANGE .. "Cena 50%+ ponad najtansza realna - sprzedaz moze byc bardzo wolna.|r"
    end
    if e.L and e.L.vendor and e.L.vendor * qty > recv then
        warn[#warn + 1] = ORANGE .. "NPC placi wiecej: " .. ns.MoneyPlain(e.L.vendor * qty) .. " (AH po prowizji: " .. ns.MoneyPlain(recv) .. ").|r"
    end
    if not ahOpen then warn[#warn + 1] = GRAY .. "Otworz dom aukcyjny, zeby wystawiac.|r" end
    S.warn:SetText(table.concat(warn, "\n"))
end

------------------------------------------------------------------
-- Strona: MOJE AUKCJE
------------------------------------------------------------------
local function OwnedList()
    local out = {}
    local AH = _G.C_AuctionHouse
    if not (AH and AH.GetOwnedAuctions) then return out end
    local activeEnum = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active) or 0
    for _, a in ipairs(AH.GetOwnedAuctions() or {}) do
        local id = a.itemKey and a.itemKey.itemID
        if id and (a.status == nil or a.status == activeEnum) then
            out[#out + 1] = { id = id, s = "i:" .. id, qty = a.quantity or 1,
                price = a.buyoutAmount or a.bidAmount or 0, auctionID = a.auctionID,
                left = a.timeLeftSeconds, tl = a.timeLeft }
        end
    end
    return out
end

local TL_TEXT = { [0] = "<30 min", "<2 h", "<12 h", "<48 h" }
local function LeftText(a)
    if a.left and a.left > 0 then
        local h, m = math.floor(a.left / 3600), math.floor((a.left % 3600) / 60)
        if h > 0 then return string.format("%dh %dm", h, m) end
        return m .. " min"
    end
    return TL_TEXT[a.tl or -1] or "--"
end

local function BuildOwn(p)
    local S = {}
    p.S = S
    S.refresh = ns.MakeButton(p, "Odswiez", 80, 22)
    S.refresh:SetPoint("TOPLEFT", 10, 0)
    S.refresh:SetScript("OnClick", function()
        local AH = _G.C_AuctionHouse
        if ahOpen and AH and AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) else ns.Print("Otworz dom aukcyjny.") end
        RefreshOwn()
    end)
    S.info = Label(p, 100, -5, "", 10, 800, nil, true)

    local hx = { { "PRZEDMIOT", 8 }, { "ILOSC", 262 }, { "TWOJA CENA", 322 }, { "MIN. RYNKU", 438 }, { "STATUS", 556 },
        { "ZYSK / SZT.", 716 }, { "POZOSTALO", 828 } }
    for _, h in ipairs(hx) do Label(p, h[2], -32, GRAY .. h[1] .. "|r", 9) end

    S.rows = {}
    for i = 1, OWN_ROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(960, 24)
        row:SetPoint("TOPLEFT", 8, -48 - (i - 1) * 26)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
        row.name = Label(row, 4, -5, "", 11, 250, nil, true)
        row.qty = Label(row, 254, -5, "", 11, 50, "RIGHT", true)
        row.price = Label(row, 314, -5, "", 11, 110, nil, true)
        row.mkt = Label(row, 430, -5, "", 11, 110, nil, true)
        row.status = Label(row, 548, -5, "", 11, 156, nil, true)
        row.profit = Label(row, 708, -5, "", 11, 112, nil, true)
        row.left = Label(row, 820, -5, "", 11, 70, nil, true)
        row.cancel = ns.MakeButton(row, "Anuluj", 62, 20)
        row.cancel:SetPoint("RIGHT", -4, 0)
        row.cancel:SetScript("OnClick", function()
            local a = row.a
            local AH = _G.C_AuctionHouse
            if not (a and a.auctionID and AH and AH.CancelAuction and ahOpen) then ns.Print("Otworz dom aukcyjny."); return end
            pcall(AH.CancelAuction, a.auctionID)
            ns.Print("Anulowano: " .. ns.ItemLink(a.s))
            C_Timer.After(1.0, function()
                if AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) end
            end)
        end)
        row:SetScript("OnClick", function(self)
            if self.a then ns.Select(self.a.s) end
        end)
        row:Hide()
        S.rows[i] = row
    end
    wheel.auctions = function(delta)
        own.offset = math.max(0, own.offset - delta * 3)
        RefreshOwn()
    end
end

function RefreshOwn()
    local p = pages.auctions
    if not (p and p.S and view == "auctions") then return end
    local S = p.S
    local list = OwnedList()
    local keep = keepRate()
    for _, a in ipairs(list) do
        local L = Light(a.s)
        a.min = L.min
        a.under = (a.min and a.price > 0 and a.min < a.price) and true or false
    end
    table.sort(list, function(a, b)
        if a.under ~= b.under then return a.under end
        return ns.ItemName(a.s) < ns.ItemName(b.s)
    end)
    local nUnder, value = 0, 0
    for _, a in ipairs(list) do
        if a.under then nUnder = nUnder + 1 end
        value = value + a.price * a.qty
    end
    own.offset = math.min(own.offset, math.max(0, #list - OWN_ROWS))
    if not ahOpen and #list == 0 then
        S.info:SetText(ORANGE .. "Otworz dom aukcyjny, zeby wczytac swoje aukcje.|r")
    else
        S.info:SetText(string.format("%d aukcji  ·  podbitych: %s%d|r  ·  wartosc wystawionych: %s",
            #list, nUnder > 0 and ORANGE or GREEN, nUnder, ns.MoneyPlain(value)))
    end
    for i = 1, OWN_ROWS do
        local row, a = S.rows[i], list[own.offset + i]
        row.a = a
        if a then
            row:Show()
            row.name:SetText(ns.ItemName(a.s))
            row.qty:SetText(tostring(a.qty))
            row.price:SetText(ns.Money(a.price))
            row.mkt:SetText(ns.Money(a.min))
            if a.under then
                row.status:SetText(ORANGE .. string.format("podbita (+%.0f%% nad min)|r", (a.price / a.min - 1) * 100))
            else
                row.status:SetText(GREEN .. "najnizsza|r")
            end
            local buy = ns.db.buyPrice[a.s]
            if buy then
                local net = a.price * keep - buy
                row.profit:SetText((net >= 0 and (GREEN .. "+|r") or "") .. ns.Money(net))
            else
                row.profit:SetText("|cff888888--|r")
            end
            row.left:SetText(GRAY .. LeftText(a) .. "|r")
            row.cancel:SetEnabled(ahOpen)
        else
            row:Hide()
        end
    end
end

------------------------------------------------------------------
-- Strona: LUKI CENOWE
------------------------------------------------------------------
local function StackSize(id)
    local gi = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if gi then
        local res = { pcall(gi, id) }
        local st = res[9]
        if type(st) == "number" and st > 0 then return st end
    end
    return 20
end

-- reagent = materialy do craftingu (klasa przedmiotu 7); reszta = pojedyncze przedmioty
local function IsReagent(id)
    local gi = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not gi then return false end
    local ok, _, _, _, _, _, classID = pcall(gi, id)
    return ok and classID == 7
end

local function ApplyKind()
    if gaps.all then
        gaps.rows = gaps.all[gaps.kind] or {}
        gaps.offset = 0
    end
end

local function GapOne(id, mode, keep, share)
    local db = ns.db
    local s = "i:" .. id
    local rate = tsm("DBRegionSaleRate", s)
    if not rate then return nil end
    local perDay = tsm("DBRegionSoldPerDay", s)
    if not perDay then return nil end
    local minbuy = tsm("DBMinBuyout", s)
    local buy, sellp
    if mode == "tsm" then
        buy, sellp = minbuy, tsm("DBMarket", s) or tsm("DBRecent", s)
    else
        local bz = Blizz(s)
        if mode == "t2b" then buy, sellp = minbuy, bz else buy, sellp = bz, minbuy end
    end
    if not buy or not sellp or buy <= 0 then return nil end
    local net = sellp * keep - buy
    local gain = net / buy * 100
    if gain < (db.margin or 0) then return nil end
    local day = math.floor(perDay / (db.perDayDiv or 1) * share)
    if day < 1 then return nil end
    local stack = StackSize(id)
    local carry = day
    if stack > 1 and day >= stack then carry = math.floor(day / stack) * stack end
    local profit = carry * net
    if profit < (db.gapMinProfit or 0) then return nil end
    return { id = id, s = s, buy = buy, sell = sellp, gain = gain, carry = carry, upTo = carry * 2,
        slots = math.ceil(carry / stack), profit = profit, reagent = IsReagent(id) }
end

local function GapCandidates(mode)
    local list, seen = {}, {}
    local function add(id)
        if id and not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
    for _, s in ipairs(ns.db.watch) do add(itemId(s)) end
    for id in pairs(ns.arcNow or {}) do add(id) end
    if mode ~= "tsm" then
        local bz = _G.TsmAnalizeBlizz
        if bz and bz.items then
            for s in pairs(bz.items) do add(itemId(s)) end
        end
    end
    return list
end

function StartGaps()
    gaps.token = gaps.token + 1
    local token, mode = gaps.token, gaps.mode
    gaps.rows, gaps.offset, gaps.running, gaps.all = {}, 0, false, nil
    if not ns.HasTSM() then gaps.status = RED .. "TSM nie wykryte.|r"; return end
    if mode ~= "tsm" then
        local bz = _G.TsmAnalizeBlizz
        if not (bz and bz.items and next(bz.items)) then
            gaps.status = ORANGE .. "Brak danych Blizzarda (BlizzData.lua) - uzyj trybu TSM.|r"
            return
        end
    end
    local list = GapCandidates(mode)
    local rows, i = {}, 1
    gaps.rows, gaps.running = rows, true
    local keep = keepRate()
    local share = math.max(0.05, math.min(1, ns.db.riskShare or 0.5))
    local function step()
        if token ~= gaps.token then return end
        local t0 = debugprofilestop()
        while i <= #list and debugprofilestop() - t0 < 5 do
            local ok, g = pcall(GapOne, list[i], mode, keep, share)
            i = i + 1
            if ok and g then rows[#rows + 1] = g end
        end
        if i <= #list then
            gaps.status = string.format("Liczenie... %d / %d (znaleziono %d)", i - 1, #list, #rows)
            RefreshGaps()
            C_Timer.After(0, step)
        else
            table.sort(rows, function(a, b) return a.profit > b.profit end)
            -- reagenty: tylko pozycje, ktore rynek obraca w ilosciach (min. 20 szt. do zabrania); reszta to pojedyncze przedmioty
            local reag, single = {}, {}
            for _, g in ipairs(rows) do
                if g.reagent then
                    if g.carry >= 20 and #reag < 200 then reag[#reag + 1] = g end
                elseif #single < 200 then
                    single[#single + 1] = g
                end
            end
            gaps.all = { reagent = reag, item = single }
            ApplyKind()
            gaps.running = false
            gaps.status = GRAY .. string.format("%d reagentow, %d przedmiotow  ·  ceny z TSM%s  ·  sprawdz oferty w grze, zanim przeniesiesz towar",
                #reag, #single, mode ~= "tsm" and " i Blizzarda" or "") .. "|r"
            RefreshGaps()
        end
    end
    step()
end

local GAP_MODES = {
    { "tsm", "TSM: kup min, sprzedaj wg rynku", "Kup po aktualnej min (TSM), sprzedaj po cenie rynku DBMarket." },
    { "t2b", "Kup wg TSM, sprzedaj wg Blizz", "Kup po min z TSM, sprzedaj po min z Blizzarda (BlizzData.lua)." },
    { "b2t", "Kup wg Blizz, sprzedaj wg TSM", "Kup po min z Blizzarda, sprzedaj po min z TSM." },
}

local GAP_KINDS = {
    { "reagent", "Reagenty (crafting, hurt)", "Materialy do craftingu: sprzedawane na rynku w tysiacach, liczone w stosach." },
    { "item", "Przedmioty (sztuki)", "Pojedyncze przedmioty (ekwipunek, przepisy, itp.), sprzedawane po kilka sztuk." },
}

local function BuildGaps(p)
    local S = {}
    p.S = S
    S.modeBtns = {}
    local x = 10
    for i, m in ipairs(GAP_MODES) do
        local b = FlatButton(p, 236, 24)
        b:SetPoint("TOPLEFT", x, 0)
        x = x + 242
        b.text:SetText(m[2])
        b:SetScript("OnClick", function()
            gaps.mode = m[1]
            StartGaps()
            RefreshGaps()
        end)
        Tip(b, m[3])
        S.modeBtns[i] = b
    end
    local re = ns.MakeButton(p, "Przelicz", 80, 24)
    re:SetPoint("TOPLEFT", x + 4, 0)
    re:SetScript("OnClick", function() StartGaps(); RefreshGaps() end)

    S.kindBtns = {}
    local kx = 10
    for i, k in ipairs(GAP_KINDS) do
        local b = FlatButton(p, 200, 22)
        b:SetPoint("TOPLEFT", kx, -28)
        kx = kx + 206
        b.text:SetText(k[2])
        b:SetScript("OnClick", function()
            gaps.kind = k[1]
            ApplyKind()
            RefreshGaps()
        end)
        Tip(b, k[3])
        S.kindBtns[i] = b
    end

    S.desc = Label(p, 10, -56, GRAY .. "Zabierz = ile powinno sie sprzedac w ciagu jednej aukcji (do dobowej sprzedazy), w pelnych stosach. " ..
        "Tylko przedmioty z potwierdzonym popytem (sale rate z TSM). Dodaj = do Listy, grupa 'Wyprawa' (cel = alert ceny, ilosc = Zabierz).|r", 10, 950)

    local hx = { { "PRZEDMIOT", 28 }, { "KUP", 296 }, { "SPRZEDAJ ZA", 392 }, { "ZYSK", 490 }, { "ZABIERZ", 560 },
        { "SLOTY", 700 }, { "PROFIT", 750 } }
    for _, h in ipairs(hx) do Label(p, h[2], -84, GRAY .. h[1] .. "|r", 9) end

    S.rows = {}
    for i = 1, GROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(960, 24)
        row:SetPoint("TOPLEFT", 8, -100 - (i - 1) * 26)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 4, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name = Label(row, 28, -5, "", 11, 262, nil, true)
        row.buy = Label(row, 288, -5, "", 11, 96, "RIGHT", true)
        row.sell = Label(row, 386, -5, "", 11, 96, "RIGHT", true)
        row.gain = Label(row, 484, -5, "", 11, 60, "RIGHT", true)
        row.carry = Label(row, 552, -5, "", 11, 140, "RIGHT", true)
        row.slots = Label(row, 696, -5, "", 11, 40, "RIGHT", true)
        row.profit = Label(row, 742, -5, "", 11, 150, "RIGHT", true)
        row.add = ns.MakeButton(row, "Dodaj", 56, 20)
        row.add:SetPoint("RIGHT", -6, 0)
        row.add:SetScript("OnClick", function()
            local g = row.g
            if not g then return end
            local target = math.floor(g.buy * 1.03)
            if ns.ListAdd then ns.ListAdd(g.s, "Wyprawa", target, g.carry) end
            ns.Print(string.format("Dodano do Listy (grupa 'Wyprawa'): %dx %s, cel (alert) do %s.", g.carry,
                ns.ItemLink(g.s), ns.MoneyPlain(target)))
        end)
        row:SetScript("OnClick", function(self)
            if self.g then ns.Select(self.g.s) end
        end)
        row:Hide()
        S.rows[i] = row
    end
    S.status = Label(p, 10, -100 - GROWS * 26 - 6, "", 10, 950, nil, true)
    wheel.gaps = function(delta)
        gaps.offset = math.max(0, gaps.offset - delta * 3)
        RefreshGaps()
    end
end

function RefreshGaps()
    local p = pages.gaps
    if not (p and p.S and view == "gaps" and win and win:IsShown()) then return end
    local S = p.S
    for i, m in ipairs(GAP_MODES) do Active(S.modeBtns[i], gaps.mode == m[1]) end
    for i, k in ipairs(GAP_KINDS) do Active(S.kindBtns[i], gaps.kind == k[1]) end
    gaps.offset = math.min(gaps.offset, math.max(0, #gaps.rows - GROWS))
    for i = 1, GROWS do
        local row, g = S.rows[i], gaps.rows[gaps.offset + i]
        row.g = g
        if g then
            row:Show()
            row.icon:SetTexture(ns.ItemIcon(g.s))
            row.name:SetText(ns.ItemName(g.s))
            row.buy:SetText(ns.Money(g.buy))
            row.sell:SetText(ns.Money(g.sell))
            row.gain:SetText(string.format("%s%+.0f%%|r", GREEN, g.gain))
            row.carry:SetText(string.format("%d %s(do %d)|r", g.carry, GRAY, g.upTo))
            row.slots:SetText(tostring(g.slots))
            row.profit:SetText(ns.Money(g.profit))
        else
            row:Hide()
        end
    end
    S.status:SetText(gaps.status or "")
end

------------------------------------------------------------------
-- Okno, zakladki, stopka
------------------------------------------------------------------
local TABS = {
    { "sell", "Sprzedaj" }, { "auctions", "Moje aukcje" }, { "gaps", "Luki cenowe" },
    { "watch", "Lista / zakupy", embed = "TsmAnalizeWatch" },
    { "market", "Rynek", embed = "TsmAnalizeMarket" }, { "ml", "ML", embed = "TsmAnalizeML" },
    { "cfg", "Ustawienia" },
}
-- stare okna (Panel, Lista, Rynek, ML) zyja teraz wewnatrz Huba: ten sam kod, jedno miejsce, bez doku
local EMBED = {}
for _, tb in ipairs(TABS) do
    if tb.embed then EMBED[tb[1]] = tb.embed end
end
local switching = false
local dockSuppress = false   -- programowe ukrycie Listy przy HUD (nie zmienia ustawienia)
local hudListBtn
local returnTab, backBtn      -- skad wrocic przyciskiem Cofnij na HUD

local function HideEmbedded(except)
    switching = true
    for k, name in pairs(EMBED) do
        local f = _G[name]
        if f and k ~= except and f:IsShown() then f:Hide() end
    end
    switching = false
end

local function InitEmbedded()
    for k, name in pairs(EMBED) do
        local f = _G[name]
        if f then
            f:RegisterForDrag()   -- panele nie sa przeciagane osobno: kotwiczy je Hub
            f:HookScript("OnHide", function()
                if switching or dockSuppress then return end
                if f.dockedToHud then
                    -- X na Liscie przy HUD: zapamietaj, ze lista ma byc zamknieta
                    f.dockedToHud = false
                    ns.db.hudList = false
                    if hudListBtn then Active(hudListBtn, false) end
                    return
                end
                if win and win:IsShown() and view == k then win:Hide() end   -- X na panelu zamyka Hub
            end)
            f:Hide()
        end
    end
    ns.db.panelShown = false
    if ns.db.hudList == nil then ns.db.hudList = true end
end

------------------------------------------------------------------
-- Zakladka USTAWIENIA (pola z ns.FIELDS i przelaczniki z ns.TOGGLES, 3 kolumny)
------------------------------------------------------------------
local cfg = { inputs = {}, checks = {} }

local function LoadCfg()
    local db = ns.db
    for _, fld in ipairs(ns.FIELDS) do
        local b = cfg.inputs[fld.key]
        if b then
            local v = db[fld.key]
            b:SetText(fld.kind == "money" and ns.MoneyPlain(v) or tostring(v or ""))
            b:SetCursorPosition(0)
        end
    end
    for _, chk in ipairs(ns.TOGGLES) do
        local cb = cfg.checks[chk.key]
        if cb then
            local v
            if chk.get then v = chk.get() else v = db[chk.key] end
            cb:SetChecked(v and true or false)
        end
    end
end

local function ApplyCfg()
    local db = ns.db
    local errors = {}
    for _, fld in ipairs(ns.FIELDS) do
        local b = cfg.inputs[fld.key]
        if b then
            local ok = ns.SetField(fld, b:GetText())
            if not ok then errors[#errors + 1] = fld.label end
        end
    end
    for _, chk in ipairs(ns.TOGGLES) do
        local cb = cfg.checks[chk.key]
        if cb then
            local v = cb:GetChecked() and true or false
            if chk.set then chk.set(v) else db[chk.key] = v end
        end
    end
    if ns.ApplyScale then ns.ApplyScale() end
    ns.UpdateUI()
    if ns.UpdatePanel then ns.UpdatePanel() end
    if #errors > 0 then
        ns.Print("Niepoprawne wartosci (pominiete): " .. table.concat(errors, ", "))
    else
        ns.Print("Ustawienia zapisane.")
    end
    LoadCfg()
end

local function BuildCfg(p)
    local HIDE = { scanMinPrice = true, scanSkipHigh = true, scanRequireRate = true, scanSortDay = true }   -- skaner usuniety
    local FIELDS, TOGGLES = {}, {}
    for _, fl in ipairs(ns.FIELDS) do
        if not HIDE[fl.key] then FIELDS[#FIELDS + 1] = fl end
    end
    for _, tg in ipairs(ns.TOGGLES) do
        if not HIDE[tg.key] then TOGGLES[#TOGGLES + 1] = tg end
    end
    local perCol = math.ceil(#FIELDS / 3)
    local trows = math.ceil(#TOGGLES / 3)
    for i, fld in ipairs(FIELDS) do
        local col = math.floor((i - 1) / perCol)
        local row = (i - 1) % perCol
        local x0 = 10 + col * 318
        local y = -6 - row * 28
        Label(p, x0, y - 5, fld.label, 11, 192, nil, true)
        local box = ns.MakeInput(p, 100)
        box:SetPoint("TOPLEFT", x0 + 196, y)
        if fld.kind == "text" then box:SetMaxLetters(200) end
        cfg.inputs[fld.key] = box
    end
    local cy0 = -6 - perCol * 28 - 14
    for i, chk in ipairs(TOGGLES) do
        local col = math.floor((i - 1) / trows)
        local row = (i - 1) % trows
        local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", 8 + col * 318, cy0 - row * 26)
        local lbl = ns.MakeFS(p, 11)
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        lbl:SetWidth(282)
        lbl:SetWordWrap(false)
        lbl:SetText(chk.label)
        cfg.checks[chk.key] = cb
    end
    local save = ns.MakeButton(p, "Zastosuj", 110, 24)
    save:SetPoint("TOPLEFT", 10, cy0 - trows * 26 - 14)
    save:SetScript("OnClick", ApplyCfg)
end


local function RefreshFooter()
    if not win then return end
    local db = ns.db
    win.footer:SetText(string.format("Dom: %s (%s%%)   ·   TSM: %s   ·   AH: %s   ·   wyszukiwan AH w minucie: %d",
        db.house == "neutral" and "neutralny" or "frakcyjny", tostring(ns.Cut()),
        ns.lastRefresh and ("odswiezono " .. date("%H:%M", ns.lastRefresh)) or "jeszcze nie odswiezono",
        ahOpen and (GREEN .. "otwarty|r") or (ORANGE .. "zamkniety|r"), SearchesPerMinute()))
end

function RefreshHub()
    if not (win and win:IsShown()) then return end
    win:SetScale(ns.db.scale or 1)
    for k, b in pairs(tabBtns) do Active(b, k == view) end
    if view == "sell" then
        RefreshList()
        RefreshDetail()
    elseif view == "auctions" then
        RefreshOwn()
    elseif view == "gaps" then
        RefreshGaps()
    end
    RefreshFooter()
end

local function ShowTab(k)
    if k == "shop" then k = "watch" end   -- dawna zakladka Zakupy to teraz Lista
    local valid = false
    for _, tb in ipairs(TABS) do
        if tb[1] == k then valid = true end
    end
    if not valid then k = "sell" end
    view = k
    ns.db.hubTab = k
    for kk, pg in pairs(pages) do pg:SetShown(kk == k) end
    HideEmbedded(k)
    local name = EMBED[k]
    if name then
        local f = _G[name]
        if f then
            f.dockedToHud = false
            f:ClearAllPoints()
            f:SetPoint("TOP", win, "TOP", 0, -64)
            f:SetHeight(576)
            f:SetFrameStrata("DIALOG")
            f:SetFrameLevel(win:GetFrameLevel() + 20)
            f:Show()
        end
    elseif k == "sell" then
        if sell.dirty or #sell.list == 0 then RebuildSell() end
    elseif k == "auctions" then
        local AH = _G.C_AuctionHouse
        if ahOpen and AH and AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) end
    elseif k == "gaps" then
        if #gaps.rows == 0 and not gaps.running then StartGaps() end
    elseif k == "cfg" then
        LoadCfg()
    end
    RefreshHub()
end

local function BuildHub()
    local db = ns.db
    local f = CreateFrame("Frame", "TsmAnalizeHub", UIParent, "BackdropTemplate")
    win = f
    f:SetSize(W, H)
    local hp = db.hubPos
    if hp then f:SetPoint(hp[1], UIParent, hp[2], hp[3], hp[4]) else f:SetPoint("CENTER") end
    f:SetFrameStrata("DIALOG")
    ns.DarkBackdrop(f, 0.97)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local pt, _, rp, x, y = self:GetPoint()
        db.hubPos = { pt, rp, x, y }
    end)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeHub") end

    local title = ns.MakeFS(f, 15)
    title:SetPoint("TOPLEFT", 14, -9)
    title:SetText(BLUE .. "TSMA|r  Hub")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    -- zakladki
    local x = 14
    for _, tb in ipairs(TABS) do
        local b = FlatButton(f, 100, 24)
        b:SetPoint("TOPLEFT", x, -32)
        x = x + 104
        b.text:SetText(tb[2])
        b:SetScript("OnClick", function() ShowTab(tb[1]) end)
        tabBtns[tb[1]] = b
    end

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.25, 0.27, 0.32, 1)
    line:SetPoint("TOPLEFT", 12, -60)
    line:SetSize(W - 24, 1)

    for _, tb in ipairs(TABS) do
        if not tb.embed then
            local pg = CreateFrame("Frame", nil, f)
            pg:SetPoint("TOPLEFT", 6, PAGE_Y - 6)
            pg:SetSize(W - 12, H - 62 - 36)
            pg:Hide()
            pages[tb[1]] = pg
        end
    end
    BuildSell(pages.sell)
    BuildOwn(pages.auctions)
    BuildGaps(pages.gaps)
    BuildCfg(pages.cfg)

    f.footer = ns.MakeFS(f, 10)
    f.footer:SetPoint("BOTTOMLEFT", 14, 9)
    f.footer:SetWidth(W - 110)
    f.footer:SetWordWrap(false)
    f.footer:SetTextColor(0.55, 0.55, 0.55)

    f:SetScript("OnMouseWheel", function(_, delta)
        local h = wheel[view]
        if h then ns.Safe("hub", h, delta) end
    end)
    f:SetScript("OnShow", function()
        ahOpen = ahOpen or (_G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown()) and true or false
        sell.dirty = true
        sell.dur = ns.db.postDur or 3
        ns.Safe("hub", ShowTab, ns.db.hubTab or "sell")
    end)
    f:SetScript("OnHide", function()
        HideEmbedded(nil)
        GameTooltip:Hide()
    end)

    -- powrot do HUD (HUD i Hub nie wisza naraz)
    local hudBtn = ns.MakeButton(f, "HUD", 56, 20)
    hudBtn:SetPoint("BOTTOMRIGHT", -12, 6)
    hudBtn:SetScript("OnClick", function()
        f:Hide()
        if ns.frame then ns.frame:Show(); ns.db.shown = true end
    end)
    Tip(hudBtn, "Zamknij Hub i wroc do HUD (analiza wybranego przedmiotu).")
end

-- Lista (okno Watch) przy HUD: po /tsma HUD pokazuje liste obok siebie (zapamietywane); w Hubie ta sama lista jest zakladka
local function DockList(show)
    local f = _G.TsmAnalizeWatch
    local hud = ns.frame
    if not (f and hud) then return end
    dockSuppress = true
    if show then
        if not (win and win:IsShown()) then
            f:ClearAllPoints()
            f:SetPoint("TOPRIGHT", hud, "TOPLEFT", -4, 0)
            f:SetHeight(hud:GetHeight())
            f:SetFrameStrata("DIALOG")
            f.dockedToHud = true
            f:Show()
        end
    elseif f.dockedToHud then
        f.dockedToHud = false
        f:Hide()
    end
    dockSuppress = false
end

-- przyciski przy HUD: Hub (wszystkie funkcje w jednym oknie), Wykres, Lista
local function BuildHudButtons()
    local hud = ns.frame
    if not hud then return end
    local defs = {
        { "Hub", "Hub: Sprzedaj, Moje aukcje, Luki, Lista, Rynek, ML, Ustawienia", function() ns.ToggleHub() end },
        { "Wykres", "Duzy wykres (zakres, typ, nakladki, zrodlo w menu)", function() if ns.ToggleBigChart then ns.ToggleBigChart() end end },
        { "Lista", "Lista obserwowanych i zakupow obok HUD (klik w przedmiot = wykres)", function()
            ns.db.hudList = not ns.db.hudList
            DockList(ns.db.hudList)
            if hudListBtn then Active(hudListBtn, ns.db.hudList and true or false) end
        end },
    }
    for i, d in ipairs(defs) do
        local b = FlatButton(hud, 56, 28)
        b:SetPoint("TOPLEFT", hud, "TOPRIGHT", 2, -34 - (i - 1) * 32)
        b.text:SetText(GRAY .. d[1] .. "|r")
        b:SetScript("OnClick", d[3])
        Tip(b, d[2])
        if d[1] == "Lista" then hudListBtn = b end
    end
    Active(hudListBtn, ns.db.hudList and true or false)

    -- Cofnij: wraca do Listy w Hubie (widoczny tylko po przeskoku z Listy)
    backBtn = ns.MakeButton(hud, "< Cofnij", 76, 20)
    backBtn:SetPoint("TOPLEFT", hud, "TOPLEFT", 62, -6)
    backBtn:SetScript("OnClick", function() ns.BackToHub() end)
    Tip(backBtn, "Wroc do Listy (Hub)")
    backBtn:SetShown(returnTab ~= nil)

    hud:HookScript("OnShow", function()
        if backBtn then backBtn:SetShown(returnTab ~= nil) end
        if ns.db.hudList then DockList(true) end
    end)
    hud:HookScript("OnHide", function()
        returnTab = nil
        if backBtn then backBtn:Hide() end
        DockList(false)
    end)
    if hud:IsShown() and ns.db.hudList then DockList(true) end
end

-- klik w przedmiot na Liscie w Hubie: przejdz do malego okna (HUD) z analiza; przycisk Cofnij wraca do Listy
function ns.ListJump()
    if not (win and win:IsShown() and view == "watch" and ns.frame) then return end
    if ns.db.listJump == false then return end
    returnTab = "watch"
    win:Hide()
    ns.db.shown = true
    ns.frame:Show()
    if backBtn then backBtn:Show() end
end

function ns.BackToHub()
    local tab = returnTab or "watch"
    returnTab = nil
    if backBtn then backBtn:Hide() end
    ns.ShowHub(tab)
end

function ns.ShowHub(tab)
    if not win then return end
    if tab then ns.db.hubTab = tab end
    if win:IsShown() then ShowTab(ns.db.hubTab or "sell") else win:Show() end
end

function ns.ToggleHub(tab)
    if not win then return end
    if win:IsShown() and (not tab or tab == view) then win:Hide() else ns.ShowHub(tab) end
end

-- stare punkty wejscia (komendy, minimapa, przyciski) prowadza do zakladek Huba
function ns.DockSelect(key) ns.ToggleHub(key) end
function ns.ShowPanel() ns.ShowHub() end            -- dawny panel Okazje/Dziennik/Craft zostal usuniety
function ns.TogglePanel() ns.ToggleHub() end
function ns.ToggleConfig() ns.ToggleHub("cfg") end
function ns.ToggleWatchMenu() ns.ToggleHub("watch") end

------------------------------------------------------------------
-- Zdarzenia, ustawienia, komendy
------------------------------------------------------------------
local bagPending = false
local function OnBags()
    sell.dirty = true
    if not (win and win:IsShown()) or bagPending then return end
    bagPending = true
    C_Timer.After(0.3, function()
        bagPending = false
        if win and win:IsShown() then
            RebuildSell()
            RefreshHub()
        end
    end)
end

local function OnEvent(event, a1)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        if ns.db.hubAuto and win then ns.ShowHub("sell") end
        if win and win:IsShown() then
            if view == "sell" then
                if sell.cur then RequestLive(sell.cur.id) end
            elseif view == "auctions" then
                local AH = _G.C_AuctionHouse
                if AH and AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) end
            end
            RefreshHub()
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        RefreshHub()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodity(a1)
        if view == "sell" then RefreshHub() end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnItemResults(a1)
        if view == "sell" then RefreshHub() end
    elseif event == "OWNED_AUCTIONS_UPDATED" or event == "AUCTION_CANCELED" then
        if view == "auctions" then RefreshHub() end
    elseif event == "BAG_UPDATE_DELAYED" then
        OnBags()
    end
end

hooksecurefunc(ns, "UpdateUI", function()
    ns.Safe("hub", function()
        -- zmiana wyboru w HUD na przedmiot z toreb przenosi sie do zakladki Sprzedaj
        local sel = ns.db and ns.db.selected
        if sel and (not sell.cur or sell.cur.s ~= sel) then
            for _, e in ipairs(sell.list) do
                if e.s == sel then
                    sell.cur, sell.price, sell.boxDirty, sell.qtyDirty, sell.qty = e, nil, true, true, e.qty
                    RequestLive(e.id)
                    break
                end
            end
        end
        RefreshHub()
    end)
end)

if ns.RefreshAll then
    hooksecurefunc(ns, "RefreshAll", function() wipe(hubCache) end)
end

table.insert(ns.FIELDS, { key = "gapMinProfit", label = "Luki: min. zysk z transportu", kind = "money", min = 0, max = 1e10 })
table.insert(ns.TOGGLES, { key = "hubAuto", label = "Hub: otwieraj razem z domem aukcyjnym" })
table.insert(ns.TOGGLES, { key = "listJump", label = "Lista w Hubie: klik w przedmiot otwiera HUD (przycisk Cofnij)",
    get = function() return ns.db.listJump ~= false end,
    set = function(v) ns.db.listJump = v and true or false end })

local function HubCommand(rest)
    local v = trim(rest):lower()
    if v:match("^dur") then
        local labels = {}
        for w in v:gmatch("%S+") do
            if w ~= "dur" then labels[#labels + 1] = w end
        end
        if #labels == 3 then
            ns.db.durLabels = labels
            ns.Print("Czasy aukcji: " .. table.concat(labels, ", ") .. " (kolejnosc: krotki, sredni, dlugi)")
            RefreshHub()
        else
            ns.Print("Uzycie: /tsma hub dur 12h 24h 48h   (trzy etykiety dla przyciskow czasu aukcji)")
        end
        return
    end
    local map = { sell = "sell", sprzedaj = "sell", auctions = "auctions", aukcje = "auctions", shop = "watch",
        zakupy = "watch", gaps = "gaps", luki = "gaps", lista = "watch",
        watch = "watch", rynek = "market", market = "market", ml = "ml", cfg = "cfg", ustawienia = "cfg" }
    ns.ToggleHub(map[v])
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if (cmd == "hub" or cmd == "goldwright") and ns.db and win then
        HubCommand(rest)
    elseif origSlash then
        origSlash(msg)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, a1)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON or not ns.db then return end
        self:UnregisterEvent("ADDON_LOADED")
        ns.Safe("hub", function()
            local db = ns.db
            for k, v in pairs(DEFAULTS) do
                if db[k] == nil then db[k] = (type(v) == "table") and CopyTable(v) or v end
            end
            sell.dur = db.postDur or 3
        end)
        ns.Safe("hub", BuildHub)
        ns.Safe("hub", InitEmbedded)
        ns.Safe("hub", BuildHudButtons)
        for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED",
            "ITEM_SEARCH_RESULTS_UPDATED", "OWNED_AUCTIONS_UPDATED", "AUCTION_CANCELED", "BAG_UPDATE_DELAYED" }) do
            pcall(self.RegisterEvent, self, e)
        end
        return
    end
    ns.Safe("hub", OnEvent, event, a1)
end)
