local ADDON, ns = ...

------------------------------------------------------------------
-- ARCHIWUM CEN WSZYSTKICH PRZEDMIOTOW
--  * skan: po zalogowaniu (i co arcEveryMin) addon odczytuje z TSM cene minimalna WSZYSTKICH przedmiotow, o ktorych TSM ma dane
--    (pelne przeszukanie ID raz na dobe, miedzy nimi tylko znane przedmioty), z podzialem na male porcje (bez przycinania gry)
--  * zapis: jedna kompaktowa linia tekstu na przedmiot, wpis dobowy = min / max / cena koncowa (8 znakow na dobe)
--  * wykres DOWOLNEGO przedmiotu (tez nieobserwowanego): starsze dni dopinane z archiwum
--  * okno "Rynek": wszystkie przedmioty z archiwum, sortowanie wg ceny, zmiany 24h / 7 dni / wzgledem mediany 30 dni
-- Dane TSM zmieniaja sie tylko po zeskanowaniu AH albo po /reload (patrz wczesniej), wiec archiwum zapisuje
-- stan z kazdego takiego momentu, w ktorym gra jest wlaczona.
------------------------------------------------------------------

local DEFAULTS = { arcOn = true, arcMaxID = 60000, arcKeepDays = 60, arcEveryMin = 30, arcMinPrice = 10000, arcFullT = 0 }
local BASE_DAY = 20454            -- 2026-01-01 (dni od 1970)
local BUDGET_MS = 4               -- ile ms na klatke zuzywa skan
local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local SCALE = 186                 -- kwantyzacja logarytmiczna ceny: krok ~0.5%

ns.arcToday, ns.arcNow, ns.arcInfo = {}, {}, {}

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

local ENC, DEC = {}, {}
for i = 1, 64 do
    local c = ALPHA:sub(i, i)
    ENC[i - 1] = c
    DEC[c:byte()] = i - 1
end

local function enc2(n)
    n = clamp(math.floor(n), 0, 4095)
    return ENC[math.floor(n / 64)] .. ENC[n % 64]
end

local function dec2(s, pos)
    local a, b = s:byte(pos, pos + 1)
    return (DEC[a] or 0) * 64 + (DEC[b] or 0)
end

local function v2q(v) return clamp(math.floor(math.log(math.max(v, 1)) * SCALE + 0.5), 0, 4095) end
local function q2v(q) return math.exp(q / SCALE) end

local function dayIdx(t) return math.floor(t / 86400) - BASE_DAY end

