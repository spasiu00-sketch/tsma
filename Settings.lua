local ADDON, ns = ...

------------------------------------------------------------------
-- USTAWIENIA (zakladka Hub > Ustawienia): grupy, tooltipy, zapis od razu, wyszukiwarka, reset
-- Opcje nadal rejestruja sie w ns.FIELDS / ns.TOGGLES (inne pliki bez zmian); opis i grupe dobiera tabela META.
-- Opcja spoza META trafia do grupy "Inne".
------------------------------------------------------------------

local GRAY, GREEN, RED, BLUE = "|cff9aa0a6", "|cff33dd66", "|cffff4040", "|cff33aaff"
local ROWS, ROW_H, ROW_W = 18, 28, 780
local EXTRA_DEF = { uiAlpha = 1, fontScale = 1 }
local HIDE = { scanMinPrice = true, scanSkipHigh = true, scanRequireRate = true, scanSortDay = true }

-- nowe opcje wygladu
table.insert(ns.FIELDS, { key = "uiAlpha", label = "Przezroczystosc okien (0.3-1)", kind = "num", min = 0.3, max = 1 })
table.insert(ns.FIELDS, { key = "fontScale", label = "Rozmiar czcionki (0.8-1.6, po /reload)", kind = "num", min = 0.8, max = 1.6 })
table.insert(ns.TOGGLES, { key = "alertSound", label = "Dzwiek alertow",
    get = function() return ns.db.alertSound ~= false end,
    set = function(v) ns.db.alertSound = v and true or false end })

