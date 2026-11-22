local ADDON, ns = ...

------------------------------------------------------------------
-- JEDNO OKNO NA RAZ: HUD, Hub i duzy wykres nie zaslaniaja sie nawzajem.
-- Otwarcie jednego zamyka pozostale. HUD ukryty w ten sposob wraca sam, gdy zamkniesz Hub / wykres
-- (jesli byl wczesniej otwarty). Panele Okazje / Lista / Rynek / ML sa wewnatrz Huba, wiec zamykaja sie razem z nim.
------------------------------------------------------------------

local HUD = "TsmAnalizeFrame"
local NAMES = { HUD, "TsmAnalizeHub", "TsmAnalizeBigChart" }

local hooked = {}
local busy = false
local hudAuto = false   -- HUD ukryty przez ten modul (do przywrocenia)

local function OtherShown()
    for _, n in ipairs(NAMES) do
        if n ~= HUD then
            local f = _G[n]
            if f and f:IsShown() then return true end
        end
    end
    return false
end

local function OnShown(name)
    if busy then return end
    busy = true
    for _, n in ipairs(NAMES) do
        local f = _G[n]
        if n ~= name and f and f:IsShown() then
            f:Hide()
            if n == HUD then hudAuto = true end
        end
    end
    if name == HUD then hudAuto = false end
    busy = false
end

local function OnHidden(name)
    if busy or name == HUD then return end
    if hudAuto and not OtherShown() then
        hudAuto = false
        local hud = ns.frame
        if hud and ns.db and ns.db.shown then hud:Show() end
    end
end

local function Hook(name)
    local f = _G[name]
    if not f or hooked[name] then return end
    hooked[name] = true
    f:HookScript("OnShow", function() OnShown(name) end)
    f:HookScript("OnHide", function() OnHidden(name) end)
end

-- duzy wykres powstaje dopiero przy pierwszym otwarciu
local origToggle = ns.ToggleBigChart
function ns.ToggleBigChart()
    if origToggle then origToggle() end
    Hook("TsmAnalizeBigChart")
    local f = _G.TsmAnalizeBigChart
    if f and f:IsShown() then OnShown("TsmAnalizeBigChart") end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    for _, n in ipairs(NAMES) do Hook(n) end
end)