local function InitDB()
    local db = ns.db
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    db.arc = db.arc or {}           -- [itemID] = tekst: rekordy po 8 znakow (doba, min, max, koniec)
    ns.arcDay = dayIdx(time())
    -- retencja
    local keepFrom = ns.arcDay - db.arcKeepDays
    for id, s in pairs(db.arc) do
        while #s >= 8 and dec2(s, 1) < keepFrom do s = s:sub(9) end
        db.arc[id] = (#s >= 8) and s or nil
    end
end

------------------------------------------------------------------
-- Skan cen z TSM (porcjami)
------------------------------------------------------------------
local scan   -- stan biezacego skanu

local function tsmMin(id)
    local ok, v = pcall(TSM_API.GetCustomPriceValue, "DBMinBuyout", "i:" .. id)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil
end

local Flush

local function Finish()
    local db = ns.db
    ns.arcInfo.scanT = time()
    ns.arcInfo.found = scan.found
    ns.arcInfo.full = scan.full
    if scan.full then db.arcFullT = time() end
    scan = nil
    Flush()
    if ns.arcOnScan then ns.Safe("market", ns.arcOnScan) end
end

local function Step()
    if not scan then return end
    local t0 = debugprofilestop()
    local today = ns.arcToday
    while scan.i <= scan.n and debugprofilestop() - t0 < BUDGET_MS do
        local id = scan.list and scan.list[scan.i] or scan.i
        scan.i = scan.i + 1
        local v = tsmMin(id)
        if v then
            scan.found = scan.found + 1
            ns.arcNow[id] = v
            local t = today[id]
            if not t then
                today[id] = { v, v, v }
            else
                if v < t[1] then t[1] = v end
                if v > t[2] then t[2] = v end
                t[3] = v
            end
        end
    end
    if scan.i <= scan.n then
        C_Timer.After(0, Step)
    else
        Finish()
    end
end

local function StartScan(full)
    local db = ns.db
    if scan or not db or not db.arcOn or not ns.HasTSM() then return false end
    -- zmiana doby w trakcie sesji: zapisz wczoraj i zacznij od nowa
    local d = dayIdx(time())
    if d ~= ns.arcDay then
        Flush()
        ns.arcToday = {}
        ns.arcDay = d
    end
    scan = { i = 1, found = 0, full = full }
    if full then
        scan.n = db.arcMaxID
    else
        local list, seen = {}, {}
        for id in pairs(db.arc) do seen[id] = true; list[#list + 1] = id end
        for id in pairs(ns.arcNow) do
            if not seen[id] then seen[id] = true; list[#list + 1] = id end
        end
        scan.list, scan.n = list, #list
    end
    C_Timer.After(0, Step)
    return true
end

-- zapis dobowy do db.arc (wywolywany co 20 min, po skanie i przy wylogowaniu / reloadzie)
function Flush()
    local db = ns.db
    if not (db and db.arc) then return end
    local today = dayIdx(time())
    if today ~= ns.arcDay and next(ns.arcToday) then today = ns.arcDay end   -- dane sa z poprzedniej doby
    local keepFrom = today - (db.arcKeepDays or 60)
    for id, t in pairs(ns.arcToday) do
        local s = db.arc[id] or ""
        local lo, hi, cl = t[1], t[2], t[3]
        if #s >= 8 and dec2(s, #s - 7) == today then
            local plo, phi = q2v(dec2(s, #s - 5)), q2v(dec2(s, #s - 3))   -- polacz z wczesniejszym zapisem tej doby
            lo, hi = math.min(lo, plo), math.max(hi, phi)
            s = s:sub(1, #s - 8)
        end
        s = s .. enc2(today) .. enc2(v2q(lo)) .. enc2(v2q(hi)) .. enc2(v2q(cl))
        while #s >= 8 and dec2(s, 1) < keepFrom do s = s:sub(9) end
        db.arc[id] = s
    end
end

------------------------------------------------------------------
-- Odczyt: rekordy, punkty do wykresu, metryki do okna Rynek
------------------------------------------------------------------
local function Records(id)
    local s = ns.db.arc[id]
    local out = {}
    if s then
        for pos = 1, #s - 7, 8 do
            out[#out + 1] = { day = dec2(s, pos), lo = q2v(dec2(s, pos + 2)), hi = q2v(dec2(s, pos + 4)), cl = q2v(dec2(s, pos + 6)) }
        end
    end
    -- dzisiejsze dane z pamieci (jeszcze nie zapisane) zastepuja zapis tej doby
    local t = ns.arcToday[id]
    if t then
        local today = ns.arcDay or dayIdx(time())
        if #out > 0 and out[#out].day == today then out[#out] = nil end
        out[#out + 1] = { day = today, lo = t[1], hi = t[2], cl = t[3] }
    end
    return out
end

local function ArchivePoints(id)
    local recs = Records(id)
    local pts = {}
    for _, r in ipairs(recs) do
        -- {czas, zamkniecie, min doby, max doby}
        pts[#pts + 1] = { (BASE_DAY + r.day) * 86400 + 43200, math.floor(r.cl + 0.5), math.floor(r.lo + 0.5), math.floor(r.hi + 0.5) }
    end
    return pts
end
ns.ArchivePoints = ArchivePoints

local function median(vals)
    local n = #vals
    if n == 0 then return nil end
    table.sort(vals)
    if n % 2 == 1 then return vals[(n + 1) / 2] end
    return (vals[n / 2] + vals[n / 2 + 1]) / 2
end

-- zwraca cene, zmiane 24h, 7 dni, wzgledem mediany 30 dni (w %); brakujace = nil
local function Metrics(id)
    local recs = Records(id)
    local n = #recs
    if n == 0 then return nil end
    local today = ns.arcDay or dayIdx(time())
    local cur = ns.arcNow[id] or recs[n].cl
    local d1, d7, vm
    local ref1, ref7
    for i = n, 1, -1 do
        local r = recs[i]
        if not ref1 and r.day < today then ref1 = r.cl end
        if not ref7 and r.day <= today - 7 then ref7 = r.cl; break end
    end
    if ref1 and ref1 > 0 then d1 = (cur / ref1 - 1) * 100 end
    if ref7 and ref7 > 0 then d7 = (cur / ref7 - 1) * 100 end
    local vals = {}
    for i = n, 1, -1 do
        if recs[i].day >= today - 30 then vals[#vals + 1] = recs[i].cl end
    end
    if #vals >= 3 then
        local m = median(vals)
        if m and m > 0 then vm = (cur / m - 1) * 100 end
    end
    return cur, d1, d7, vm
end

-- wykres dowolnego przedmiotu: starsze dni z archiwum dopinamy tylko na czas rysowania (bez wplywu na statystyki)
local origDraw = ns.DrawChart
function ns.DrawChart(chart, itemString, breakEven, alertPrice)
    local db = ns.db
    local id = db and db.arc and itemString and tonumber(itemString:match("^i:(%d+)"))
    local pts = id and ArchivePoints(id)
    if not pts or #pts == 0 then return origDraw(chart, itemString, breakEven, alertPrice) end

    local rec = db.items[itemString]
    local created = false
    if not rec then
        rec = { hist = {} }
        db.items[itemString] = rec
        created = true
    end
    local saved = rec.hist
    local first = saved[1] and saved[1][1] or math.huge
    local merged = {}
    for _, p in ipairs(pts) do
        if p[1] < first then merged[#merged + 1] = { p[1], p[2], 0, 2, { p[3], p[4] } } end   -- p[5] = min/max doby (swiece)
    end
    for _, p in ipairs(saved) do merged[#merged + 1] = p end
    rec.hist = merged
    local ok, err = pcall(origDraw, chart, itemString, breakEven, alertPrice)
    rec.hist = saved
    if created then db.items[itemString] = nil end
    if not ok then error(err, 0) end
end

------------------------------------------------------------------
-- Okno "Rynek": wszystkie przedmioty z archiwum
------------------------------------------------------------------
local win
local entries, view = {}, {}
local building = false
local sortKey, sortDesc = "d1", true
local offset, ROWS = 0, 18

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function Pct(v)
    if v == nil then return "|cff888888--|r" end
    return string.format("%s%+.1f%%|r", v >= 0 and "|cff33dd66" or "|cffff4040", v)
end

local function BuildView()
    if not win then return end
    local minPrice = ns.ParseMoney(win.minBox:GetText()) or 0
    local filter = trim(win.filter:GetText()):lower()
    view = {}
    for _, e in ipairs(entries) do
        if e.price >= minPrice then
            if filter == "" or ns.ItemName("i:" .. e.id):lower():find(filter, 1, true) or tostring(e.id) == filter then
                view[#view + 1] = e
            end
        end
    end
    table.sort(view, function(a, b)
        local x, y = a[sortKey], b[sortKey]
        if x == nil and y == nil then return a.id < b.id end
        if x == nil then return false end
        if y == nil then return true end
        if x == y then return a.id < b.id end
        if sortDesc then return x > y end
        return x < y
    end)
end

local function Refresh()
    if not (win and win:IsShown()) then return end
    win:SetScale(ns.db.scale or 1)
    local maxOff = math.max(0, #view - ROWS)
    offset = math.min(offset, maxOff)
    local info = ns.arcInfo
    local nArc = 0
    for _ in pairs(ns.db.arc) do nArc = nArc + 1 end
    if building then
        win.status:SetText("Liczenie zmian...")
    elseif not ns.HasTSM() then
        win.status:SetText("|cffff4040TSM nie wykryte.|r")
    else
        win.status:SetText(string.format("%d z %d przedmiotow w archiwum%s", #view, nArc,
            info.scanT and ("   |cff9aa0a6ostatni skan " .. date("%H:%M", info.scanT) .. "|r") or ""))
    end
    for k, b in pairs(win.sortBtns) do b:SetEnabled(k ~= sortKey) end
    for i = 1, ROWS do
        local row = win.rows[i]
        local e = view[offset + i]
        row.e = e
        if e then
            row:Show()
            row.name:SetText(ns.ItemName("i:" .. e.id))
            row.price:SetText(ns.Money(e.price))
            row.d1:SetText(Pct(e.d1))
            row.d7:SetText(Pct(e.d7))
            row.vm:SetText(Pct(e.vm))
            row.sel:SetShown(ns.db.selected == "i:" .. e.id)
        else
            row:Hide()
        end
    end
end

-- liczenie metryk wszystkich przedmiotow porcjami
local function BuildEntries()
    if building or not win then return end
    local db = ns.db
    local ids, seen = {}, {}
    for id in pairs(db.arc) do seen[id] = true; ids[#ids + 1] = id end
    for id in pairs(ns.arcNow) do
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    building = true
    local out, i = {}, 1
    local function step()
        local t0 = debugprofilestop()
        while i <= #ids and debugprofilestop() - t0 < 6 do
            local id = ids[i]
            i = i + 1
            local price, d1, d7, vm = Metrics(id)
            if price then out[#out + 1] = { id = id, price = price, d1 = d1, d7 = d7, vm = vm } end
        end
        if i <= #ids then
            win.status:SetText(string.format("Liczenie zmian... %d / %d", i - 1, #ids))
            C_Timer.After(0, step)
        else
            entries, building = out, false
            BuildView()
            Refresh()
        end
    end
    step()
end

function ns.arcOnScan()
    if win and win:IsShown() then BuildEntries() end
end

local function BuildWindow()
    local f = CreateFrame("Frame", "TsmAnalizeMarket", UIParent, "BackdropTemplate")
    win = f
    f:SetSize(524, 590)
    f:SetPoint("CENTER", -60, 0)
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
    if UISpecialFrames then tinsert(UISpecialFrames, "TsmAnalizeMarket") end

    local title = ns.MakeFS(f, 14)
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("|cff33aaffTSMA|r  Rynek - wszystkie przedmioty")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    f.status = ns.MakeFS(f, 10)
    f.status:SetPoint("TOPLEFT", 14, -32)
    f.status:SetWidth(496)

    local l1 = ns.MakeFS(f, 10)
    l1:SetPoint("TOPLEFT", 14, -50)
    l1:SetText("|cff9aa0a6NAZWA / ID|r")
    local l2 = ns.MakeFS(f, 10)
    l2:SetPoint("TOPLEFT", 226, -50)
    l2:SetText("|cff9aa0a6MIN. CENA|r")

    f.filter = ns.MakeInput(f, 190)
    f.filter:SetPoint("TOPLEFT", 20, -64)
    f.filter:SetScript("OnTextChanged", function(_, user)
        if user and not building then offset = 0; BuildView(); Refresh() end
    end)

    f.minBox = ns.MakeInput(f, 100)
    f.minBox:SetPoint("TOPLEFT", 232, -64)
    f.minBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        ns.db.arcMinPrice = ns.ParseMoney(self:GetText()) or 0
        offset = 0
        BuildView()
        Refresh()
    end)

    local recalc = ns.MakeButton(f, "Przelicz", 80, 22)
    recalc:SetPoint("TOPLEFT", 346, -64)
    recalc:SetScript("OnClick", function() BuildEntries() end)

    -- sortowanie: klik w naglowek = ta kolumna malejaco, ponowny klik = odwrocenie
    f.sortBtns = {}
    local SORTS = { { "price", "Cena", 214 }, { "d1", "24h", 70 }, { "d7", "7 dni", 70 }, { "vm", "vs mediana 30d", 120 } }
    local prev
    for _, sdef in ipairs(SORTS) do
        local b = ns.MakeButton(f, sdef[2], sdef[3], 20)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 14, -94) end
        b:SetScript("OnClick", function()
            if sortKey == sdef[1] then sortDesc = not sortDesc else sortKey, sortDesc = sdef[1], true end
            offset = 0
            BuildView()
            Refresh()
        end)
        f.sortBtns[sdef[1]] = b
        prev = b
    end

    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(500, 22)
        row:SetPoint("TOPLEFT", 12, -120 - (i - 1) * 24)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.2, 0.5, 1, 0.18)
        row.sel:Hide()

        row.name = ns.MakeFS(row, 11)
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetWidth(204)
        row.name:SetWordWrap(false)
        row.price = ns.MakeFS(row, 10, "RIGHT")
        row.price:SetPoint("LEFT", 212, 0)
        row.price:SetWidth(100)
        row.price:SetWordWrap(false)
        row.d1 = ns.MakeFS(row, 10, "RIGHT")
        row.d1:SetPoint("LEFT", 316, 0)
        row.d1:SetWidth(62)
        row.d7 = ns.MakeFS(row, 10, "RIGHT")
        row.d7:SetPoint("LEFT", 382, 0)
        row.d7:SetWidth(62)
        row.vm = ns.MakeFS(row, 10, "RIGHT")
        row.vm:SetPoint("LEFT", 440, 0)
        row.vm:SetWidth(56)

        row:SetScript("OnClick", function(self)
            if self.e then
                ns.Select("i:" .. self.e.id)
                Refresh()
            end
        end)
        row:Hide()
        f.rows[i] = row
    end

    f:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta * 3)
        Refresh()
    end)
    f:SetScript("OnShow", function()
        f.minBox:SetText(ns.MoneyPlain(ns.db.arcMinPrice or 0))
        if #entries == 0 then BuildEntries() else Refresh() end
    end)

end

if ns.UpdateUI then
    hooksecurefunc(ns, "UpdateUI", function() ns.Safe("market", Refresh) end)
end

------------------------------------------------------------------
-- Ustawienia, komendy, start
------------------------------------------------------------------
table.insert(ns.FIELDS, { key = "arcKeepDays", label = "Archiwum cen: dni (7-180)", kind = "num", min = 7, max = 180, int = true })
table.insert(ns.FIELDS, { key = "arcMaxID", label = "Archiwum: max ID przedmiotu", kind = "num", min = 1000, max = 300000, int = true })
table.insert(ns.TOGGLES, { key = "arcOn", label = "Archiwum cen wszystkich przedmiotow (dobowe)" })

local function ArcCommand(rest)
    local db = ns.db
    local v = (rest or ""):lower()
    if v == "on" or v == "off" then
        db.arcOn = (v == "on")
    elseif v == "full" then
        if StartScan(true) then ns.Print("Pelny skan ID uruchomiony (do " .. db.arcMaxID .. ").") else ns.Print("Skan juz trwa, archiwum wylaczone albo brak TSM.") end
        return
    end
    local n, bytes = 0, 0
    for _, s in pairs(db.arc) do n = n + 1; bytes = bytes + #s end
    local info = ns.arcInfo
    ns.Print(string.format("Archiwum cen: %s, %d przedmiotow, ok. %.1f MB danych, retencja %d dni", db.arcOn and "WLACZONE" or "wylaczone",
        n, bytes / 1048576, db.arcKeepDays))
    ns.Print(info.scanT and string.format("  Ostatni skan: %s (%s), znaleziono %d przedmiotow; ostatni pelny skan ID: %s",
        date("%H:%M:%S", info.scanT), info.full and "pelny" or "znane", info.found or 0,
        (db.arcFullT or 0) > 0 and date("%d.%m %H:%M", db.arcFullT) or "nigdy")
        or "  Skan jeszcze nie zakonczony w tej sesji.")
    ns.Print("  /tsma archive on|off | full   (okno: przycisk Rynek na HUD albo /tsma market)")
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if (cmd == "archive" or cmd == "archiwum") and ns.db and ns.db.arc then
        ArcCommand(rest)
    elseif (cmd == "market" or cmd == "rynek") and ns.db and win then
        if ns.DockSelect then ns.DockSelect("market") elseif win:IsShown() then win:Hide() else win:Show() end
    elseif origSlash then
        origSlash(msg)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGOUT" then
        ns.Safe("archive", Flush)
        return
    end
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.Safe("archive", InitDB)
    if ns.frame then ns.Safe("market", BuildWindow) end

    -- pierwszy skan po zaladowaniu danych przez TSM; pelny przeszukanie ID raz na dobe
    C_Timer.After(12, function()
        local db = ns.db
        local needFull = time() - (db.arcFullT or 0) > 86400
        ns.Safe("archive", StartScan, needFull)
    end)
    C_Timer.NewTicker(math.max(5, ns.db.arcEveryMin) * 60, function() ns.Safe("archive", StartScan, false) end)
    C_Timer.NewTicker(20 * 60, function() ns.Safe("archive", Flush) end)
end)
