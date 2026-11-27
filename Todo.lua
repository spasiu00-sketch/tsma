local ADDON, ns = ...

------------------------------------------------------------------
-- CO ZROBIC TERAZ: jedna kolejka akcji wg oczekiwanego zysku na dobe z alokacja kapitalu
--   zrodla: flipy z luki (Tracker.lua), snajpy (BlizzSnipe.lua), arbitraz miedzy domami (BlizzArb.lua), obserwowane z werdyktem KUP (Analyze)
--   wynik: lista { kind, s, cost, profit, days, roiDay, spend } ; alokacja zachlanna wg ROI/dobe do wyczerpania kapitalu
--   (max 25% kapitalu na jedna akcje; capital = 0 -> tylko ranking bez alokacji)
-- Komenda: /tsma todo | /tsma arb
------------------------------------------------------------------

local function Fresh(d, hours)
    return type(d) == "table" and (d.generated or 0) > 0 and time() - d.generated < hours * 3600
end

function ns.ArbRows()
    local d = _G.TsmAnalizeArb
    if not Fresh(d, 8) then return {} end
    local out = {}
    for _, r in ipairs(d.rows or {}) do
        out[#out + 1] = { s = r[1], buyAH = r[2], sellAH = r[3], buy = r[4], sell = r[5], qty = r[6], profit = r[7], gain = r[8],
            buyName = d.houses and d.houses[r[2]] or tostring(r[2]), sellName = d.houses and d.houses[r[3]] or tostring(r[3]) }
    end
    return out
end

function ns.Todo()
    local db = ns.db
    local acts = {}
    local sn = _G.TsmAnalizeSnipe
    if Fresh(sn, 3) then
        for _, r in ipairs(sn.rows or {}) do
            local cost = r[2] * r[3]
            if cost > 0 and r[5] > 0 then
                acts[#acts + 1] = { kind = "SNIPE", s = r[1], cost = cost, profit = r[5], days = 1,
                    text = string.format("kup %dx po %s (ref %s)", r[3], ns.MoneyPlain(r[2]), ns.MoneyPlain(r[4])) }
            end
        end
    end
    for _, f in ipairs(ns.Flips and ns.Flips() or {}) do
        acts[#acts + 1] = { kind = "FLIP", s = f.s, cost = f.cost, profit = f.profit, days = math.max(0.25, math.min(f.days or 1, 5)),
            text = string.format("kup %dx (sr. %s), wystaw za %s pod sciana %s", f.units, ns.MoneyPlain(f.avg), ns.MoneyPlain(f.sell), ns.MoneyPlain(f.wall)) }
    end
    for _, a in ipairs(ns.ArbRows()) do
        acts[#acts + 1] = { kind = "ARBITRAZ", s = a.s, cost = a.buy * a.qty, profit = a.profit, days = 2,
            text = string.format("%dx: %s po ~%s -> %s po %s", a.qty, a.buyName, ns.MoneyPlain(a.buy), a.sellName, ns.MoneyPlain(a.sell)) }
    end
    if ns.HasTSM() then
        for _, s in ipairs(ns.RefreshList()) do
            local d = ns.cache[s]
            if d and d.minbuy then
                local ok, r = pcall(ns.Analyze, s, d, nil)
                if ok and r and r.verdict == "BUY" and r.profit and r.buy and r.profit.net > 0 then
                    local qty = r.maxUnits or 20
                    if qty > 0 then
                        acts[#acts + 1] = { kind = "KUP", s = s, cost = r.buy * qty, profit = r.profit.net * qty,
                            days = r.profit.days or 3,
                            text = string.format("%dx po %s, wystaw za %s", qty, ns.MoneyPlain(r.buy), ns.MoneyPlain(r.suggest)) }
                    end
                end
            end
        end
    end
    for _, a in ipairs(acts) do a.roiDay = (a.profit / a.cost) / math.max(a.days, 0.25) * 100 end
    table.sort(acts, function(x, y)
        if x.roiDay ~= y.roiDay then return x.roiDay > y.roiDay end
        return x.profit > y.profit
    end)
    local cap = (db.capital or 0)
    if cap > 0 then
        local left = cap
        for _, a in ipairs(acts) do
            local spend = math.min(a.cost, left, cap * 0.25)
            a.spend = spend > 0 and spend or 0
            a.expected = a.profit * (a.spend / a.cost)
            left = left - a.spend
        end
    end
    return acts
