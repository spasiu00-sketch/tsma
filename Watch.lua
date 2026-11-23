local ADDON, ns = ...

------------------------------------------------------------------
-- LISTA: obserwowane + zakupy w jednym miejscu (zakladka "Lista" w Hubie)
--  * dodawanie: Shift+klik na przedmiocie, ID, nazwa; wiele naraz (oddziel przecinkiem / spacja przy ID)
--  * grupa wpisana w polu "Grupa" laczy dodawane przedmioty; puste = kategoria automatyczna (typ przedmiotu z gry)
--  * CEL (ALERT): cena, przy ktorej chcesz kupowac; to ten sam prog co "alert gdy min <=" w HUD. Lista pokazuje OKAZJA,
--    gdy aktualna cena jest na poziomie celu albo nizej, a addon wysyla alert na czacie
--  * ILOSC: ile chcesz kupic (do liczenia kosztu calej listy)
--  * ponowne dodanie przedmiotu z nowym celem / iloscia aktualizuje wpis
--  * wiersz grupy: klik = zwin/rozwin, [x] = usun grupe
--  * wiersz przedmiotu: klik = analiza w HUD, [>] = przenies do grupy z pola "Grupa", [x] = usun z listy
--  * [Z TSM] = import calej grupy TSM: wpisz fragment nazwy/sciezki albo zostaw puste i wybierz grupe z listy
-- Lista przedmiotow nadal siedzi w db.watch, wiec skaner, alerty, odswiezanie i strzalki < > w HUD dzialaja jak dotad.
-- Dawne listy zakupow (db.shop) zostaly przeniesione tutaj jednorazowo: nazwa listy = grupa, cena = cel, ilosc = ilosc.
------------------------------------------------------------------

