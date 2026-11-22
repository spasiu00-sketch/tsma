local ADDON, ns = ...

------------------------------------------------------------------
-- JEDEN PANEL BOCZNY Z ZAKLADKAMI
-- Zamiast kilku rozrzuconych okien (Panel, Lista, Rynek, ML, Ustawienia) obok HUD jest pasek zakladek;
-- klik otwiera wybrany panel zadokowany przy prawej krawedzi HUD, ponowny klik go zamyka.
-- Zakladka zapamietuje sie miedzy sesjami, a panele podazaja za HUD (jego pozycje zapamietuje HUD).
-- Duzy wykres i Hub (styl Goldwright) zostaja osobnymi oknami (wlasne pozycje zapamietywane osobno).
------------------------------------------------------------------

local TABS = {
    { key = "panel",  label = "Panel", name = "TsmAnalizePanel",  tip = "Okazje, dziennik, craft" },
    { key = "watch",  label = "Lista", name = "TsmAnalizeWatch",  tip = "Lista obserwowanych: dodawanie, grupy, kategorie" },
    { key = "market", label = "Rynek", name = "TsmAnalizeMarket", tip = "Wszystkie przedmioty z archiwum: zmiany cen, filtry" },
    { key = "ml",     label = "ML",    name = "TsmAnalizeML",     tip = "Uczenie: model sprzedazy, prognoza, wzorce" },
    { key = "cfg",    label = "Ustaw", name = "TsmAnalizeConfig", tip = "Ustawienia" },
}

local BTN_W, BTN_H, GAP, DOCK_W = 56, 28, 4, 62
local buttons = {}
local current
local suspend = false

local function Sync()
    for _, b in ipairs(buttons) do
        local active = (b.key == current)
        b.accent:SetShown(active)
        b.bg:SetColorTexture(active and 0.14 or 0.09, active and 0.30 or 0.10, active and 0.52 or 0.13, 1)
        b.text:SetText((active and "|cffffffff" or "|cff9aa0a6") .. b.label .. "|r")
    end
end

function ns.DockSelect(key, force)
    local hud = ns.frame
    if not (hud and ns.db) then return end
    if key and key == current and not force then key = nil end   -- ponowny klik = zamknij
    current = key
    ns.db.sideTab = key
    ns.db.panelShown = (key == "panel")
    for _, t in ipairs(TABS) do
        local f = _G[t.name]
        if f then
            if t.key == key then
                if not hud:IsShown() then hud:Show(); ns.db.shown = true end
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", hud, "TOPRIGHT", DOCK_W + 2, 0)
                f:Show()
            else
                f:Hide()
            end
        end
    end
    Sync()
end

-- przycisk-skrot do osobnego okna (duzy wykres, Hub)
local function ShortcutButton(hud, index, text, tip, onClick)
    local cb = CreateFrame("Button", nil, hud)
    cb:SetSize(BTN_W, BTN_H)
    cb:SetPoint("TOPLEFT", hud, "TOPRIGHT", 2, -34 - #TABS * (BTN_H + GAP) - 8 - (index - 1) * (BTN_H + GAP))
    cb.bg = cb:CreateTexture(nil, "BACKGROUND")
    cb.bg:SetAllPoints()
    cb.bg:SetColorTexture(0.09, 0.10, 0.13, 1)
    local hl = cb:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    cb.text = ns.MakeFS(cb, 11, "CENTER")
    cb.text:SetPoint("CENTER", 0, 0)
    cb.text:SetText("|cff9aa0a6" .. text .. "|r")
    cb:SetScript("OnClick", onClick)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tip, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cb
end

local function BuildStrip()
    local hud = ns.frame
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, hud)
        b:SetSize(BTN_W, BTN_H)
        b:SetPoint("TOPLEFT", hud, "TOPRIGHT", 2, -34 - (i - 1) * (BTN_H + GAP))
        b.key, b.label = t.key, t.label
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.accent = b:CreateTexture(nil, "ARTWORK")
        b.accent:SetColorTexture(0.2, 0.67, 1, 1)
        b.accent:SetPoint("TOPLEFT", 0, 0)
        b.accent:SetPoint("BOTTOMLEFT", 0, 0)
        b.accent:SetWidth(3)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        b.text = ns.MakeFS(b, 11, "CENTER")
        b.text:SetPoint("CENTER", 1, 0)
        b:SetScript("OnClick", function() ns.DockSelect(t.key) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(t.tip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        buttons[#buttons + 1] = b
    end

    -- skroty do osobnych okien
    ShortcutButton(hud, 1, "Wykres", "Duzy wykres (swiece, nakladki, porownanie)", function()
        if ns.ToggleBigChart then ns.ToggleBigChart() end
    end)
    ShortcutButton(hud, 2, "Hub", "Hub w stylu Goldwright: Sprzedaj, Moje aukcje, Zakupy, Luki cenowe", function()
        if ns.ToggleHub then ns.ToggleHub() end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db or not ns.frame then return end
    self:UnregisterEvent("ADDON_LOADED")

    ns.Safe("dock", BuildStrip)

    -- panele nie sa juz przeciagane osobno: kotwiczy je dok
    for _, t in ipairs(TABS) do
        local f = _G[t.name]
        if f then
            f:RegisterForDrag()
            f:HookScript("OnHide", function()
                if suspend then return end
                if current == t.key then
                    current = nil
                    ns.db.sideTab = nil
                    ns.db.panelShown = false
                    Sync()
                end
            end)
        end
    end

    -- zamkniecie / otwarcie HUD chowa i przywraca wybrany panel
    ns.frame:HookScript("OnHide", function()
        suspend = true
        for _, t in ipairs(TABS) do
            local f = _G[t.name]
            if f then f:Hide() end
        end
        suspend = false
    end)
    ns.frame:HookScript("OnShow", function()
        if current then ns.DockSelect(current, true) end
    end)

    -- istniejace funkcje otwierania przechodza przez dok
    local origShowPanel = ns.ShowPanel
    function ns.ShowPanel(mode)
        ns.DockSelect("panel", true)
        if origShowPanel then origShowPanel(mode) end
    end
    function ns.TogglePanel() ns.DockSelect("panel") end
    function ns.ToggleConfig() ns.DockSelect("cfg") end
    function ns.ToggleWatchMenu() ns.DockSelect("watch") end

    -- stan poczatkowy: wszystko zamkniete, potem przywrocenie zapamietanej zakladki
    suspend = true
    for _, t in ipairs(TABS) do
        local f = _G[t.name]
        if f then f:Hide() end
    end
    suspend = false
    current = nil
    Sync()
    if ns.db.sideTab and ns.frame:IsShown() then ns.DockSelect(ns.db.sideTab, true) end
end)
