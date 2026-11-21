local ADDON, ns = ...

------------------------------------------------------------------
-- DANE Z BLIZZARD AH (silnik Python: AuctionEngine -> BlizzData.lua)
-- Tooltip: cena Blizzarda, wlasna mediana, ilosc, zmiana 24h, porownanie z TSM DBMarket.
-- Komenda: /tsma blizz  (wybrany przedmiot + najlepsze okazje, z ID i nazwa)
------------------------------------------------------------------

local function Entry(s)
    local d = _G.TsmAnalizeBlizz
    return d and d.items and d.items[s], d
end

-- nazwa: z BlizzData.lua (pole nm), a gdy jej brak - z gry/TSM
local function NameOf(s)
    local e = Entry(s)
    if e and e.nm and e.nm ~= "" then return e.nm end
    local n = ns.ItemName(s)
    if n and n ~= s then return n end
    return s
end

local function AgeText(d)
    if not d or not d.generated or d.generated == 0 then return "brak danych" end
    local m = math.floor((time() - d.generated) / 60)
    local txt = (m >= 120) and string.format("%dh temu", math.floor(m / 60)) or string.format("%d min temu", m)
    if m > 120 then txt = "|cffff4040" .. txt .. " (nieaktualne)|r" end
    return txt
end

local function Flags(f)
    local t = {}
    if f:find("O") then t[#t + 1] = "|cff33dd66okazja|r" end
    if f:find("D") then t[#t + 1] = "|cffff4040gwaltowny spadek|r" end
    if f:find("L") then t[#t + 1] = "|cffffcc33mala podaz|r" end
    return table.concat(t, ", ")
end

local function Lines(s)
    local e, d = Entry(s)
    if not e then return nil end
    local out = {}
    out[#out + 1] = { "Blizz AH: min / ilosc", ns.Money(e.m) .. "  x" .. e.q }
    out[#out + 1] = { "Blizz mediana teraz", ns.Money(e.d) }
    if e.h then
        local diff = (e.m / e.h - 1) * 100
        out[#out + 1] = { string.format("Wlasna mediana (%d pkt)", e.n or 0), ns.Money(e.h)
            .. string.format("  (%+.0f%%)", diff) }
    end
    if e.c then out[#out + 1] = { "Zmiana 24h", string.format("%+.1f%%", e.c) } end
    if e.p then
        local col = e.p >= 0 and "|cff33dd66" or "|cffff4040"
        out[#out + 1] = { string.format("Zysk wg mediany (AH %s%%)", tostring(d.cut)), string.format("%s%+.1f%%|r", col, e.p) }
    end
    local tsm = ns.cache and ns.cache[s]
    if tsm and tsm.market and tsm.market > 0 then
        out[#out + 1] = { "Blizz min vs TSM DBMarket", string.format("%+.0f%%", (e.m / tsm.market - 1) * 100) }
    end
    if e.f and e.f ~= "" then out[#out + 1] = { "Flagi", Flags(e.f) } end
    out[#out + 1] = { "|cff9aa0a6Dane Blizzarda|r", "|cff9aa0a6" .. AgeText(d) .. "|r" }
    return out
end

local function AddTip(tt, s)
    if not (ns.db and ns.db.tooltip) then return end
    local lines = Lines(s)
    if not lines then return end
    tt:AddLine(" ")
    for _, l in ipairs(lines) do tt:AddDoubleLine(l[1], l[2]) end
end

local function InitTip()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            ns.Safe("blizztip", function()
                if not data or (tt.IsForbidden and tt:IsForbidden()) then return end
                local s = data.hyperlink and ns.ResolveItem(data.hyperlink) or (data.id and ("i:" .. data.id))
                if s then AddTip(tt, s) end
            end)
        end)
    end
end

local function Plain(t) return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function Command()
    local d = _G.TsmAnalizeBlizz
    local n = 0
    if d and d.items then for _ in pairs(d.items) do n = n + 1 end end
    ns.Print(string.format("Blizzard AH: %d przedmiotow, dane: %s", n, Plain(AgeText(d))))
    local s = ns.db.selected
    if s then
        local lines = Lines(s)
        if lines then
            ns.Print(string.format("%s (%s):", NameOf(s), s))
            for _, l in ipairs(lines) do ns.Print("  " .. Plain(l[1]) .. ": " .. Plain(l[2])) end
        else
            ns.Print("Brak danych Blizzarda dla wybranego przedmiotu.")
        end
    end
    if d and d.deals and #d.deals > 0 then
        ns.Print("Najlepsze okazje (zysk wg wlasnej mediany po prowizji):")
        for i, x in ipairs(d.deals) do
            if i > 10 then break end
            local e = d.items and d.items[x[1]]
            local label = (e and e.nm and e.nm ~= "") and e.nm or ns.ItemLink(x[1])
            ns.Print(string.format("  %+.0f%%  %s  (%s)", x[2], label, x[1]))
        end
    end
end

-- /tsma blizz find <fragment nazwy lub ID>: szukanie w danych Blizzarda
local function Find(query)
    local d = _G.TsmAnalizeBlizz
    if not (d and d.items) then ns.Print("Brak danych Blizzarda."); return end
    query = (query or ""):lower()
    if query == "" then ns.Print("Uzycie: /tsma blizz find <fragment nazwy albo ID>"); return end
    local hits = {}
    for s, e in pairs(d.items) do
        local name = (e.nm or ""):lower()
        if name:find(query, 1, true) or s == query or s == ("i:" .. query) then
            hits[#hits + 1] = s
        end
    end
    table.sort(hits, function(a, b) return (d.items[a].m or 0) > (d.items[b].m or 0) end)
    if #hits == 0 then ns.Print("Nic nie znaleziono: " .. query); return end
    for i, s in ipairs(hits) do
        if i > 15 then ns.Print(string.format("  ... i %d wiecej", #hits - 15)); break end
        local e = d.items[s]
        ns.Print(string.format("  %s (%s): %s x%d", NameOf(s), s, Plain(ns.Money(e.m)), e.q or 0))
    end
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    if (cmd or ""):lower() == "blizz" and ns.db then
        local sub, arg = (rest or ""):match("^(%S*)%s*(.-)$")
        if (sub or ""):lower() == "find" then Find(arg) else Command() end
    elseif origSlash then
        origSlash(msg)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.Safe("blizztip", InitTip)
end)