-- { grupa, klucz, opis, zaawansowane }
local META = {
    { "Handel", "house", "Wybiera prowizje: dom frakcyjny (Prowizja frakcyjna) albo neutralny (Prowizja neutralna, zwykle 15%)." },
    { "Handel", "cut", "Prowizja frakcyjnego domu aukcyjnego w %. Wchodzi do break-even i zysku netto." },
    { "Handel", "cutNeutral", "Prowizja neutralnego domu aukcyjnego w %." },
    { "Handel", "margin", "Minimalny oczekiwany zysk netto w %. Ponizej tego werdykt to GRANICZNIE albo NIE." },
    { "Handel", "undercut", "O ile podbijac najnizsza oferte. Wpisz np. 1c; sama liczba '1' to 1 zloto." },
    { "Handel", "youngMode", "Przy mlodej ekonomii zmniejsza wage DBMarket (dane z pierwszych dni sa niepewne)." },
    { "Handel", "useAvgBuy", "Gdy nie wpisales ceny zakupu, uzyj sredniego zakupu z TSM Accounting." },
    { "Handel", "profitOn", "Werdykt z realna cena sprzedazy (Twoje sprzedaze, wlasne punkty, DBRegionSaleAvg), kosztem ponownych wystawien i ROI na dobe." },
    { "Handel", "minRoiDay", "Minimalny ROI na dobe (%). Ponizej tego werdykt KUP spada do GRANICZNIE." },
    { "Handel", "maxLoss", "Gdy w scenariuszu pesymistycznym (cena nizsza o zmiennosc) strata przekracza tyle %, KUP spada do GRANICZNIE. 0 = wylaczone." },
    { "Handel", "refFormula", "Wlasny wzor TSM ceny odniesienia sprzedazy, np. min(DBMarket, DBRegionMarketAvg). Puste = auto.", true },

    { "Kapital i ryzyko", "capital", "Twoj kapital. 0 = nie licz limitu zakupu." },
    { "Kapital i ryzyko", "exposurePct", "Maksymalny % kapitalu w jednym przedmiocie (dodatkowo zmniejszany przez ryzyko)." },
    { "Kapital i ryzyko", "stopLoss", "Alert, gdy cena spadnie o tyle % ponizej break-even przedmiotu w zapasie." },
    { "Kapital i ryzyko", "minSaleRate", "Ponizej tego sale rate sprzedaz uznajemy za wolna (dolicza ryzyko).", true },
    { "Kapital i ryzyko", "riskExt", "Rozszerzona ocena: swiezosc danych, dlugosc historii, czas sprzedazy, bufor spadku." },
    { "Kapital i ryzyko", "riskShare", "Jaki ulamek sprzedazy rynku zakladasz dla siebie (0-1). Wplywa na czas sprzedazy i limit sztuk.", true },
    { "Kapital i ryzyko", "catExpOn", "Limit kapitalu na kategorie przedmiotow (np. wszystkie ziola razem)." },
    { "Kapital i ryzyko", "catExposurePct", "Max % kapitalu w jednej kategorii (typ: podtyp z gry)." },
    { "Kapital i ryzyko", "staleOn", "Alert, gdy towar w zapasie lezy za dlugo, z cena wyjscia." },
    { "Kapital i ryzyko", "staleDays", "Po ilu dniach zapas uznajemy za zalegajacy." },
    { "Dane i archiwum", "refreshMin", "Co ile minut odswiezac dane z TSM." },
    { "Dane i archiwum", "histDays", "Ile dni wlasnej historii cen trzymac (1-30)." },
    { "Dane i archiwum", "arcOn", "Dobowe archiwum cen wszystkich przedmiotow (wykresy dowolnego przedmiotu, okno Rynek)." },
    { "Dane i archiwum", "arcKeepDays", "Ile dni trzymac archiwum (7-180). Wiecej dni = wiekszy plik SavedVariables." },
    { "Dane i archiwum", "chartBlizz", "Wykresy z danych Blizzarda (AuctionEngine) zamiast TSM + archiwum. Zrodla nie sa mieszane." },
    { "Dane i archiwum", "histEveryMin", "Co ile minut zapisywac punkt do historii.", true },
    { "Dane i archiwum", "predHours", "Po ilu godzinach oceniac trafnosc werdyktu (statystyka Trafnosc KUP).", true },
    { "Dane i archiwum", "perDayDiv", "Dzielnik DBRegionSoldPerDay. Sprawdz /tsma debug, jesli tempo sprzedazy wyglada zle.", true },
    { "Dane i archiwum", "depositMin", "Minimalny depozyt za aukcje (np. 1s).", true },
    { "Dane i archiwum", "depositPct", "Depozyt jako % ceny NPC. Po kilku wystawieniach addon kalibruje to sam.", true },
    { "Dane i archiwum", "stackSize", "Typowy rozmiar stosu przy wystawianiu (do minimalnego depozytu).", true },
    { "Dane i archiwum", "arcMaxID", "Gorna granica ID przy pelnym skanie archiwum (raz na dobe).", true },

    { "Alerty i dziennik", "alertBuy", "Alert na czacie, gdy obserwowany przedmiot staje sie okazja." },
    { "Alerty i dziennik", "alertUndercut", "Alert, gdy ktos podbil Twoja aukcje." },
    { "Alerty i dziennik", "warnPost", "Ostrzezenie po wystawieniu ponizej break-even, progu zysku albo podejrzanie nisko." },
    { "Alerty i dziennik", "alertSound", "Dzwiek przy alertach." },
    { "Alerty i dziennik", "autoLog", "Dziennik transakcji z komunikatow AH (sprzedaz / wygasniecie) i hooka wystawiania." },
    { "Alerty i dziennik", "mailLog", "Realny przychod z faktur AH na poczcie (nieprzeczytane maile 'Auction successful')." },
    { "Alerty i dziennik", "tooltip", "Werdykt i ceny w tooltipie przedmiotu." },

    { "Uczenie (ML)", "mlUse", "Model sprzedazy wplywa na werdykty. Wylaczone = tryb cienia (liczy, ale nic nie zmienia)." },
    { "Uczenie (ML)", "mlAutoCal", "Automatycznie koryguje margines na podstawie trafnosci werdyktow KUP." },

    { "Wyglad i Hub", "scale", "Skala okien (0.6-1.5)." },
    { "Wyglad i Hub", "uiAlpha", "Przezroczystosc tla okien (0.3-1)." },
    { "Wyglad i Hub", "fontScale", "Mnoznik rozmiaru czcionki. Dziala po /reload." },
    { "Wyglad i Hub", "colorblind", "Niebieski / pomaranczowy zamiast zielonego / czerwonego." },
    { "Wyglad i Hub", "minimapShow", "Przycisk przy minimapie." },
    { "Wyglad i Hub", "hubAuto", "Otwieraj Hub razem z domem aukcyjnym." },
    { "Wyglad i Hub", "listJump", "Klik w przedmiot na Liscie w Hubie otwiera HUD z analiza (przycisk Cofnij wraca)." },
    { "Wyglad i Hub", "gapMinProfit", "Luki cenowe: minimalny zysk z jednego transportu.", true },
}

