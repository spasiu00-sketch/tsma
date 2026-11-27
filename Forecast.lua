local ADDON, ns = ...

------------------------------------------------------------------
-- PROGNOZY Z SILNIKA (forecast.py -> BlizzForecast.lua): kwantyle p10 / p50 / p90 zmiany ceny min za 6 / 24 / 72 h.
-- Silnik eksportuje tylko horyzonty, ktore w walk-forward bily model bazowy i mialy sensowna kalibracje.
-- Tu: odczyt, notatki w Analyze, obnizenie werdyktu KUP przy prognozie spadku, komenda /tsma fc.
-- Etap potoku (Pipeline.lua, priorytet 10). Wczytaj PO Pipeline.lua.
------------------------------------------------------------------

local DEFAULTS = { fcOn = true, fcMinMed24 = -3, fcMaxAge = 8 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local HS = { 6, 24, 72 }

-- zwraca { f6 = {p10,p50,p90}, f24 = ..., f72 = ..., age = godziny } albo nil (brak / nieaktualne)
function ns.FcFor(s)
    local d = _G.TsmAnalizeForecast
    if type(d) ~= "table" or type(d.items) ~= "table" or (d.generated or 0) <= 0 then return nil end
    local age = (time() - d.generated) / 3600
    local maxAge = (ns.db and ns.db.fcMaxAge) or 8
    if age > maxAge then return nil end
    local e = d.items[s]
    if not e then return nil end
    local out = { age = age }
    for k, v in pairs(e) do out[k] = v end
    return out
end

function ns.FcLine(f, h)
    local x = f and f["f" .. h]
    if not x then return nil end
    return string.format("%+.1f%% (p10 %+.1f%%, p90 %+.1f%%)", x[2], x[1], x[3])
end

ns.AddStage("forecast", 10, function(nextFn, s, d, buy)
    local r = nextFn(s, d, buy)
    local db = ns.db
    if not (db and db.fcOn) or r.verdict == "NODATA" then return r end
    local f = ns.FcFor(s)
    if not f then return r end
    r.fc = f
    local x = f.f24 or f.f6
    local h = f.f24 and 24 or 6
    if x then
        local limit = db.fcMinMed24 or -3
        if r.verdict == "BUY" and x[2] <= limit * (h / 24) ^ 0.5 then
            r.verdict = "MARGINAL"
            table.insert(r.notes, 1, string.format("Prognoza +%dh: mediana %+.1f%% - werdykt obnizony (kup po spadku).", h, x[2]))
        elseif x[2] >= 4 and x[1] > -2 then
            table.insert(r.notes, 1, string.format("Prognoza +%dh: wzrost %+.1f%% (p10 %+.1f%%) - dobry moment na zakup.", h, x[2], x[1]))
        end
    end
    return r
end)

local function Plain(t) return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function Command()
    local d = _G.TsmAnalizeForecast
    if type(d) ~= "table" or not d.items then ns.Print("Brak prognoz (BlizzForecast.lua) - uruchom AuctionEngine z flow/forecast."); return end
    local n = 0
    for _ in pairs(d.items) do n = n + 1 end
    local hs = {}
    for h, sk in pairs(d.skill or {}) do hs[#hs + 1] = string.format("%dh (skill %+.0f%%)", h, sk * 100) end
    table.sort(hs)
    ns.Print(string.format("Prognozy: %d przedmiotow, wiek %.1f h, horyzonty: %s", n, (time() - (d.generated or 0)) / 3600,
        #hs > 0 and table.concat(hs, ", ") or "brak"))
    local s = ns.db.selected
    if s then
        local f = ns.FcFor(s)
        if f then
            for _, h in ipairs(HS) do
                local l = ns.FcLine(f, h)
                if l then ns.Print(string.format("  %s +%dh: %s", ns.ItemName(s), h, l)) end
            end
        else
            ns.Print("  Brak prognozy dla wybranego przedmiotu.")
        end
    end
    local up, down = {}, {}
    for s2, e in pairs(d.items) do
        local x = e.f24 or e.f6
        if x then
            local row = { s = s2, mid = x[2], lo = x[1] }
            if x[2] >= 3 and x[1] > -3 then up[#up + 1] = row elseif x[2] <= -3 then down[#down + 1] = row end
        end
    end
    table.sort(up, function(a, b) return a.mid > b.mid end)
    table.sort(down, function(a, b) return a.mid < b.mid end)
    ns.Print("Prognozowany wzrost (p10 > -3%):")
    for i = 1, math.min(8, #up) do ns.Print(string.format("  %+.1f%%  %s", up[i].mid, ns.ItemName(up[i].s))) end
    ns.Print("Prognozowany spadek (nie kupuj / sprzedaj zapas):")
    for i = 1, math.min(8, #down) do ns.Print(string.format("  %+.1f%%  %s", down[i].mid, ns.ItemName(down[i].s))) end
end

table.insert(ns.TOGGLES, { key = "fcOn", label = "Prognozy z silnika wplywaja na werdykt (BlizzForecast.lua)" })
table.insert(ns.FIELDS, { key = "fcMinMed24", label = "Prognoza: mediana 24h ponizej (%) obniza KUP", kind = "num", min = -50, max = 0 })

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if (cmd == "fc" or cmd == "prognoza") and ns.db then
        Command()
    elseif origSlash then
        origSlash(msg)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    for k, v in pairs(DEFAULTS) do
        if ns.db[k] == nil then ns.db[k] = v end
    end
end)
