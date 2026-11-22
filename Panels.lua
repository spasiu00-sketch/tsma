local ADDON, ns = ...

------------------------------------------------------------------
-- Dawny panel Okazje / Dziennik / Craft oraz stare okno ustawien zostaly usuniete
-- (okazje, craft i dziennik prowadzisz w TSM; ustawienia sa w zakladce Hub > Ustawienia).
-- Zostaly tylko: puste punkty wejscia, z ktorych korzystaja inne pliki, i okno eksportu CSV.
------------------------------------------------------------------

ns.panelMode = "scan"

-- brak panelu: wywolania z innych plikow sa bezpieczne i nic nie robia
function ns.UpdatePanel() end
function ns.ShowPanel() end
function ns.TogglePanel() end
function ns.ToggleConfig() end   -- Hub podmienia na zakladke Ustawienia
function ns.BuildPanels() end

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
        f:SetFrameStrata("FULLSCREEN_DIALOG")
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