local ctl = { rows = {}, items = {}, groups = {} }
local Refresh

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function BuildItems()
    local byKey = {}
    for _, f in ipairs(ns.FIELDS) do byKey[f.key] = { kind = "field", def = f, key = f.key } end
    for _, t in ipairs(ns.TOGGLES) do byKey[t.key] = { kind = "toggle", def = t, key = t.key } end
    local out, used, seenGroup = {}, {}, {}
    for _, m in ipairs(META) do
        local it = byKey[m[2]]
        if it and not HIDE[m[2]] then
            it.group, it.tip, it.adv = m[1], m[3], m[4] and true or false
            out[#out + 1] = it
            used[m[2]] = true
            if not seenGroup[m[1]] then seenGroup[m[1]] = true; ctl.groups[#ctl.groups + 1] = m[1] end
        end
    end
    local extra = {}
    for k, it in pairs(byKey) do
        if not used[k] and not HIDE[k] then extra[#extra + 1] = k end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do
        local it = byKey[k]
        it.group, it.tip, it.adv = "Inne", "", false
        out[#out + 1] = it
    end
    if #extra > 0 then ctl.groups[#ctl.groups + 1] = "Inne" end
    ctl.items = out
end

local function DefaultOf(it)
    local dv = ns.DEFAULTS and ns.DEFAULTS[it.key]
    if dv == nil then dv = EXTRA_DEF[it.key] end
    return dv
end

local function CanReset(it)
    local dv = DefaultOf(it)
    if dv == nil or type(dv) == "table" then return false end
    if it.kind == "toggle" then
        if it.def.get or type(dv) ~= "boolean" then return false end
        return (ns.db[it.key] and true or false) ~= dv
    end
    local cur = ns.db[it.key]
    if cur == nil then cur = dv end
    return cur ~= dv
end

local function AfterChange()
    if ns.ApplyOpacity then ns.ApplyOpacity() end
    if ns.ApplyScale then ns.ApplyScale() end
    ns.UpdateUI()
end

local function ResetItem(it)
    local dv = DefaultOf(it)
    if dv == nil then return end
    if it.kind == "field" then
        ns.SetField(it.def, it.def.kind == "money" and ns.MoneyPlain(dv) or tostring(dv))
    elseif it.def.set then
        it.def.set(dv)
    else
        ns.db[it.key] = dv
    end
end

local function Fill(row, it, showGroup)
    row.it = it
    row.label:SetText(it.def.label)
    row.tag:SetText(showGroup and (GRAY .. it.group .. "|r") or "")
    if it.kind == "field" then
        row.check:Hide()
        row.box:Show()
        local v = ns.db[it.key]
        if v == nil then v = EXTRA_DEF[it.key] end
        row.box:SetText(it.def.kind == "money" and ns.MoneyPlain(v) or tostring(v == nil and "" or v))
        row.box:SetCursorPosition(0)
        row.box:SetTextColor(1, 1, 1)
        row.dirty = false
    else
        row.box:Hide()
        row.check:Show()
        local v
        if it.def.get then v = it.def.get() else v = ns.db[it.key] end
        row.check:SetChecked(v and true or false)
    end
    row.reset:SetShown(CanReset(it))
end

local function Visible()
    local q = trim(ctl.search:GetText()):lower()
    local out = {}
    for _, it in ipairs(ctl.items) do
        local match
        if q ~= "" then
            match = it.def.label:lower():find(q, 1, true) or it.key:lower():find(q, 1, true)
                or (it.tip or ""):lower():find(q, 1, true)
        else
            match = (it.group == ctl.group)
        end
        if match and (not it.adv or ns.db.cfgAdvanced or q ~= "") then out[#out + 1] = it end
    end
    return out, q ~= ""
end

function Refresh()
    if not ctl.built then return end
    local list, searching = Visible()
    for i, b in ipairs(ctl.catBtns) do ns.SetActive(b, (not searching) and b.group == ctl.group) end
    if searching then
        ctl.header:SetText(BLUE .. "Wyniki wyszukiwania|r  " .. GRAY .. #list .. "|r")
    else
        ctl.header:SetText(BLUE .. ctl.group .. "|r")
    end
    for i = 1, ROWS do
        local row, it = ctl.rows[i], list[i]
        if it then
            row:Show()
            row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.035 or 0)
            Fill(row, it, searching)
        else
            row.it = nil
            row:Hide()
        end
    end
    ctl.adv:SetChecked(ns.db.cfgAdvanced and true or false)
   if #list > ROWS then ctl.status:SetText("|cffffa040Pokazano " .. ROWS .. " z " .. #list .. " - zawez fraze.|r") end
end

local function Commit(row)
    local it = row.it
    if not (it and row.dirty) then return end
    row.dirty = false
    local ok, err = ns.SetField(it.def, row.box:GetText())
    if ok then
        ctl.status:SetText(GREEN .. "Zapisano: " .. it.def.label .. "|r")
        AfterChange()
        Refresh()
    else
        row.box:SetTextColor(1, 0.3, 0.3)
        ctl.status:SetText(RED .. (err or "Niepoprawna wartosc") .. "|r")
    end
end

local function BuildRow(parent, i)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(ROW_W, ROW_H - 2)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:EnableMouse(true)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()

    row.label = ns.MakeFS(row, 11)
    row.label:SetPoint("LEFT", 8, 0)
    row.label:SetWidth(420)
    row.label:SetWordWrap(false)

    row.box = ns.MakeInput(row, 150)
    row.box:SetPoint("LEFT", 444, 0)
    row.box:SetScript("OnTextChanged", function(_, user) if user then row.dirty = true end end)
    row.box:SetScript("OnEnterPressed", function(self) Commit(row); self:ClearFocus() end)
    row.box:SetScript("OnEditFocusLost", function() Commit(row) end)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(24, 24)
    row.check:SetPoint("LEFT", 438, 0)
    row.check:SetScript("OnClick", function(self)
        local it = row.it
        if not it then return end
        local v = self:GetChecked() and true or false
        if it.def.set then it.def.set(v) else ns.db[it.key] = v end
        ctl.status:SetText(GREEN .. "Zapisano: " .. it.def.label .. "|r")
        AfterChange()
        Refresh()
    end)

    row.reset = ns.MakeButton(row, "R", 24, 20)
    row.reset:SetPoint("LEFT", 606, 0)
    row.reset:SetScript("OnClick", function()
        if row.it then
            ResetItem(row.it)
            ctl.status:SetText(GRAY .. "Przywrocono domyslna: " .. row.it.def.label .. "|r")
            AfterChange()
            Refresh()
        end
    end)
    ns.Tip(row.reset, "Przywroc wartosc domyslna")

    row.tag = ns.MakeFS(row, 9)
    row.tag:SetPoint("LEFT", 640, 0)
    row.tag:SetWidth(136)
    row.tag:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        local it = self.it
        if not it then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(it.def.label, 1, 1, 1)
        if it.tip and it.tip ~= "" then GameTooltip:AddLine(it.tip, 0.8, 0.8, 0.8, true) end
        if it.kind == "field" then
            GameTooltip:AddLine("/tsma set " .. it.key .. " <wartosc>", 0.5, 0.7, 1)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    return row
end

local function ResetGroup()
    local label = "Przywroc domyslne (grupa)"
    if not ctl.confirm then
        ctl.confirm = true
        ctl.resetBtn:SetText("Na pewno? Kliknij ponownie")
        C_Timer.After(4, function()
            ctl.confirm = false
            ctl.resetBtn:SetText(label)
        end)
        return
    end
    ctl.confirm = false
    ctl.resetBtn:SetText(label)
    local n = 0
    for _, it in ipairs(ctl.items) do
        if it.group == ctl.group and CanReset(it) then ResetItem(it); n = n + 1 end
    end
    ctl.status:SetText(GRAY .. "Przywrocono domyslne: " .. n .. " opcji w grupie " .. ctl.group .. "|r")
    AfterChange()
    Refresh()
end

function ns.BuildSettings(p)
    local db = ns.db
    BuildItems()
    ctl.group = ctl.groups[1]

    -- lewa kolumna: wyszukiwarka, grupy, zaawansowane, reset
    local sl = ns.MakeFS(p, 10)
    sl:SetPoint("TOPLEFT", 8, -2)
    sl:SetText(GRAY .. "SZUKAJ USTAWIENIA|r")
    ctl.search = ns.MakeInput(p, 150)
    ctl.search:SetPoint("TOPLEFT", 14, -16)
    ctl.search:SetScript("OnTextChanged", function(_, user) if user then Refresh() end end)

    ctl.catBtns = {}
    for i, g in ipairs(ctl.groups) do
        local b = ns.FlatButton(p, 156, 26)
        b:SetPoint("TOPLEFT", 8, -50 - (i - 1) * 30)
        b.group = g
        b.text:SetText(g)
        b:SetScript("OnClick", function()
            ctl.group = g
            ctl.search:SetText("")
            Refresh()
        end)
        ctl.catBtns[i] = b
    end

    ctl.adv = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    ctl.adv:SetSize(24, 24)
    ctl.adv:SetPoint("TOPLEFT", 6, -444)
    ctl.adv:SetScript("OnClick", function(self)
        ns.db.cfgAdvanced = self:GetChecked() and true or false
        Refresh()
    end)
    local al = ns.MakeFS(p, 11)
    al:SetPoint("LEFT", ctl.adv, "RIGHT", 2, 0)
    al:SetText("Pokaz zaawansowane")

    ctl.resetBtn = ns.MakeButton(p, "Przywroc domyslne (grupa)", 156, 24)
    ctl.resetBtn:SetPoint("TOPLEFT", 8, -476)
    ctl.resetBtn:SetScript("OnClick", ResetGroup)

    -- prawa czesc: naglowek, wiersze, status
    ctl.header = ns.MakeFS(p, 13)
    ctl.header:SetPoint("TOPLEFT", 180, -4)
    local content = CreateFrame("Frame", nil, p)
    content:SetPoint("TOPLEFT", 180, -30)
    content:SetSize(ROW_W, ROWS * ROW_H)
    for i = 1, ROWS do ctl.rows[i] = BuildRow(content, i) end

    ctl.status = ns.MakeFS(p, 10)
    ctl.status:SetPoint("TOPLEFT", 180, -30 - ROWS * ROW_H - 6)
    ctl.status:SetWidth(ROW_W)
    ctl.status:SetWordWrap(false)

    ctl.built = true
    Refresh()
end

function ns.LoadSettings()
    ctl.status:SetText("")
    Refresh()
end
