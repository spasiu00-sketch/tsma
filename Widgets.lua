local ADDON, ns = ...

------------------------------------------------------------------
-- WSPOLNE WIDGETY I PALETA (jedno miejsce zamiast kopii w Hub/Chart/UI)
------------------------------------------------------------------

ns.THEME = {
    btn    = { 0.12, 0.13, 0.17 },
    btnOn  = { 0.14, 0.30, 0.52 },
    border = { 0.25, 0.27, 0.32 },
    accent = { 0.20, 0.67, 1.00 },
}

function ns.FlatButton(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    local c = ns.THEME.btn
    b.bg:SetColorTexture(c[1], c[2], c[3], 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.text = ns.MakeFS(b, 11, "CENTER")
    b.text:SetPoint("CENTER", 0, 0)
    return b
end

function ns.SetActive(b, on)
    local c = on and ns.THEME.btnOn or ns.THEME.btn
    b.bg:SetColorTexture(c[1], c[2], c[3], 1)
end

function ns.Tip(btn, text, anchor)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end