local ROWS, ROW_H, W = 11, 24, 780
local offset = 0
local win, addBox, groupBox, targetBox, qtyBox

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function EnsureGroup(name)
    local list = ns.db.groupList
    for _, n in ipairs(list) do
        if n == name then return end
    end
    list[#list + 1] = name
end

local function InitDB()
    local db = ns.db
    db.groupList = db.groupList or {}        -- kolejnosc grup wlasnych
    db.groupOf = db.groupOf or {}            -- [itemString] = nazwa grupy wlasnej
    db.groupCollapsed = db.groupCollapsed or {}
    db.watchQty = db.watchQty or {}          -- [itemString] = ile chcesz kupic

    -- jednorazowa migracja z dawnych list zakupow Huba
    if db.shop and not db.shopMigrated then
        for _, l in ipairs(db.shop.lists or {}) do
            if l.name and l.name ~= "" then EnsureGroup(l.name) end
            for _, it in ipairs(l.items or {}) do
                if it.s then
                    if not ns.IsWatched(it.s) then table.insert(db.watch, it.s) end
                    if l.name and not db.groupOf[it.s] then db.groupOf[it.s] = l.name end
                    if it.max and not db.alerts[it.s] then db.alerts[it.s] = it.max end
                    if it.qty then db.watchQty[it.s] = it.qty end
                end
            end
        end
        db.shop = nil
        db.shopMigrated = true
    end
end

-- kategoria automatyczna z typu przedmiotu w grze (np. "Trade Goods: Herb")
local function AutoCategory(s)
    local id = tonumber((s or ""):match("^i:(%d+)"))
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if id and getInstant then
        local _, itemType, itemSubType = getInstant(id)
        if itemType and itemType ~= "" then
            if itemSubType and itemSubType ~= "" and itemSubType ~= itemType then
                return itemType .. ": " .. itemSubType
            end
            return itemType
        end
    end
    return "Inne"
end

-- grupy: najpierw wlasne (w swojej kolejnosci, tez puste), potem automatyczne alfabetycznie
local function Model()
    local db = ns.db
    local watched = {}
    for _, s in ipairs(db.watch) do watched[s] = true end
    for s in pairs(db.groupOf) do
        if not watched[s] then db.groupOf[s] = nil end   -- przedmiot usuniety z listy gdzie indziej (np. przycisk w HUD)
    end

    local byName, custom, auto = {}, {}, {}
    for _, name in ipairs(db.groupList) do
        local g = { name = name, items = {}, custom = true }
        byName[name] = g
        custom[#custom + 1] = g
    end
    -- nazwy liczymy raz na przedmiot (ns.ItemName pyta TSM, wiec nie w komparatorze sortowania)
    local names = {}
    for _, s in ipairs(db.watch) do
        names[s] = ns.ItemName(s)
        local name = db.groupOf[s]
        local g = name and byName[name]
        if not g then
            name = AutoCategory(s)
            g = byName[name]
            if not g then
                g = { name = name, items = {}, custom = false }
                byName[name] = g
                auto[#auto + 1] = g
            end
        end
        g.items[#g.items + 1] = s
    end
    table.sort(auto, function(a, b) return a.name < b.name end)
    local out = {}
    for _, g in ipairs(custom) do out[#out + 1] = g end
    for _, g in ipairs(auto) do out[#out + 1] = g end
    for _, g in ipairs(out) do
        table.sort(g.items, function(a, b)
            local x, y = names[a] or a, names[b] or b
            if x ~= y then return x < y end
            return a < b
        end)
    end
    return out
end

local function BuildList()
    local list = {}
    for _, g in ipairs(Model()) do
        local collapsed = ns.db.groupCollapsed[g.name] and true or false
        list[#list + 1] = { kind = "group", g = g, collapsed = collapsed }
        if not collapsed then
            for _, s in ipairs(g.items) do
                list[#list + 1] = { kind = "item", s = s, g = g }
            end
        end
    end
    return list
end

------------------------------------------------------------------
-- Dodawanie
------------------------------------------------------------------
local function ParseTokens(text)
    local items, bad = {}, {}
    text = text or ""
    for body in text:gmatch("|H(item:[^|]+)|h") do
        local s = ns.ResolveItem(body)
        if s then items[#items + 1] = s end
    end
    local rest = (text:gsub("|c%x%x%x%x%x%x%x%x|H.-|h.-|h|r", " "))
    for part in rest:gmatch("[^,;\n]+") do
        part = trim(part)
        if part ~= "" then
            if part:match("^[%d%s]+$") then
                for n in part:gmatch("%d+") do items[#items + 1] = "i:" .. n end
            else
                local s = ns.ResolveItem(part)
                if s then items[#items + 1] = s else bad[#bad + 1] = part end
            end
        end
    end
    return items, bad
end

-- maxPrice (cel = alert) i qty sa opcjonalne; podane aktualizuja wpis takze dla przedmiotu, ktory juz byl na liscie
local function AddItems(items, groupName, maxPrice, qty)
    local db = ns.db
    local added, existing = 0, 0
    if groupName ~= "" then EnsureGroup(groupName) end
    for _, s in ipairs(items) do
        if not ns.IsWatched(s) then
            table.insert(db.watch, s)
            added = added + 1
        else
            existing = existing + 1
        end
        if groupName ~= "" then db.groupOf[s] = groupName end   -- istniejacy przedmiot zostaje przeniesiony do grupy
        if maxPrice then
            db.alerts[s] = maxPrice
            ns.alertState[s] = nil
        end
        if qty then db.watchQty[s] = qty end
        ns.MergeImport(s)
        if ns.BlizzRecord then ns.BlizzRecord(s) end   -- migawka Blizzarda dla wykresu (jesli sa dane)
        if ns.HasTSM() then
            local d = ns.FetchTSM(s)
            ns.cache[s] = d
            ns.Record(s, d)
        end
    end
    return added, existing
end

-- punkt wejscia dla innych modulow (np. Luki cenowe w Hubie)
function ns.ListAdd(s, groupName, maxPrice, qty)
    if not (ns.db and s) then return end
    AddItems({ s }, groupName or "", maxPrice, qty)
    if ns.UpdateUI then ns.UpdateUI() end
end

local function DoAdd()
    local items, bad = ParseTokens(addBox:GetText())
    local groupName = trim(groupBox:GetText())
    local maxPrice = ns.ParseMoney(targetBox:GetText())
    local qty = tonumber(qtyBox:GetText())
    if qty and qty <= 0 then qty = nil end
    if #items == 0 then
        ns.Print("Nie rozpoznano zadnego przedmiotu." .. (#bad > 0 and (" (" .. table.concat(bad, ", ") .. ")") or ""))
        return
    end
    local added, existing = AddItems(items, groupName, maxPrice, qty)
    ns.Print(string.format("Lista: dodano %d, juz byly %d%s%s%s.", added, existing,
        groupName ~= "" and (", grupa: " .. groupName) or " (kategoria automatyczna)",
        maxPrice and (", cel: " .. ns.MoneyPlain(maxPrice)) or "",
        #bad > 0 and ("; nierozpoznane: " .. table.concat(bad, ", ")) or ""))
    if #items == 1 and ns.Select then ns.Select(items[1]) end
    addBox:SetText("")
    targetBox:SetText("")
    qtyBox:SetText("")
    addBox:ClearFocus()
    ns.UpdateUI()
end

-- Import grup TSM. Sciezki w TSM sa laczone znakiem ` (np. Zielarstwo`Klasyczne); mozesz wpisac tez / lub >,
-- wielkosc liter nie ma znaczenia, wystarczy fragment nazwy. Puste pole albo nieznana sciezka = lista grup do wyboru.
local function TSMPaths()
    if not (ns.HasTSM() and type(TSM_API.GetGroupPaths) == "function") then return nil end
    local t = {}
    local ok, res = pcall(TSM_API.GetGroupPaths, t)
    local src = (ok and type(res) == "table" and next(res) ~= nil) and res or t
    local list, seen = {}, {}
    for k, v in pairs(src) do
        local p = (type(v) == "string" and v) or (type(k) == "string" and k) or nil
        if p and not seen[p] then
            seen[p] = true
            list[#list + 1] = p
        end
    end
    table.sort(list)
    return list
end

local function Pretty(path) return (path:gsub("`", " > ")) end

-- zwraca sciezke albo nil, lista_kandydatow
local function ResolveTSMPath(text, paths)
    local want = (trim(text):gsub("%s*[/\\>]%s*", "`")):lower()
    for _, p in ipairs(paths) do
        if p:lower() == want then return p end
    end
    local cands = {}
    for _, p in ipairs(paths) do
        if p:lower():find(want, 1, true) then cands[#cands + 1] = p end
    end
    if #cands == 1 then return cands[1] end
    return nil, cands
end

local function ImportPath(path, groupName)
    local t = {}
    local ok, res = pcall(TSM_API.GetGroupItems, path, true, t)
    if not ok then
        ns.Print("Blad TSM przy odczycie grupy '" .. Pretty(path) .. "': " .. tostring(res))
        return
    end
    local src = (type(res) == "table" and next(res) ~= nil) and res or t
    local items, seen = {}, {}
    for k, v in pairs(src) do
        local s = (type(v) == "string" and v) or (type(k) == "string" and k) or nil
        if s and not seen[s] and #items < 500 then
            seen[s] = true
            items[#items + 1] = s
        end
    end
    if #items == 0 then
        ns.Print("Grupa TSM '" .. Pretty(path) .. "' nie zawiera przedmiotow (albo TSM ich nie zwrocil - sprawdz /tsma debug).")
        return
    end
    if groupName == "" then groupName = path:match("([^`]+)$") or path end
    local added, existing = AddItems(items, groupName)
    ns.Print(string.format("Import z TSM (%s): dodano %d, juz byly %d, grupa: %s.", Pretty(path), added, existing, groupName))
    ns.UpdateUI()
end

-- okno wyboru grupy TSM (z filtrem)
local picker
local PICK_ROWS = 16

local function RefreshPicker()
    if not (picker and picker:IsShown()) then return end
    local filter = trim(picker.filter:GetText()):lower()
    local list = {}
    for _, p in ipairs(picker.all or {}) do
        if filter == "" or p:lower():find(filter, 1, true) then list[#list + 1] = p end
    end
    local maxOff = math.max(0, #list - PICK_ROWS)
    picker.offset = math.min(picker.offset or 0, maxOff)
    picker.count:SetText(string.format("%d grup", #list))
    for i = 1, PICK_ROWS do
        local row = picker.rows[i]
        local p = list[picker.offset + i]
        row.path = p
        if p then
            local depth = select(2, p:gsub("`", ""))
            row.text:SetText(string.rep("    ", depth) .. (p:match("([^`]+)$") or p))
            row.full:SetText(Pretty(p))
            row:Show()
        else
            row:Hide()
        end
    end
end

local function BuildPicker()
    local f = CreateFrame("Frame", "TsmAnalizeTSMPicker", UIParent, "BackdropTemplate")
    picker = f
    f:SetSize(460, 480)
    f:SetPoint("CENTER", 120, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    ns.DarkBackdrop(f, 0.98)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeTSMPicker") end

    local title = ns.MakeFS(f, 14)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("|cff33aaffTSMA|r  Wybierz grupe TSM do importu")

    f.count = ns.MakeFS(f, 10, "RIGHT")
    f.count:SetPoint("TOPRIGHT", -34, -13)
    f.count:SetWidth(100)
    f.count:SetTextColor(0.6, 0.6, 0.6)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local lbl = ns.MakeFS(f, 10)
    lbl:SetPoint("TOPLEFT", 14, -34)
    lbl:SetText("|cff9aa0a6Filtr (fragment nazwy). Klik w grupe = import wszystkich jej przedmiotow (z podgrupami) do grupy z pola Grupa albo o tej nazwie.|r")
    lbl:SetWidth(430)

    f.filter = ns.MakeInput(f, 300)
    f.filter:SetPoint("TOPLEFT", 20, -68)
    f.filter:SetScript("OnTextChanged", function(_, user) if user then picker.offset = 0; RefreshPicker() end end)

    f.rows = {}
    for i = 1, PICK_ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(436, 22)
        row:SetPoint("TOPLEFT", 12, -98 - (i - 1) * 24)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.text = ns.MakeFS(row, 11)
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetWidth(200)
        row.text:SetWordWrap(false)
        row.full = ns.MakeFS(row, 9, "RIGHT")
        row.full:SetPoint("RIGHT", -6, 0)
        row.full:SetWidth(220)
        row.full:SetWordWrap(false)
        row.full:SetTextColor(0.55, 0.55, 0.55)
        row:SetScript("OnClick", function(self)
            if not self.path then return end
            ImportPath(self.path, trim(groupBox:GetText()))
            picker:Hide()
        end)
        row:Hide()
        f.rows[i] = row
    end

    f:SetScript("OnMouseWheel", function(_, delta)
        picker.offset = math.max(0, (picker.offset or 0) - delta * 3)
        RefreshPicker()
    end)
end

local function ShowPicker(paths)
    if not paths or #paths == 0 then
        ns.Print("TSM nie zwrocil zadnych grup (TSM_API.GetGroupPaths) - sprawdz /tsma debug.")
        return
    end
    if not picker then BuildPicker() end
    picker.all = paths
    picker.offset = 0
    picker.filter:SetText("")
    picker:Show()
    RefreshPicker()
end

local function DoImportTSM()
    if not ns.HasTSM() then ns.Print("TSM nie wykryte."); return end
    if type(TSM_API.GetGroupItems) ~= "function" then
        ns.Print("Ta wersja TSM nie udostepnia TSM_API.GetGroupItems - import grup niemozliwy (sprawdz /tsma debug).")
        return
    end
    local text = trim(addBox:GetText())
    local paths = TSMPaths()

    if text == "" then
        if paths then ShowPicker(paths)
        else ns.Print("Wpisz sciezke grupy TSM w polu przedmiotow (ta wersja TSM nie udostepnia listy grup).") end
        return
    end

    if not paths then
        -- brak GetGroupPaths: probujemy wpisana sciezke wprost (separator: `)
        ImportPath((text:gsub("%s*[/\\>]%s*", "`")), trim(groupBox:GetText()))
        addBox:SetText("")
        addBox:ClearFocus()
        return
    end

    local path, cands = ResolveTSMPath(text, paths)
    if path then
        ImportPath(path, trim(groupBox:GetText()))
        addBox:SetText("")
        addBox:ClearFocus()
    elseif cands and #cands > 1 then
        ns.Print(string.format("'%s' pasuje do %d grup - wybierz z listy.", text, #cands))
        ShowPicker(cands)
    else
        ns.Print(string.format("Nie ma grupy TSM '%s' - wybierz z listy.", text))
        ShowPicker(paths)
    end
end

------------------------------------------------------------------
-- Akcje na wierszach
------------------------------------------------------------------
local function RemoveItem(s)
    local i = ns.IsWatched(s)
    if i then table.remove(ns.db.watch, i) end
    ns.db.groupOf[s] = nil
    ns.db.watchQty[s] = nil
    ns.UpdateUI()
end

local function MoveItem(s)
    local name = trim(groupBox:GetText())
    if name == "" then
        ns.db.groupOf[s] = nil
    else
        EnsureGroup(name)
        ns.db.groupOf[s] = name
    end
    ns.UpdateUI()
end

local function DeleteGroup(name)
    local db = ns.db
    for s, g in pairs(db.groupOf) do
        if g == name then db.groupOf[s] = nil end
    end
    for i, n in ipairs(db.groupList) do
        if n == name then table.remove(db.groupList, i); break end
    end
    db.groupCollapsed[name] = nil
    ns.UpdateUI()
end

------------------------------------------------------------------
-- Okno
------------------------------------------------------------------
local function RightText(s)
    local d = ns.cache[s]
    if not d then return "|cff888888--|r" end
    local ok, r = pcall(ns.Analyze, s, d, (ns.EffectiveBuy(s, d)))
    if ok and r and r.verdict ~= "NODATA" and r.risk then
        return ns.RISK_LETTER[r.risk.level] .. " " .. ns.Money(d.minbuy) .. "  " .. ns.VERDICT_SHORT[r.verdict]
    end
    return ns.Money(d.minbuy)
end

-- OKAZJA, gdy aktualna cena <= cel (alert); inaczej ile % nad celem
local function StatusText(s)
    local t = ns.db.alerts[s]
    local d = ns.cache[s]
    if not (t and d and d.minbuy) then return "" end
    local pct = (d.minbuy / t - 1) * 100
    if pct <= 0 then
        return string.format("|cff33dd66OKAZJA: %.0f%% pod celem|r", -pct)
    end
    return string.format("|cff9aa0a6%.0f%% nad celem|r", pct)
end

local function Refresh()
    if not (win and win:IsShown()) then return end
    win:SetScale(ns.db.scale or 1)
    local db = ns.db
    local list = BuildList()
    local maxOff = math.max(0, #list - ROWS)
    offset = math.min(offset, maxOff)

    local nWatch = #db.watch
    win.count:SetText(string.format("%d przedmiotow", nWatch))

    local cost, deals = 0, 0
    for _, s in ipairs(db.watch) do
        local d = ns.cache[s]
        if d and d.minbuy then
            local q = db.watchQty[s]
            if q then cost = cost + d.minbuy * q end
            local t = db.alerts[s]
            if t and d.minbuy <= t then deals = deals + 1 end
        end
    end
    win.sum:SetText(string.format("Koszt pozycji z iloscia po aktualnych cenach: %s    okazji teraz (cena <= cel): %s%d|r",
        ns.MoneyPlain(cost), deals > 0 and "|cff33dd66" or "|cff9aa0a6", deals))

    if win.chart then
        local sel = db.selected
        win.chart.st = db.listSt
        win.chart:SetItem(sel)
        win.chart:Redraw()
        win.chartTitle:SetText(sel and ns.ItemName(sel) or "|cff9aa0a6Kliknij przedmiot na liscie, zeby zobaczyc wykres|r")
        for _, b in ipairs(win.rangeBtns) do b:SetEnabled((db.listSt.range or 0) ~= b.range) end
        win.srcBtn:SetText(ns.ChartSourceText and ns.ChartSourceText() or "Zrodlo")
    end

    for i = 1, ROWS do
        local row = win.rows[i]
        local e = list[offset + i]
        row.e = e
        if not e then
            row:Hide()
        else
            row:Show()
            row.name:ClearAllPoints()
            if e.kind == "group" then
                local g = e.g
                row.icon:Hide()
                row.sel:Hide()
                row.name:SetPoint("LEFT", 4, 0)
                row.name:SetWidth(460)
                row.name:SetText((g.custom and "|cffffd100" or "|cff7fb2ff") .. (e.collapsed and "[+] " or "[-] ")
                    .. g.name .. "|r |cff9aa0a6(" .. #g.items .. ")|r")
                row.right:SetText("")
                row.target:SetText("")
                row.qty:SetText("")
                row.status:SetText("")
                row.move:Hide()
                row.del:SetShown(g.custom)
            else
                row.icon:Show()
                row.icon:SetTexture(ns.ItemIcon(e.s))
                row.sel:SetShown(e.s == db.selected)
                row.name:SetPoint("LEFT", 42, 0)
                row.name:SetWidth(190)
                row.name:SetText(ns.ItemName(e.s))
                row.right:SetText(RightText(e.s))
                local t = db.alerts[e.s]
                row.target:SetText(t and ns.Money(t) or "|cff888888--|r")
                local q = db.watchQty[e.s]
                row.qty:SetText(q and ("x" .. q) or "")
                row.status:SetText(StatusText(e.s))
                row.move:Show()
                row.del:Show()
            end
        end
    end
end

local function Tip(btn, text)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function BuildWindow()
    local f = CreateFrame("Frame", "TsmAnalizeWatch", UIParent, "BackdropTemplate")
    win = f
    f:SetSize(W, 580)
    f:SetPoint("CENTER", -120, 0)
    f:SetFrameStrata("DIALOG")
    ns.DarkBackdrop(f, 0.97)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeWatch") end

    local title = ns.MakeFS(f, 14)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("|cff33aaffTSMA|r  Lista: obserwowane i zakupy")

    f.count = ns.MakeFS(f, 10, "RIGHT")
    f.count:SetPoint("TOPRIGHT", -34, -13)
    f.count:SetWidth(120)
    f.count:SetTextColor(0.6, 0.6, 0.6)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local l1 = ns.MakeFS(f, 10)
    l1:SetPoint("TOPLEFT", 14, -34)
    l1:SetText("|cff9aa0a6Przedmiot (Shift+klik, ID, nazwa, wiele po przecinku, albo grupa TSM)   |   Grupa   |   Cel (= alert)   |   Ilosc|r")

    addBox = ns.MakeInput(f, 250)
    addBox:SetPoint("TOPLEFT", 20, -50)
    addBox:SetScript("OnEnterPressed", DoAdd)

    groupBox = ns.MakeInput(f, 110)
    groupBox:SetPoint("TOPLEFT", 282, -50)
    groupBox:SetScript("OnEnterPressed", DoAdd)

    targetBox = ns.MakeInput(f, 110)
    targetBox:SetPoint("TOPLEFT", 400, -50)
    targetBox:SetScript("OnEnterPressed", DoAdd)

    qtyBox = ns.MakeInput(f, 50)
    qtyBox:SetPoint("TOPLEFT", 516, -50)
    qtyBox:SetNumeric(true)
    qtyBox:SetScript("OnEnterPressed", DoAdd)

    local addBtn = ns.MakeButton(f, "Dodaj", 60, 22)
    addBtn:SetPoint("TOPLEFT", 578, -50)
    addBtn:SetScript("OnClick", DoAdd)

    local tsmBtn = ns.MakeButton(f, "Z TSM", 60, 22)
    tsmBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
    tsmBtn:SetScript("OnClick", DoImportTSM)
    Tip(tsmBtn, "Import grupy TSM: wpisz fragment nazwy/sciezki w polu przedmiotow albo zostaw puste i wybierz z listy.")

    local l3 = ns.MakeFS(f, 10)
    l3:SetPoint("TOPLEFT", 14, -78)
    l3:SetWidth(W - 28)
    l3:SetText("|cff9aa0a6Cel ceny to ten sam prog co alert w HUD: gdy cena spadnie do celu, wiersz pokaze OKAZJA i dostaniesz alert na czacie. Ponowne dodanie przedmiotu z nowym celem/iloscia aktualizuje wpis. [>] przenosi przedmiot do grupy z pola Grupa.|r")

    -- naglowki kolumn
    local heads = { { "PRZEDMIOT", 54 }, { "RYZYKO / CENA / WERDYKT", 248 }, { "CEL (ALERT)", 444 }, { "ILOSC", 548 }, { "STATUS", 596 } }
    for _, h in ipairs(heads) do
        local fs = ns.MakeFS(f, 9)
        fs:SetPoint("TOPLEFT", h[2], -102)
        fs:SetText("|cff9aa0a6" .. h[1] .. "|r")
    end

    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(W - 24, ROW_H - 2)
        row:SetPoint("TOPLEFT", 12, -118 - (i - 1) * ROW_H)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.2, 0.5, 1, 0.18)
        row.sel:Hide()

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 18, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        row.name = ns.MakeFS(row, 11)
        row.name:SetWordWrap(false)

        row.right = ns.MakeFS(row, 10)
        row.right:SetPoint("LEFT", 236, 0)
        row.right:SetWidth(194)
        row.right:SetWordWrap(false)
        row.target = ns.MakeFS(row, 10)
        row.target:SetPoint("LEFT", 432, 0)
        row.target:SetWidth(100)
        row.target:SetWordWrap(false)
        row.qty = ns.MakeFS(row, 10)
        row.qty:SetPoint("LEFT", 536, 0)
        row.qty:SetWidth(44)
        row.qty:SetWordWrap(false)
        row.status = ns.MakeFS(row, 10)
        row.status:SetPoint("LEFT", 584, 0)
        row.status:SetWidth(130)
        row.status:SetWordWrap(false)

        row.del = ns.MakeButton(row, "x", 22, 18)
        row.del:SetPoint("RIGHT", -2, 0)
        row.move = ns.MakeButton(row, ">", 22, 18)
        row.move:SetPoint("RIGHT", -26, 0)

        row.del:SetScript("OnClick", function()
            local e = row.e
            if not e then return end
            if e.kind == "group" then DeleteGroup(e.g.name) else RemoveItem(e.s) end
        end)
        row.move:SetScript("OnClick", function()
            if row.e and row.e.kind == "item" then MoveItem(row.e.s) end
        end)
        Tip(row.del, "Usun z listy (przy grupie: usun grupe, przedmioty wroca do kategorii automatycznych)")
        Tip(row.move, "Przenies do grupy wpisanej w polu Grupa (puste = kategoria automatyczna)")

        row:SetScript("OnClick", function(self)
            local e = self.e
            if not e then return end
            if e.kind == "group" then
                ns.db.groupCollapsed[e.g.name] = (not e.collapsed) or nil
                Refresh()
            else
                ns.Select(e.s)
                if ns.ListJump then ns.ListJump() end   -- w Hubie: przejdz do malego okna (HUD), Cofnij wraca
            end
        end)
        row:Hide()
        f.rows[i] = row
    end

    f.sum = ns.MakeFS(f, 10)
    f.sum:SetPoint("TOPLEFT", 14, -118 - ROWS * ROW_H - 4)
    f.sum:SetWidth(W - 28)

    -- wykres wybranego przedmiotu (klik w wiersz = pokaz wykres)
    local db = ns.db
    db.listSt = db.listSt or { range = 7 * 86400, be = true, alert = true, ov = {} }
    local st = db.listSt
    f.chartTitle = ns.MakeFS(f, 12)
    f.chartTitle:SetPoint("TOPLEFT", 14, -408)
    f.chartTitle:SetWidth(330)
    f.chartTitle:SetWordWrap(false)

    f.rangeBtns = {}
    local rdefs = { { "7d", 7 * 86400, 38 }, { "30d", 30 * 86400, 42 }, { "Wszystko", 0, 70 } }
    local prevB
    for i = #rdefs, 1, -1 do
        local r = rdefs[i]
        local b = ns.MakeButton(f, r[1], r[3], 20)
        if prevB then b:SetPoint("RIGHT", prevB, "LEFT", -3, 0) else b:SetPoint("TOPRIGHT", -14, -404) end
        b:SetScript("OnClick", function() st.range = r[2]; Refresh() end)
        b.range = r[2]
        f.rangeBtns[i] = b
        prevB = b
    end
    f.srcBtn = ns.MakeButton(f, "", 104, 20)
    f.srcBtn:SetPoint("RIGHT", prevB, "LEFT", -10, 0)
    f.srcBtn:SetScript("OnClick", function()
        if ns.SetChartSource then ns.SetChartSource(not ns.db.chartBlizz) end
    end)
    Tip(f.srcBtn, "Zrodlo wykresu: TSMA (TSM + archiwum) albo Blizzard (AuctionEngine). Zrodla nie sa mieszane.")
    f.bigBtn = ns.MakeButton(f, "Duzy wykres", 92, 20)
    f.bigBtn:SetPoint("RIGHT", f.srcBtn, "LEFT", -3, 0)
    f.bigBtn:SetScript("OnClick", function()
        if ns.ToggleBigChart then ns.ToggleBigChart() end
    end)
    Tip(f.bigBtn, "Otwiera duzy wykres (zamyka to okno).")

    if ns.NewChart then
        f.chart = ns.NewChart(f, W - 28, 112, { padL = 70, gutter = 104, mini = true, st = st })
        f.chart:SetPoint("TOPLEFT", 14, -448)
    end

    f:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 3)
        Refresh()
    end)
    f:SetScript("OnShow", function() ns.Safe("watch", Refresh) end)

    -- Shift+klik na przedmiot wstawia link do pola, gdy ma focus.
    -- Jeden Shift+klik odpala kilka hookow (InsertLink i HandleModifiedItemClick), wiec dopisujemy link tylko raz.
    local function OnLink(link)
        if type(link) == "string" and addBox:HasFocus() then
            local cur = addBox:GetText()
            if cur:find(link, 1, true) then return end
            addBox:SetText((cur ~= "" and (cur .. ", ") or "") .. link)
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

end

function ns.ToggleWatchMenu()
    if not win then return end
    if win:IsShown() then win:Hide() else win:Show() end
end

if ns.UpdateUI then
    hooksecurefunc(ns, "UpdateUI", function() ns.Safe("watch", Refresh) end)
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = (msg or ""):match("^(%S*)")
    cmd = (cmd or ""):lower()
    if (cmd == "menu" or cmd == "listamenu") and ns.db then
        ns.ToggleWatchMenu()
    elseif origSlash then
        origSlash(msg)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.Safe("watch", InitDB)
    ns.Safe("watch", BuildWindow)
end)
