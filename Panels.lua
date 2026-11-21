local ADDON, ns = ...

local ROWS, ROW_H = 15, 24
local PANEL_W = 350
local ROWS_TOP_SCAN, ROWS_TOP_LOG = -214, -236   -- w dzienniku podsumowanie jest wyzsze

ns.panelMode = "scan"   -- "scan" | "log" | "craft"
local logOffset = 0

------------------------------------------------------------------
-- Panel boczny: Okazje (skaner) + Dziennik + Craft
------------------------------------------------------------------
local function UpdateRows(entries, offset, render)
    local p = ns.panel
    for i = 1, ROWS do
        local row = p.rows[i]
        local e = entries[offset + i]
        if e then
            local left, right, s = render(e)
            row.left:SetText(left)
            row.right:SetText(right)
            row.s = s
            row:Show()
        else
            row.s = nil
            row:Hide()
        end
    end
end

local KIND_TEXT = {
    buy     = "|cff4da6ffKUP|r",
    sell    = "|cff33dd66SPRZ|r",
    post    = "|cffffcc33WYST|r",
    expired = "|cffff4040WYGAS|r",
}

-- wpisy dziennika od najnowszego (opcjonalnie tylko biezaca postac)
local function LogEntries()
    local db = ns.db
    local me = db.logCharOnly and ns.Who() or nil
    local entries = {}
    for i = #db.log, 1, -1 do
        local e = db.log[i]
        if not me or e.c == me then entries[#entries + 1] = e end
    end
    return entries
end

-- wyniki skanu, ktore sa opłacalnym craftem (zysk oczekiwany > 0 i zysk >= margines), od najwiekszego zysku/szt.
local function CraftEntries()
    local margin = ns.db.margin or 0
    local t = {}
    for _, e in ipairs(ns.scan.results) do
        if e.craftProfit and e.craftPct and e.craftPct >= margin and e.craftExp and e.craftExp > 0 then
            t[#t + 1] = e
        end
    end
    table.sort(t, function(a, b) return a.craftProfit > b.craftProfit end)
    return t
end

local function ModeEntries()
    if ns.panelMode == "log" then return LogEntries() end
    if ns.panelMode == "craft" then return CraftEntries() end
    return ns.scan.results
end

local function UpdatePanelInner()
    local p = ns.panel
    if not p or not p:IsShown() then return end
    local db = ns.db
    local sc = ns.scan
    local mode = ns.panelMode

    p.scanTab:SetEnabled(mode ~= "scan")
    p.logTab:SetEnabled(mode ~= "log")
    p.craftTab:SetEnabled(mode ~= "craft")

    local isScanLike = mode ~= "log"
    local top = isScanLike and ROWS_TOP_SCAN or ROWS_TOP_LOG
    if p.rowsTop ~= top then
        p.rowsTop = top
        for i = 1, ROWS do
            p.rows[i]:ClearAllPoints()
            p.rows[i]:SetPoint("TOPLEFT", 14, top - (i - 1) * ROW_H)
        end
    end

    -- przycisk trybu: sortowanie (okazje) / filtr postaci (dziennik) / brak (craft)
    if mode == "scan" then
        p.sortBtn:Show()
        p.sortBtn:SetText(db.scanSortDay and "Sort: zysk/d" or "Sort: % zysku")
    elseif mode == "log" then
        p.sortBtn:Show()
        p.sortBtn:SetText(db.logCharOnly and "Ta postac" or "Wsz. postacie")
    else
        p.sortBtn:Hide()
    end
    p.scanGroup:SetShown(isScanLike)
    p.logGroup:SetShown(not isScanLike)

    if isScanLike then
        p.summary:SetText("")
        local entries = ModeEntries()
        if sc.running then
            p.status:SetText(string.format("Skanuje... %d / %d", sc.i, sc.total))
        elseif mode == "craft" then
            if #entries > 0 then
                p.status:SetText(string.format("Craft: %d pozycji wg zysku na sztuke (z ostatniego skanu, zakres: %s). Klik = analiza.",
                    #entries, (sc.scope == "" and "obserwowane") or sc.scope))
            elseif sc.total > 0 then
                p.status:SetText("Brak oplacalnych craftow w ostatnim skanie (potrzebne: Crafting z TSM, zysk >= min. zysk).")
            else
                p.status:SetText("Wpisz zakres (grupa TSM z recepturami albo *) i nacisnij Skanuj.")
            end
        elseif #sc.results > 0 then
            p.status:SetText(string.format("Okazji: %d (zakres: %s). Klik = analiza, kolko = przewijanie. Ryzyko: N/S/W.",
                #sc.results, (sc.scope == "" and "obserwowane") or sc.scope))
        elseif sc.total > 0 then
            p.status:SetText("Brak okazji spelniajacych warunki (zysk oczekiwany, ryzyko, sale rate, min. cena).")
        else
            p.status:SetText("Wpisz zakres i nacisnij Skanuj.")
        end
        local maxOff = math.max(0, #entries - ROWS)
        sc.offset = math.min(sc.offset or 0, maxOff)
        if mode == "craft" then
            UpdateRows(entries, sc.offset, function(e)
                local risk = ns.RISK_LETTER[e.risk or "MED"] .. " "
                local col = e.craftPct >= 50 and "|cff33dd66" or "|cffffcc33"
                return risk .. ns.ItemName(e.s), string.format("%s%+.0f%%|r %s", col, e.craftPct, ns.Money(e.craftProfit)), e.s
            end)
        else
            UpdateRows(entries, sc.offset, function(e)
                local tag = (e.mode == "craft") and "|cffa0a0ff[C]|r " or ""
                local risk = ns.RISK_LETTER[e.risk or "MED"] .. " "
                local col = e.pct >= 50 and "|cff33dd66" or "|cffffcc33"
                local right
                if db.scanSortDay and e.score then
                    right = string.format("%s%+.0f%%|r %s/d", col, e.pct, ns.Money(e.score))
                else
                    right = string.format("%s%+.0f%%|r %s", col, e.pct, ns.Money(e.profit))
                end
                return risk .. tag .. ns.ItemName(e.s), right, e.s
            end)
        end
    else
        local profit, spent, sells, lost = ns.LedgerSummary(db.logCharOnly)
        local s = db.selected
        local info = s and ("Przedmiot: " .. ns.ItemName(s)) or "Wybierz przedmiot w HUD."
        local lot = s and db.lots[s]
        if lot then
            info = info .. string.format("\nStan: %d szt., sr. koszt %s", lot.qty, ns.Money(db.buyPrice[s]))
        end
        p.logInfo:SetText(info)
        p.summary:SetText(string.format("%s: %s   Wydano: %s\nSprzedazy: %d   Utracone depozyty: %s\n%s",
            db.logCharOnly and "Zysk (ta postac)" or "Zysk netto",
            ns.Money(profit), ns.Money(spent), sells, ns.Money(lost), ns.AccuracyLine()))

        local entries = LogEntries()
        local maxOff = math.max(0, #entries - ROWS)
        logOffset = math.min(logOffset, maxOff)
        UpdateRows(entries, logOffset, function(e)
            local left = string.format("%s %s %dx %s", date("%d.%m %H:%M", e.t), KIND_TEXT[e.kind] or e.kind,
                e.qty, ns.ItemName(e.s))
            local right = ns.Money(e.price)
            if e.profit then
                right = right .. "  " .. (e.profit >= 0 and "|cff33dd66+|r" or "") .. ns.Money(e.profit)
            end
            if e.real then right = right .. " |cff9aa0a6P|r" end   -- P = przychod potwierdzony faktura z poczty
            return left, right, e.s
        end)
    end
end

function ns.UpdatePanel()
    ns.Safe("panel", UpdatePanelInner)
end

function ns.ShowPanel(mode)
    local p = ns.panel
    if not p then return end
    if mode then ns.panelMode = mode end
    p:Show()
    ns.db.panelShown = true
    ns.UpdatePanel()
end

function ns.TogglePanel()
    local p = ns.panel
    if not p then return end
    if p:IsShown() then
        p:Hide()
        ns.db.panelShown = false
    else
        ns.ShowPanel()
    end
end

local function BuildPanel()
    local db = ns.db
    local p = CreateFrame("Frame", "TsmAnalizePanel", UIParent, "BackdropTemplate")
    ns.panel = p
    p:SetScale(db.scale or 1)   -- ta sama skala co HUD (ApplyScale w UI.lua ustawia obie)
    p:SetSize(PANEL_W, ns.frame and ns.frame:GetHeight() or 660)
    p:SetPoint("TOPLEFT", ns.frame, "TOPRIGHT", 4, 0)
    ns.DarkBackdrop(p, 0.93)
    p:EnableMouse(true)
    p:EnableMouseWheel(true)
    p:SetShown(db.panelShown)

    local title = ns.MakeFS(p, 14)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("|cff33aaffTSMA|r  Okazje, dziennik, craft")

    p.scanTab = ns.MakeButton(p, "Okazje", 70, 22)
    p.scanTab:SetPoint("TOPLEFT", 14, -32)
    p.scanTab:SetScript("OnClick", function() ns.panelMode = "scan"; ns.scan.offset = 0; ns.UpdatePanel() end)

    p.logTab = ns.MakeButton(p, "Dziennik", 70, 22)
    p.logTab:SetPoint("LEFT", p.scanTab, "RIGHT", 4, 0)
    p.logTab:SetScript("OnClick", function() ns.panelMode = "log"; ns.UpdatePanel() end)

    p.craftTab = ns.MakeButton(p, "Craft", 56, 22)
    p.craftTab:SetPoint("LEFT", p.logTab, "RIGHT", 4, 0)
    p.craftTab:SetScript("OnClick", function() ns.panelMode = "craft"; ns.scan.offset = 0; ns.UpdatePanel() end)

    -- jeden przycisk, dwie funkcje: sortowanie skanera (Okazje) albo filtr postaci (Dziennik)
    p.sortBtn = ns.MakeButton(p, "Sort: % zysku", 92, 22)
    p.sortBtn:SetPoint("LEFT", p.craftTab, "RIGHT", 4, 0)
    p.sortBtn:SetScript("OnClick", function()
        if ns.panelMode == "log" then
            db.logCharOnly = not db.logCharOnly
            logOffset = 0
        else
            db.scanSortDay = not db.scanSortDay
            ns.SortScan()
        end
        ns.UpdatePanel()
    end)

    -- grupa: skaner (wspolna dla Okazji i Craft)
    local sg = CreateFrame("Frame", nil, p)
    sg:SetPoint("TOPLEFT", 0, -60)
    sg:SetSize(PANEL_W, 100)
    p.scanGroup = sg

    local scopeLbl = ns.MakeFS(sg, 10)
    scopeLbl:SetPoint("TOPLEFT", 14, 0)
    scopeLbl:SetWidth(PANEL_W - 28)
    scopeLbl:SetText("|cff9aa0a6Zakres: puste = obserwowane, * = wszystkie grupy TSM, albo sciezka grupy TSM.|r")

    local scopeBox = ns.MakeInput(sg, 220)
    scopeBox:SetPoint("TOPLEFT", 20, -30)
    scopeBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        ns.StartScan(self:GetText())
    end)
    p.scopeBox = scopeBox

    local scanBtn = ns.MakeButton(sg, "Skanuj", 80, 22)
    scanBtn:SetPoint("LEFT", scopeBox, "RIGHT", 8, 0)
    scanBtn:SetScript("OnClick", function() ns.StartScan(scopeBox:GetText()) end)

    p.status = ns.MakeFS(sg, 10)
    p.status:SetPoint("TOPLEFT", 14, -60)
    p.status:SetWidth(PANEL_W - 28)

    -- grupa: dziennik
    local lg = CreateFrame("Frame", nil, p)
    lg:SetPoint("TOPLEFT", 0, -60)
    lg:SetSize(PANEL_W, 100)
    p.logGroup = lg

    p.logInfo = ns.MakeFS(lg, 11)
    p.logInfo:SetPoint("TOPLEFT", 14, 0)
    p.logInfo:SetWidth(PANEL_W - 28)

    local qtyLbl = ns.MakeFS(lg, 10)
    qtyLbl:SetPoint("TOPLEFT", 14, -34)
    qtyLbl:SetText("|cff9aa0a6Ilosc    Cena za szt. (przy Wygaslych: depozyt za szt.):|r")

    local qtyBox = ns.MakeInput(lg, 50)
    qtyBox:SetPoint("TOPLEFT", 20, -46)
    qtyBox:SetNumeric(true)
    local priceBox = ns.MakeInput(lg, 130)
    priceBox:SetPoint("LEFT", qtyBox, "RIGHT", 12, 0)

    local function Trade(kind)
        local s = ns.db.selected
        if not s then ns.Print("Najpierw wybierz przedmiot."); return end
        local qty = tonumber(qtyBox:GetText())
        local price = ns.ParseMoney(priceBox:GetText())
        local d = ns.cache[s]
        if not price and kind == "buy" then
            price = d and d.minbuy
        elseif not price and kind == "expired" then
            price = ns.DepositPerUnit(d or ns.FetchTSM(s), s)
        end
        if not qty or qty <= 0 or not price then
            ns.Print("Podaj ilosc i cene za sztuke (np. 5g 20s).")
            return
        end
        if kind == "buy" then
            ns.Buy(s, qty, price)
        elseif kind == "sell" then
            local ok, res = ns.Sell(s, qty, price)
            if not ok then ns.Print(res); return end
        elseif kind == "expired" then
            ns.Expire(s, qty, price)
        else
            ns.Post(s, qty, price)
        end
        qtyBox:SetText("")
        priceBox:SetText("")
        qtyBox:ClearFocus()
        priceBox:ClearFocus()
        if ns.onSelect then ns.onSelect(s) end
        ns.UpdateUI()
        ns.UpdatePanel()
    end

    local b1 = ns.MakeButton(lg, "Kupione", 78, 22)
    b1:SetPoint("TOPLEFT", 14, -74)
    b1:SetScript("OnClick", function() Trade("buy") end)
    local b2 = ns.MakeButton(lg, "Sprzedane", 78, 22)
    b2:SetPoint("LEFT", b1, "RIGHT", 4, 0)
    b2:SetScript("OnClick", function() Trade("sell") end)
    local b3 = ns.MakeButton(lg, "Wystaw.", 78, 22)
    b3:SetPoint("LEFT", b2, "RIGHT", 4, 0)
    b3:SetScript("OnClick", function() Trade("post") end)
    local b4 = ns.MakeButton(lg, "Wygasle", 78, 22)
    b4:SetPoint("LEFT", b3, "RIGHT", 4, 0)
    b4:SetScript("OnClick", function() Trade("expired") end)

    p.summary = ns.MakeFS(p, 10)
    p.summary:SetPoint("TOPLEFT", 14, -160)
    p.summary:SetWidth(PANEL_W - 28)
    p.summary:SetSpacing(2)

    -- wiersze listy
    p.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(PANEL_W - 28, ROW_H - 2)
        row:SetPoint("TOPLEFT", 14, ROWS_TOP_SCAN - (i - 1) * ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.left = ns.MakeFS(row, 10)
        row.left:SetPoint("LEFT", 2, 0)
        row.left:SetWidth(170)
        row.left:SetWordWrap(false)
        row.right = ns.MakeFS(row, 10, "RIGHT")
        row.right:SetPoint("RIGHT", -2, 0)
        row.right:SetWidth(148)
        row.right:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if self.s then ns.Select(self.s) end
        end)
        row:Hide()
        p.rows[i] = row
    end
    p.rowsTop = ROWS_TOP_SCAN

    p:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #ModeEntries() - ROWS)
        if ns.panelMode == "log" then
            logOffset = math.max(0, math.min(maxOff, logOffset - delta * 3))
        else
            ns.scan.offset = math.max(0, math.min(maxOff, (ns.scan.offset or 0) - delta * 3))
        end
        ns.UpdatePanel()
    end)
    p:SetScript("OnShow", function() ns.UpdatePanel() end)

    ns.UpdatePanel()
end

------------------------------------------------------------------
-- Okno eksportu (CSV do skopiowania: Ctrl+A, Ctrl+C)
------------------------------------------------------------------
local function ShowExportInner(title, text)
    local f = ns.exportFrame
    if not f then
        f = CreateFrame("Frame", "TsmAnalizeExport", UIParent, "BackdropTemplate")
        ns.exportFrame = f
        f:SetSize(620, 440)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        ns.DarkBackdrop(f, 0.97)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeExport") end

        f.title = ns.MakeFS(f, 14)
        f.title:SetPoint("TOPLEFT", 14, -10)
        f.title:SetWidth(520)
        f.title:SetWordWrap(false)

        local hint = ns.MakeFS(f, 10)
        hint:SetPoint("TOPLEFT", 14, -32)
        hint:SetText("|cff9aa0a6Tekst jest zaznaczony: Ctrl+C kopiuje, potem wklej do arkusza/pliku .csv. Esc zamyka.|r")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)

        local sf = CreateFrame("ScrollFrame", "TsmAnalizeExportScroll", f, "InputScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 14, -56)
        sf:SetSize(572, 366)
        if sf.CharCount then sf.CharCount:Hide() end
        sf.EditBox:SetFontObject(ChatFontNormal)
        sf.EditBox:SetWidth(sf:GetWidth() - 18)
        sf.EditBox:SetMaxLetters(0)
        sf.EditBox:SetScript("OnEscapePressed", function() f:Hide() end)
        f.sf = sf
    end
    f.title:SetText(title)
    f.sf.EditBox:SetText(text)
    f.sf.EditBox:SetCursorPosition(0)
    f:Show()
    f.sf.EditBox:SetFocus()
    f.sf.EditBox:HighlightText()
end

function ns.ShowExport(title, text)
    ns.Safe("export", ShowExportInner, title, text)
end

------------------------------------------------------------------
-- Okno ustawien (2 kolumny, pola z ns.FIELDS i przelaczniki z ns.TOGGLES)
------------------------------------------------------------------
local function BuildConfig()
    local db = ns.db
    local FIELDS, TOGGLES = ns.FIELDS, ns.TOGGLES
    local perCol = math.ceil(#FIELDS / 2)
    local toggleRows = math.ceil(#TOGGLES / 2)

    local cfg = CreateFrame("Frame", "TsmAnalizeConfig", UIParent, "BackdropTemplate")
    ns.config = cfg
    cfg:SetSize(720, 50 + perCol * 28 + 16 + toggleRows * 26 + 56)
    cfg:SetPoint("CENTER")
    cfg:SetFrameStrata("DIALOG")
    ns.DarkBackdrop(cfg, 0.97)
    cfg:SetMovable(true)
    cfg:EnableMouse(true)
    cfg:SetClampedToScreen(true)
    cfg:RegisterForDrag("LeftButton")
    cfg:SetScript("OnDragStart", cfg.StartMoving)
    cfg:SetScript("OnDragStop", cfg.StopMovingOrSizing)
    cfg:Hide()

    local title = ns.MakeFS(cfg, 14)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("|cff33aaffTSMA|r  Ustawienia")

    local close = CreateFrame("Button", nil, cfg, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    cfg.inputs, cfg.checks = {}, {}

    for i, fld in ipairs(FIELDS) do
        local col = (i <= perCol) and 0 or 1
        local row = (i <= perCol) and (i - 1) or (i - perCol - 1)
        local x0 = 16 + col * 352
        local y = -40 - row * 28
        local lbl = ns.MakeFS(cfg, 11)
        lbl:SetPoint("TOPLEFT", x0, y - 5)
        lbl:SetText(fld.label)
        local box = ns.MakeInput(cfg, 110)
        box:SetPoint("TOPLEFT", x0 + 214, y)
        if fld.kind == "text" then box:SetMaxLetters(200) end
        cfg.inputs[fld.key] = box
    end

    local cy0 = -40 - perCol * 28 - 10
    for i, chk in ipairs(TOGGLES) do
        local col = (i <= toggleRows) and 0 or 1
        local row = (i <= toggleRows) and (i - 1) or (i - toggleRows - 1)
        local cb = CreateFrame("CheckButton", nil, cfg, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", 14 + col * 352, cy0 - row * 26)
        local lbl = ns.MakeFS(cfg, 11)
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        lbl:SetText(chk.label)
        cfg.checks[chk.key] = cb
    end

    local function Load()
        for _, fld in ipairs(FIELDS) do
            local v = db[fld.key]
            cfg.inputs[fld.key]:SetText(fld.kind == "money" and ns.MoneyPlain(v) or tostring(v or ""))
            cfg.inputs[fld.key]:SetCursorPosition(0)
        end
        for _, chk in ipairs(TOGGLES) do
            local v
            if chk.get then v = chk.get() else v = db[chk.key] end
            cfg.checks[chk.key]:SetChecked(v and true or false)
        end
    end

    local function Apply()
        local errors = {}
        for _, fld in ipairs(FIELDS) do
            local ok, err = ns.SetField(fld, cfg.inputs[fld.key]:GetText())
            if not ok then errors[#errors + 1] = fld.label end
        end
        for _, chk in ipairs(TOGGLES) do
            local v = cfg.checks[chk.key]:GetChecked() and true or false
            if chk.set then chk.set(v) else db[chk.key] = v end
        end
        ns.ApplyScale()
        ns.UpdateUI()
        ns.UpdatePanel()
        if #errors > 0 then
            ns.Print("Niepoprawne wartosci (pominiete): " .. table.concat(errors, ", "))
        else
            ns.Print("Ustawienia zapisane.")
        end
        Load()
    end

    local save = ns.MakeButton(cfg, "Zastosuj", 110, 24)
    save:SetPoint("BOTTOMLEFT", 16, 14)
    save:SetScript("OnClick", Apply)

    local cancel = ns.MakeButton(cfg, "Zamknij", 110, 24)
    cancel:SetPoint("LEFT", save, "RIGHT", 8, 0)
    cancel:SetScript("OnClick", function() cfg:Hide() end)

    cfg:SetScript("OnShow", Load)
end

function ns.ToggleConfig()
    local c = ns.config
    if not c then return end
    c:SetShown(not c:IsShown())
end

function ns.BuildPanels()
    BuildPanel()
    BuildConfig()
end