end

local function Command()
    local acts = ns.Todo()
    if #acts == 0 then ns.Print("Brak akcji (potrzebne swieze BlizzSnipe / BlizzArb albo obserwowane z werdyktem KUP)."); return end
    local cap = ns.db.capital or 0
    ns.Print(cap > 0 and ("Kolejka akcji (ROI/dobe, kapital " .. ns.MoneyPlain(cap) .. "):") or "Kolejka akcji (ROI/dobe; ustaw capital, zeby dostac alokacje):")
    local total = 0
    for i = 1, math.min(12, #acts) do
        local a = acts[i]
        if cap > 0 and a.spend and a.spend > 0 then total = total + a.expected end
        ns.Print(string.format("  %d. [%s] %s  %s  | zysk ~%s, ROI %.0f%%/dobe%s", i, a.kind, ns.ItemName(a.s), a.text,
            ns.MoneyPlain(a.profit), a.roiDay, (cap > 0 and a.spend) and (", wydaj " .. ns.MoneyPlain(a.spend)) or ""))
    end
    if cap > 0 then ns.Print("  Oczekiwany zysk z alokacji: " .. ns.MoneyPlain(total)) end
end

local function ArbCommand()
    local rows = ns.ArbRows()
    if #rows == 0 then ns.Print("Brak arbitrazu (BlizzArb.lua puste/nieaktualne; dziala tylko przy parze z domem neutralnym)."); return end
    ns.Print("Arbitraz (kupno wg drabiny, sprzedaz po min z prowizja domu docelowego):")
    for i = 1, math.min(10, #rows) do
        local a = rows[i]
        ns.Print(string.format("  %s: %dx  %s po ~%s -> %s po %s  zysk %s (%+.0f%%)", ns.ItemName(a.s), a.qty, a.buyName,
            ns.MoneyPlain(a.buy), a.sellName, ns.MoneyPlain(a.sell), ns.MoneyPlain(a.profit), a.gain))
    end
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if cmd == "todo" and ns.db then
        Command()
    elseif cmd == "arb" and ns.db then
        ArbCommand()
    elseif origSlash then
        origSlash(msg)
    end
end

------------------------------------------------------------------
-- ZAKLADKA HUBA "Co teraz" (podpinana trzema liniami w Hub.lua, patrz PATCHES.md)
--   ns.BuildTodo(strona) buduje widok, ns.RefreshTodo() odswieza (wolane z RefreshHub gdy zakladka aktywna)
--   klik w wiersz = analiza przedmiotu w HUD (ns.Select), kolko myszy przewija
------------------------------------------------------------------
local TROWS, TROW_H = 15, 26
local GRAYT, GREENT, ORANGET, BLUET, REDT = "|cff9aa0a6", "|cff33dd66", "|cffffa040", "|cff33aaff", "|cffff4040"
local KIND_COL = { FLIP = "|cffffd100", SNIPE = "|cffff73e6", ARBITRAZ = "|cff33aaff", KUP = "|cff33dd66" }
local toff, tcache, tcacheT = 0, nil, 0

local function Age(d)
    if type(d) ~= "table" or (d.generated or 0) <= 0 then return REDT .. "brak|r" end
    local m = math.floor((time() - d.generated) / 60)
    local txt = (m >= 120) and string.format("%dh", math.floor(m / 60)) or string.format("%dmin", m)
    return (m > 180 and ORANGET or GREENT) .. txt .. "|r"
end

function ns.BuildTodo(p)
    local S = {}
    p.S = S
    ns.todoPage = p
    local function L(parent, x, y, w, size, justify)
        local fs = ns.MakeFS(parent, size or 10, justify)
        fs:SetPoint("TOPLEFT", x, y)
        if w then fs:SetWidth(w) end
        fs:SetWordWrap(false)
        return fs
    end
    S.btn = ns.MakeButton(p, "Przelicz", 80, 22)
    S.btn:SetPoint("TOPLEFT", 10, 0)
    S.btn:SetScript("OnClick", function() tcache = nil; ns.RefreshTodo() end)
    S.info = L(p, 100, -5, 860, 10)
    S.sum = L(p, 10, -28, 950, 11)
    local heads = { { "AKCJA", 10 }, { "PRZEDMIOT", 90 }, { "SZCZEGOLY", 330 }, { "KOSZT", 640 }, { "ZYSK", 724 },
        { "ROI/DOBE", 804 }, { "WYDAJ", 878 } }
    for _, h in ipairs(heads) do L(p, h[2], -52, nil, 9):SetText(GRAYT .. h[1] .. "|r") end
    S.rows = {}
    for i = 1, TROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(955, TROW_H - 2)
        row:SetPoint("TOPLEFT", 6, -68 - (i - 1) * TROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
        row.kind = L(row, 4, -6, 80, 10)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 84, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name = L(row, 106, -6, 216, 11)
        row.text = L(row, 326, -6, 306, 10)
        row.cost = L(row, 634, -6, 84, 10, "RIGHT")
        row.profit = L(row, 718, -6, 84, 10, "RIGHT")
        row.roi = L(row, 800, -6, 70, 10, "RIGHT")
        row.spend = L(row, 872, -6, 80, 10, "RIGHT")
        row:SetScript("OnClick", function(self)
            if self.a and ns.Select then ns.Select(self.a.s) end
        end)
        row:Hide()
        S.rows[i] = row
    end
    S.note = L(p, 10, -68 - TROWS * TROW_H - 6, 950, 10)
    S.note:SetText(GRAYT .. "ROI/dobe = (zysk / koszt) / dni obrotu. Snajpy i arbitraz licza sie z ostatniego eksportu AuctionEngine (po /reload). Klik w wiersz = analiza w HUD. Alokacja wymaga ustawionego kapitalu.|r")
end

function ns.TodoWheel(delta)
    toff = math.max(0, toff - delta * 3)
    ns.RefreshTodo()
end

function ns.RefreshTodo()
    local p = ns.todoPage
    if not (p and p.S) then return end
    local S = p.S
    if not tcache or time() - tcacheT > 10 then
        local ok, res = pcall(ns.Todo)
        tcache, tcacheT = ok and res or {}, time()
    end
    local list = tcache
    local cap = (ns.db and ns.db.capital) or 0
    toff = math.min(toff, math.max(0, #list - TROWS))
    S.info:SetText(GRAYT .. "Dane (wiek): snajpy |r" .. Age(_G.TsmAnalizeSnipe) .. GRAYT .. "  arbitraz |r" .. Age(_G.TsmAnalizeArb)
        .. GRAYT .. "  prognozy |r" .. Age(_G.TsmAnalizeForecast) .. GRAYT .. "  Blizzard |r" .. Age(_G.TsmAnalizeBlizz))
    local total, spend = 0, 0
    for _, a in ipairs(list) do
        if a.spend and a.spend > 0 then total, spend = total + (a.expected or 0), spend + a.spend end
    end
    if #list == 0 then
        S.sum:SetText(GRAYT .. "Brak akcji: potrzebne swieze dane z AuctionEngine (snajpy, arbitraz) albo obserwowane przedmioty z werdyktem KUP.|r")
    elseif cap > 0 then
        S.sum:SetText(string.format("%d akcji  |  alokacja: wydaj %s, oczekiwany zysk %s%s|r (kapital %s)", #list, ns.MoneyPlain(spend),
            GREENT, ns.MoneyPlain(total), ns.MoneyPlain(cap)))
    else
        S.sum:SetText(string.format("%d akcji  |  %sUstaw kapital (Ustawienia > Kapital i ryzyko), zeby dostac alokacje.|r", #list, ORANGET))
    end
    for i = 1, TROWS do
        local row, a = S.rows[i], list[toff + i]
        row.a = a
        if a then
            row:Show()
            row.kind:SetText((KIND_COL[a.kind] or "") .. a.kind .. "|r")
            row.icon:SetTexture(ns.ItemIcon(a.s))
            row.name:SetText(ns.ItemName(a.s))
            row.text:SetText(GRAYT .. a.text .. "|r")
            row.cost:SetText(ns.MoneyPlain(a.cost))
            row.profit:SetText(GREENT .. ns.MoneyPlain(a.profit) .. "|r")
            row.roi:SetText(string.format("%.0f%%", a.roiDay))
            row.spend:SetText((a.spend and a.spend > 0) and ns.MoneyPlain(a.spend) or (cap > 0 and (GRAYT .. "-|r") or ""))
        else
            row:Hide()
        end
    end
end
