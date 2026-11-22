local ADDON, ns = ...

------------------------------------------------------------------
-- ALERTY (prog ceny, nowa okazja, podbita aukcja, stop-loss)
------------------------------------------------------------------
local function Notify(msg, itemString)
    local link = itemString and ns.ItemLink(itemString) or ""
    ns.Print(msg .. " " .. link)
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "TSMA: " .. msg, 1, 0.8, 0.2)
    end
if not ns.db or ns.db.alertSound ~= false then
    local snd = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
    pcall(PlaySound, snd, "Master")
end

function ns.CheckAlerts(list)
    local db = ns.db
    for _, s in ipairs(list) do
        local d = ns.cache[s]
        if d and d.minbuy then
            local st = ns.alertState[s]
            if not st then st = {}; ns.alertState[s] = st end

            -- 1) prog ceny
            local thr = db.alerts[s]
            if thr then
                if d.minbuy <= thr then
                    if not st.thr then
                        st.thr = true
                        Notify("cena spadla do " .. ns.MoneyPlain(d.minbuy) .. " (prog " .. ns.MoneyPlain(thr) .. ")", s)
                    end
                else
                    st.thr = false
                end
            end

            -- 2) nowa okazja (tylko obserwowane)
            if db.alertBuy and ns.IsWatched(s) then
                local r = ns.Analyze(s, d, nil)  -- zakladamy zakup po aktualnej min
                local good = (r.verdict == "BUY")
                if st.init and good and not st.good then
                    Notify(string.format("okazja: zysk ~%+.0f%%, ryzyko %s, wystaw za %s",
                        r.targetPct, ns.RISK_TEXT[r.risk.level], ns.MoneyPlain(r.suggest)), s)
                end
                st.good = good
                st.init = true
            end

            -- 3) podbita Twoja aukcja (ktos wystawil taniej niz Ty)
            if db.alertUndercut then
                local own = ns.OwnLowest and ns.OwnLowest(s)
                if own and d.minbuy < own then
                    if not st.under then
                        st.under = true
                        Notify(string.format("Twoja aukcja podbita: min %s < Twoja %s",
                            ns.MoneyPlain(d.minbuy), ns.MoneyPlain(own)), s)
                    end
                else
                    st.under = false
                end
            end

            -- 4) stop-loss dla przedmiotow w zapasie
            local lot, avg = db.lots[s], db.buyPrice[s]
            if lot and lot.qty and lot.qty > 0 and avg then
                local be = math.ceil(avg / (1 - ns.Cut() / 100))
                local limit = be * (1 - db.stopLoss / 100)
                if d.minbuy < limit then
                    if not st.stop then
                        st.stop = true
                        Notify(string.format("STOP-LOSS: cena %s ponizej progu %s (break-even %s, mam %d szt.)",
                            ns.MoneyPlain(d.minbuy), ns.MoneyPlain(limit), ns.MoneyPlain(be), lot.qty), s)
                    end
                else
                    st.stop = false
                end
            end
        end
    end
end

------------------------------------------------------------------
-- DZIENNIK / ZAKUPY
------------------------------------------------------------------
-- jedna logika sum: wpisy biezace + wpisy obciete do db.totals
local function accumulate(t, e)
    if e.kind == "buy" then
        t.spent = t.spent + e.qty * e.price
    elseif e.kind == "sell" then
        t.sells = t.sells + 1
        if e.profit then t.profit = t.profit + e.profit end
    elseif e.kind == "expired" and e.profit then
        t.profit = t.profit + e.profit
        t.lost = t.lost - e.profit
    end
end

local function trimLog()
    local db = ns.db
    local log = db.log
    while #log > 300 do
        accumulate(db.totals, table.remove(log, 1))
    end
end

-- odejmuje ilosc od otwartych wystawien (FIFO)
local function consumeOpen(s, qty)
    local op = ns.db.openPosts[s]
    if not op then return end
    while qty > 0 and op[1] do
        if op[1].qty <= qty then
            qty = qty - op[1].qty
            table.remove(op, 1)
        else
            op[1].qty = op[1].qty - qty
            qty = 0
        end
    end
    if #op == 0 then ns.db.openPosts[s] = nil end
end

function ns.Buy(s, qty, price)
    local db = ns.db
    local lot = db.lots[s]
    if not lot then lot = { qty = 0, cost = 0 }; db.lots[s] = lot end
    lot.qty = lot.qty + qty
    lot.cost = lot.cost + qty * price
    db.buyPrice[s] = math.floor(lot.cost / lot.qty + 0.5)
    db.log[#db.log + 1] = { t = time(), s = s, kind = "buy", qty = qty, price = price, c = ns.Who() }
    trimLog()
end

-- Zwraca: true, zysk (lub nil gdy brak ceny zakupu)  |  false, komunikat bledu
function ns.Sell(s, qty, price, noConsume)
    local db = ns.db
    local lot = db.lots[s]
    if lot and lot.qty and qty > lot.qty then
        return false, string.format("W zapasie masz tylko %d szt., a sprzedajesz %d. Dopisz brakujace zakupy (/tsma buy) albo popraw ilosc.",
            lot.qty, qty)
    end
    local keep = 1 - ns.Cut() / 100
    local avg = db.buyPrice[s]
    local profit
    if avg then profit = math.floor(qty * (price * keep - avg) + 0.5) end
    if lot then
        lot.qty = lot.qty - qty
        if avg then lot.cost = lot.cost - qty * avg end
        if lot.qty <= 0 then db.lots[s] = nil end
    end
    if not noConsume then consumeOpen(s, qty) end
    db.log[#db.log + 1] = { t = time(), s = s, kind = "sell", qty = qty, price = price, profit = profit,
        avg = avg, c = ns.Who() }
    trimLog()
    return true, profit
end

function ns.Post(s, qty, price)
    local db = ns.db
    db.log[#db.log + 1] = { t = time(), s = s, kind = "post", qty = qty, price = price, c = ns.Who() }
    local op = db.openPosts[s]
    if not op then op = {}; db.openPosts[s] = op end
    op[#op + 1] = { t = time(), qty = qty, price = price }
    trimLog()
end

-- Wygasla aukcja: tracimy depozyt (price = depozyt za sztuke)
function ns.Expire(s, qty, deposit, noConsume)
    local lost = qty * deposit
    if not noConsume then consumeOpen(s, qty) end
    ns.db.log[#ns.db.log + 1] = { t = time(), s = s, kind = "expired", qty = qty, price = deposit, profit = -lost,
        c = ns.Who() }
    trimLog()
    return -lost
end

-- zwraca: zysk netto (sprzedaze + utracone depozyty), wydano, liczba sprzedazy, utracone depozyty
-- charOnly = true: tylko wpisy biezacej postaci (bez sum ze starych, obcietych wpisow)
function ns.LedgerSummary(charOnly)
    local db = ns.db
    local t
    if charOnly then
        t = { profit = 0, spent = 0, sells = 0, lost = 0 }
    else
        t = { profit = db.totals.profit, spent = db.totals.spent, sells = db.totals.sells, lost = db.totals.lost }
    end
    local me = charOnly and ns.Who() or nil
    for _, e in ipairs(db.log) do
        if not charOnly or e.c == me then accumulate(t, e) end
    end
    return t.profit, t.spent, t.sells, t.lost
end

-- Wlasne prawdopodobienstwo sprzedazy z dziennika: sprzedane / (sprzedane + wygasle), ostatnie 45 dni.
-- Wygladzanie Laplace'a; zwraca p, liczbe rozliczonych sztuk
local sellStats, sellSig
local function buildSellStats()
    local log = ns.db.log
    local last = log[#log]
    local sig = #log .. ":" .. (last and last.t or 0)
    if sig == sellSig and sellStats then return sellStats end
    sellStats, sellSig = {}, sig
    local cutoff = time() - 45 * 86400
    for _, e in ipairs(log) do
        if e.t >= cutoff and (e.kind == "sell" or e.kind == "expired") then
            local st = sellStats[e.s]
            if not st then st = { sold = 0, exp = 0 }; sellStats[e.s] = st end
            if e.kind == "sell" then st.sold = st.sold + e.qty else st.exp = st.exp + e.qty end
        end
    end
    return sellStats
end

function ns.OwnSellProb(s)
    if not ns.db then return nil, 0 end
    local st = buildSellStats()[s]
    if not st then return nil, 0 end
    local n = st.sold + st.exp
    if n == 0 then return nil, 0 end
    return (st.sold + 1) / (n + 2), n
end

------------------------------------------------------------------
-- EKSPORT CSV (okno do skopiowania, bo addon nie moze zapisywac plikow)
------------------------------------------------------------------
local function csv(v)
    v = tostring(v == nil and "" or v)
    if v:find('[,"\n]') then
        local q = v:gsub('"', '""')
        v = '"' .. q .. '"'
    end
    return v
end

function ns.ExportLog()
    local rows = { "time,kind,character,item,itemString,qty,unit_price_copper,profit_copper,real_revenue_copper" }
    for _, e in ipairs(ns.db.log) do
        rows[#rows + 1] = table.concat({
            date("%Y-%m-%d %H:%M:%S", e.t), csv(e.kind), csv(e.c), csv(ns.ItemName(e.s)), csv(e.s),
            csv(e.qty), csv(e.price), csv(e.profit), csv(e.real),
        }, ",")
    end
    return table.concat(rows, "\n")
end

function ns.ExportHist(s)
    local rows = { "time,min_copper,market_copper,imported" }
    local rec = ns.db.items[s]
    if rec then
        for _, p in ipairs(rec.hist) do
            rows[#rows + 1] = string.format("%s,%d,%d,%d", date("%Y-%m-%d %H:%M:%S", p[1]), p[2] or 0, p[3] or 0, p[4] and 1 or 0)
        end
    end
    return table.concat(rows, "\n")
end

------------------------------------------------------------------
-- SKANER OKAZJI
------------------------------------------------------------------
ns.scan = { running = false, i = 0, total = 0, results = {}, scope = "", offset = 0 }

local MAX_SCAN = 3000

-- TSM_API moze wypelniac przekazana tabele i/lub ja zwracac - obslugujemy oba warianty
local function pick(ok, res, t)
    if ok and type(res) == "table" and next(res) ~= nil then return res end
    return t
end

local function collectItems(scope)
    local list, seen = {}, {}
    local function add(s)
        if type(s) == "string" and not seen[s] then
            seen[s] = true
            list[#list + 1] = s
        end
    end
    scope = strtrim(scope or "")

    if scope == "" then
        for _, s in ipairs(ns.db.watch) do add(s) end
        return list
    end

    if not (ns.HasTSM() and type(TSM_API.GetGroupItems) == "function") then
        return nil, "Ta wersja TSM nie udostepnia TSM_API.GetGroupItems - uzyj skanu listy obserwowanych (puste pole)."
    end

    local paths = {}
    if scope == "*" then
        if type(TSM_API.GetGroupPaths) ~= "function" then
            return nil, "Brak TSM_API.GetGroupPaths."
        end
        local t = {}
        local ok, res = pcall(TSM_API.GetGroupPaths, t)
        for _, p in ipairs(pick(ok, res, t)) do paths[#paths + 1] = p end
    else
        paths[1] = scope
    end

    for _, p in ipairs(paths) do
        local t = {}
        local ok, res = pcall(TSM_API.GetGroupItems, p, scope ~= "*", t)
        for k, v in pairs(pick(ok, res, t)) do
            -- wynik moze byc lista itemString albo tabela [itemString]=true
            if type(v) == "string" then add(v) elseif type(k) == "string" then add(k) end
        end
    end
    return list
end

local function scanOne(s)
    local db = ns.db
    local d = ns.FetchTSM(s)
    -- bez aktualnej ceny nadal sprawdzamy craft (nikt nie wystawia = czesto dobra okazja)
    if not d.minbuy and not d.crafting then return end
    local r = ns.Analyze(s, d, nil)  -- zakup po aktualnej min
    if r.verdict == "NODATA" and not r.craftPct then return end

    if db.scanRequireRate and not d.saleRate then return end
    if db.scanSkipHigh and r.risk.level == "HIGH" then return end
    if (r.sellRef or 0) < db.scanMinPrice then return end

    local best, mode, profit, exp
    if r.verdict == "BUY" then
        best, mode, profit, exp = r.expectedPct, "kup", r.targetProfit, r.expected
    end
    if r.craftPct and r.craftPct >= db.margin and r.craftExpectedPct and r.craftExpectedPct > 0
        and (not best or r.craftExpectedPct > best) then
        best, mode, profit = r.craftExpectedPct, "craft", r.craftProfit
        exp = r.craftExpectedPct / 100 * r.craftCost
    end
    if not best then return end

    -- zysk na dobe: oczekiwany zysk/szt. * realistyczne tempo (max 10 szt./dzien)
    local perDay = d.perDay and (d.perDay / (db.perDayDiv or 1)) or nil
    local score = (exp or 0) * math.min(perDay or 1, 10)

    local res = ns.scan.results
    res[#res + 1] = { s = s, pct = best, profit = profit, mode = mode, saleRate = d.saleRate,
        price = d.minbuy, risk = r.risk.level, score = score,
        craftProfit = r.craftProfit, craftPct = r.craftPct, craftExp = r.craftExpectedPct, craftCost = r.craftCost }
end

function ns.SortScan()
    local db = ns.db
    table.sort(ns.scan.results, function(a, b)
        if db.scanSortDay then
            if a.score ~= b.score then return a.score > b.score end
        else
            local sa, sb = math.min(a.pct, 300), math.min(b.pct, 300)
            if sa ~= sb then return sa > sb end
        end
        return (a.profit or 0) > (b.profit or 0)
    end)
end

function ns.StartScan(scope)
    local sc = ns.scan
    if sc.running then ns.Print("Skan juz trwa."); return end
    if not ns.HasTSM() then ns.Print("TSM nie wykryte."); return end

    local list, err = collectItems(scope)
    if not list then ns.Print(err); return end
    if #list == 0 then
        ns.Print("Brak przedmiotow do skanowania" .. ((scope or "") == "" and " (lista obserwowanych jest pusta)." or "."))
        return
    end
    while #list > MAX_SCAN do table.remove(list) end

    sc.running, sc.i, sc.total, sc.results, sc.scope, sc.list = true, 0, #list, {}, scope or "", list
    sc.offset = 0

    local function step()
        local n = 0
        while sc.i < sc.total and n < 40 do
            sc.i = sc.i + 1
            n = n + 1
            ns.Safe("scan", scanOne, sc.list[sc.i])
        end
        if sc.i < sc.total then
            C_Timer.After(0.02, step)
        else
            sc.running = false
            sc.list = nil
            ns.SortScan()
            ns.Print(string.format("Skan zakonczony: %d okazji z %d przedmiotow.", #sc.results, sc.total))
        end
        if ns.UpdatePanel then ns.UpdatePanel() end
    end
    step()
end

------------------------------------------------------------------
-- TOOLTIP
------------------------------------------------------------------
-- Cache analizy tooltipa: bez tego kazde najechanie = 11 zapytan TSM + pelna analiza
local tipCache, tipCount, tipGen = {}, 0, 0
local TIP_TTL = 30

function ns.InvalidateTips() tipGen = tipGen + 1 end   -- wolane z UpdateUI (po zmianie ustawien/danych)

local function tipAnalysis(itemString, buy)
    local now = GetTime()
    local c = tipCache[itemString]
    if c and c.gen == tipGen and c.buy == buy and now - c.t < TIP_TTL then return c.r end
    if not c then
        if tipCount >= 400 then tipCache, tipCount = {}, 0 end
        tipCount = tipCount + 1
    end
    local r = ns.Analyze(itemString, ns.FetchTSM(itemString), buy)
    tipCache[itemString] = { t = now, gen = tipGen, buy = buy, r = r }
    return r
end

local function AddTip(tooltip, itemString)
    local db = ns.db
    if not db or not db.tooltip or not itemString or not ns.HasTSM() then return end

    local buy = db.buyPrice[itemString]
    local r = tipAnalysis(itemString, buy)
    if r.verdict == "NODATA" then return end

    tooltip:AddLine(" ")
    if buy then
        tooltip:AddDoubleLine("|cff33aaffTSMA|r  koszt wlasny " .. ns.Money(buy), ns.VERDICT_SHORT[r.verdict])
    else
        tooltip:AddDoubleLine("|cff33aaffTSMA|r  gdybys kupil po akt. min", ns.VERDICT_SHORT[r.verdict])
    end
    tooltip:AddDoubleLine("Wystaw za:", ns.Money(r.suggest))
    tooltip:AddDoubleLine("Zysk netto:", ns.ProfitStr(r.suggestProfit, r.suggestPct))
    if r.maxBuy then
        tooltip:AddDoubleLine("Kupuj do:", ns.Money(r.maxBuy))
    end
    tooltip:AddDoubleLine("Ryzyko:", string.format("%s (%d)", ns.RISK_TEXT[r.risk.level], r.risk.score))
    if r.maxUnits then
        tooltip:AddDoubleLine("Max do kupienia:", r.maxUnits .. " szt.")
    end
    if r.craftProfit then
        tooltip:AddDoubleLine("Craft:", ns.ProfitStr(r.craftProfit, r.craftPct))
    end
    local lo, hi, n = ns.HistRange(itemString, 86400)
    if n and n >= 2 and lo and hi then
        tooltip:AddDoubleLine("24h min-max:", ns.Money(lo) .. " - " .. ns.Money(hi))
    end
    if r.own and r.ownLowest then
        tooltip:AddLine("|cffffa040Twoja aukcja jest najnizsza.|r")
    elseif r.own then
        tooltip:AddLine("|cffffa040Twoja aukcja jest podbita.|r")
    end
end

local function TipFromData(tt, data)
    if not data then return end
    if tt.IsForbidden and tt:IsForbidden() then return end
    local s
    if data.hyperlink then s = ns.ResolveItem(data.hyperlink) end
    if not s and data.id then s = "i:" .. data.id end
    if s then AddTip(tt, s) end
end

local function InitTooltip()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            ns.Safe("tooltip", TipFromData, tt, data)
        end)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", function(tt)
            ns.Safe("tooltip", function()
                local _, link = tt:GetItem()
                if link then
                    local s = ns.ResolveItem(link)
                    if s then AddTip(tt, s) end
                end
            end)
        end)
    end
end

------------------------------------------------------------------
-- AUTO-DZIENNIK: komunikaty AH (sprzedaz / wygasniecie) + hook wystawiania
-- + Twoje aktywne aukcje (GetOwnedAuctions) + faktury AH z poczty (realny przychod)
-- Cena i ilosc pochodza z zapisanego wystawienia (ns.Post), bo komunikat podaje tylko przedmiot.
------------------------------------------------------------------
local logPatterns = {}
local soldMailPat

-- format Blizzarda ("A buyer has been found for your auction of %s.") -> wzorzec Lua
local function FmtToPattern(fmt)
    local p = fmt:gsub("%%%d%$s", "\1"):gsub("%%s", "\1")
    p = p:gsub("([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
    p = p:gsub("\1", "(.+)")
    return "^" .. p .. "$"
end

local function BuildPatterns()
    logPatterns = {}
    local function add(kind, g)
        if type(g) == "string" then
            logPatterns[#logPatterns + 1] = { kind = kind, pat = FmtToPattern(g) }
        end
    end
    add("sold", _G.ERR_AUCTION_SOLD_S)
    add("expired", _G.ERR_AUCTION_EXPIRED_S)
    if type(_G.AUCTION_SOLD_MAIL_SUBJECT) == "string" then
        soldMailPat = FmtToPattern(_G.AUCTION_SOLD_MAIL_SUBJECT)
    end
end

local function itemID(s) return s and s:match("^i:(%d+)") end

-- klucz w openPosts odpowiadajacy itemString (dopuszcza rozne wersje itemString tego samego ID)
local function findOpenKey(s)
    local op = ns.db.openPosts
    if op[s] then return s end
    local id = itemID(s)
    if id then
        for k in pairs(op) do
            if itemID(k) == id then return k end
        end
    end
end

-- Cena Twojej najnizszej aktywnej aukcji tego przedmiotu (za szt.) albo nil.
-- Gdy w tej sesji odczytano Twoje aukcje z AH (< 2h temu), to ono rozstrzyga; inaczej szacujemy z openPosts.
function ns.OwnLowest(s)
    local id = itemID(s)
    if ns.owned and ns.ownedT and time() - ns.ownedT < 7200 then
        local o = id and ns.owned[tonumber(id)]
        return o and o.price or nil
    end
    local key = findOpenKey(s)
    local list = key and ns.db.openPosts[key]
    if not list then return nil end
    local m
    for _, p in ipairs(list) do
        if not m or p.price < m then m = p.price end
    end
    return m
end

local function itemFromCapture(cap)
    local s = ns.ResolveItem(cap)
    if s then return s end
    local name = cap:match("%[(.-)%]") or cap
    for k in pairs(ns.db.openPosts) do
        if ns.ItemName(k) == name then return k end
    end
end

local function findItemByName(name)
    local db = ns.db
    if db.selected and ns.ItemName(db.selected) == name then return db.selected end
    for _, s in ipairs(db.watch) do
        if ns.ItemName(s) == name then return s end
    end
    for s in pairs(db.lots) do
        if ns.ItemName(s) == name then return s end
    end
    for s in pairs(db.openPosts) do
        if ns.ItemName(s) == name then return s end
    end
    for i = #db.log, 1, -1 do
        if ns.ItemName(db.log[i].s) == name then return db.log[i].s end
    end
end

local function refreshViews()
    if ns.UpdateUI then ns.UpdateUI() end
    if ns.UpdatePanel then ns.UpdatePanel() end
end

local function OnSystemMessage(msg)
    local db = ns.db
    if not db or not db.autoLog or type(msg) ~= "string" then return end
    for _, p in ipairs(logPatterns) do
        local cap = msg:match(p.pat)
        if cap then
            local s = itemFromCapture(cap)
            if not s then return end
            local key = findOpenKey(s)
            local list = key and db.openPosts[key]
            local post = list and list[1]
            local what = (p.kind == "sold") and "sprzedaz" or "wygasniecie"
            if not post then
                ns.Print("Auto-dziennik: " .. what .. " " .. ns.ItemLink(s) .. " - brak zapisanego wystawienia, wpisz recznie.")
                return
            end
            table.remove(list, 1)
            if #list == 0 then db.openPosts[key] = nil end

            if p.kind == "sold" then
                local qty = post.qty
                local lot = db.lots[key]
                if lot and lot.qty and qty > lot.qty then qty = lot.qty end
                if qty <= 0 then return end
                local ok, res = ns.Sell(key, qty, post.price, true)
                if ok then
                    ns.Print(string.format("Auto-dziennik: sprzedano %dx %s po %s.%s", qty, ns.ItemLink(key),
                        ns.MoneyPlain(post.price), res and (" Zysk netto: " .. ns.Money(res)) or ""))
                else
                    ns.Print("Auto-dziennik: " .. res)
                end
            else
                local d = ns.cache[key] or ns.FetchTSM(key)
                local lost = ns.Expire(key, post.qty, ns.DepositPerUnit(d, key), true)
                ns.Print(string.format("Auto-dziennik: wygaslo %dx %s. Utracony depozyt: %s", post.qty,
                    ns.ItemLink(key), ns.Money(lost)))
            end
            refreshViews()
            return
        end
    end
end

-- Twoje aktywne aukcje z AH: podstawa wykrywania podbicia i czyszczenia anulowanych wystawien
local function OnOwned()
    local db = ns.db
    local AH = _G.C_AuctionHouse
    if not (db and AH and AH.GetOwnedAuctions) then return end
    if AH.HasFullOwnedAuctionResults and not AH.HasFullOwnedAuctionResults() then return end

    local activeEnum = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active) or 0
    local owned = {}
    for _, a in ipairs(AH.GetOwnedAuctions() or {}) do
        local id = a.itemKey and a.itemKey.itemID
        local price = a.buyoutAmount
        if (a.status == nil or a.status == activeEnum) and id and price and price > 0 then
            local o = owned[id]
            if not o then o = { price = price, qty = 0 }; owned[id] = o end
            o.qty = o.qty + (a.quantity or 1)
            if price < o.price then o.price = price end
        end
    end
    ns.owned, ns.ownedT = owned, time()

    -- wystawienia, ktorych nie ma juz na AH (anulowane albo sprzedane/wygasle bez komunikatu): usun z openPosts
    local now = time()
    for key, list in pairs(db.openPosts) do
        local id = tonumber(itemID(key))
        if id and not owned[id] then
            local keep = {}
            for _, p in ipairs(list) do
                if now - p.t < 300 then keep[#keep + 1] = p end   -- swiezo wystawione: AH moze jeszcze ich nie pokazywac
            end
            if #keep < #list then
                ns.Print(string.format("Auto-dziennik: %s nie ma juz na AH - usunieto %d otwartych wystawien (anulowane lub rozliczone bez komunikatu).",
                    ns.ItemLink(key), #list - #keep))
            end
            db.openPosts[key] = (#keep > 0) and keep or nil
        end
    end

    if ns.CheckAlerts then ns.Safe("alerts", ns.CheckAlerts, ns.RefreshList()) end
    refreshViews()
end

-- Faktury AH z poczty: realny przychod (kwota sprzedazy minus prowizja AH).
-- Przetwarzamy tylko NIEPRZECZYTANE maile "Auction successful" (to zapobiega dublowaniu).
local function ApplyMail(itemName, count, gross, cut)
    local db = ns.db
    local real = gross - (cut or 0)
    local entry
    for j = #db.log, 1, -1 do
        local e = db.log[j]
        if e.kind == "sell" and not e.real and ns.ItemName(e.s) == itemName then entry = e; break end
    end
    if entry then
        local per = real / ((count and count > 0) and count or entry.qty)
        entry.real = math.floor(per * entry.qty + 0.5)
        local avg = entry.avg or db.buyPrice[entry.s]
        if avg then entry.profit = math.floor(entry.real - entry.qty * avg + 0.5) end
        ns.Print(string.format("Poczta: %dx %s - realny przychod %s (wpis w dzienniku poprawiony).",
            entry.qty, itemName, ns.Money(entry.real)))
        return
    end

    -- brak wpisu w dzienniku (np. sprzedaz offline) - dopisz sprzedaz z faktury
    local s = findItemByName(itemName)
    if not s then
        ns.Print(string.format("Poczta: sprzedaz %s za %s - nie znam tego przedmiotu, wpisz recznie (/tsma sell).",
            itemName, ns.MoneyPlain(real)))
        return
    end
    count = (count and count > 0) and count or 1
    local ok, res = ns.Sell(s, count, math.floor(gross / count + 0.5))
    if not ok then ns.Print("Poczta: " .. tostring(res)); return end
    local e = db.log[#db.log]
    if e then
        e.real = real
        if e.avg then e.profit = math.floor(real - count * e.avg + 0.5) end
    end
    ns.Print(string.format("Poczta: dopisano sprzedaz %dx %s, realny przychod %s.", count, itemName, ns.Money(real)))
end

local function OnMail()
    local db = ns.db
    if not db or not db.mailLog or not soldMailPat then return end
    if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return end
    local changed = false
    for i = 1, GetInboxNumItems() do
        local _, _, _, subject, _, _, _, _, wasRead = GetInboxHeaderInfo(i)
        if subject and not wasRead and subject:match(soldMailPat) then
            local inv = { GetInboxInvoiceInfo(i) }
            if not inv[1] and GetInboxText then
                GetInboxText(i)   -- niektore klienty zwracaja fakture dopiero po odczytaniu tekstu maila
                inv = { GetInboxInvoiceInfo(i) }
            end
            -- invoiceType, itemName, playerName, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count
            local invType, itemName, bid, buyout, consignment, count = inv[1], inv[2], inv[4], inv[5], inv[7], inv[11]
            local gross = (bid and bid > 0) and bid or buyout
            if invType == "seller" and itemName and gross and gross > 0 then
                ApplyMail(itemName, count, gross, consignment)
                changed = true
            end
        end
    end
    if changed then refreshViews() end
end

-- ostrzezenia po wystawieniu (hook dziala PO wyslaniu aukcji - mozna ja jeszcze anulowac w AH)
local function WarnPost(s, unitPrice)
    local db = ns.db
    if not db.warnPost then return end
    local keep = 1 - ns.Cut() / 100
    local buy = db.buyPrice[s]
    if buy then
        local be = math.ceil(buy / keep)
        local ml = math.ceil(buy * (1 + db.margin / 100) / keep)
        if unitPrice < be then
            Notify(string.format("UWAGA: wystawiasz za %s - PONIZEJ break-even (%s)!", ns.MoneyPlain(unitPrice), ns.MoneyPlain(be)), s)
        elseif unitPrice < ml then
            Notify(string.format("Uwaga: cena %s jest ponizej progu min. zysku (%s).", ns.MoneyPlain(unitPrice), ns.MoneyPlain(ml)), s)
        end
    end
    local d = ns.cache[s] or ns.FetchTSM(s)
    if d.minbuy and unitPrice < d.minbuy * 0.5 then
        Notify(string.format("Uwaga: cena %s to %.0f%% aktualnej min (%s) - literowka?",
            ns.MoneyPlain(unitPrice), unitPrice / d.minbuy * 100, ns.MoneyPlain(d.minbuy)), s)
    end
end

-- wywolywane po C_AuctionHouse.PostCommodity / PostItem (unitPrice = cena za sztuke)
local function OnPost(loc, duration, qty, unitPrice, isCommodity)
    local db = ns.db
    if not db or not db.autoLog or not loc or not qty or qty <= 0 or not unitPrice or unitPrice <= 0 then return end
    local link = C_Item and C_Item.GetItemLink and C_Item.GetItemLink(loc)
    local s = link and ns.ResolveItem(link)
    if not s then return end
    ns.Post(s, qty, unitPrice)
    ns.Safe("warnpost", WarnPost, s, unitPrice)

    -- kalibracja depozytu: realna wartosc z AH
    local AH = C_AuctionHouse
    local dep
    if isCommodity and AH.CalculateCommodityDeposit then
        local id = tonumber(itemID(s))
        if id then
            local ok, v = pcall(AH.CalculateCommodityDeposit, id, duration, qty)
            if ok then dep = v end
        end
    elseif AH.CalculateItemDeposit then
        local ok, v = pcall(AH.CalculateItemDeposit, loc, duration, qty)
        if ok then dep = v end
    end
    if type(dep) == "number" and dep > 0 then
        local per = math.max(1, math.floor(dep / qty + 0.5))
        db.depositReal[s] = per
        local d = ns.cache[s] or ns.FetchTSM(s)
        if d.vendorSell and d.vendorSell >= 1000 then   -- tanie przedmioty sa zaburzone minimalnym depozytem
            local cal = db.depCal
            if cal.n >= 200 then cal.n, cal.sum = cal.n / 2, cal.sum / 2 end
            cal.n = cal.n + 1
            cal.sum = cal.sum + per / d.vendorSell
        end
    end
    refreshViews()
end

local function HookPosting()
    local AH = _G.C_AuctionHouse
    if not (AH and hooksecurefunc) then return end
    if type(AH.PostCommodity) == "function" then
        hooksecurefunc(AH, "PostCommodity", function(loc, duration, qty, unitPrice)
            ns.Safe("autopost", OnPost, loc, duration, qty, unitPrice, true)
        end)
        ns.postHooked = true
    end
    if type(AH.PostItem) == "function" then
        hooksecurefunc(AH, "PostItem", function(loc, duration, qty, bid, buyout)
            qty = qty or 1
            local total = buyout or bid
            ns.Safe("autopost", OnPost, loc, duration, qty, total and math.floor(total / qty) or nil, false)
        end)
        ns.postHooked = true
    end
end

-- wystawienia starsze niz 4 dni nie moga juz byc aktywne (max 48h) - sprzatamy
function ns.PruneOpenPosts()
    local now = time()
    for s, list in pairs(ns.db.openPosts) do
        local keep = {}
        for _, p in ipairs(list) do
            if now - p.t < 4 * 86400 then keep[#keep + 1] = p end
        end
        ns.db.openPosts[s] = (#keep > 0) and keep or nil
    end
end

local evf = CreateFrame("Frame")
evf:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_SYSTEM" then
        ns.Safe("autolog", OnSystemMessage, (...))
    elseif event == "MAIL_INBOX_UPDATE" then
        ns.Safe("mail", OnMail)
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        ns.Safe("owned", OnOwned)
    elseif event == "AUCTION_HOUSE_SHOW" then
        local AH = _G.C_AuctionHouse
        if AH and AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) end
    end
end)

function ns.InitFeatures()
    InitTooltip()
    ns.Safe("autolog", function()
        BuildPatterns()
        for _, e in ipairs({ "CHAT_MSG_SYSTEM", "MAIL_INBOX_UPDATE", "OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_SHOW" }) do
            pcall(evf.RegisterEvent, evf, e)   -- nieznane zdarzenie na danym kliencie nie moze przerwac ladowania
        end
        ns.PruneOpenPosts()
        HookPosting()
    end)
end

------------------------------------------------------------------
-- KOMENDY
------------------------------------------------------------------
local function needSelected()
    local s = ns.db.selected
    if not s then ns.Print("Najpierw wybierz przedmiot (/tsma add <item> albo pole w HUD).") end
    return s
end

local function parseQtyPrice(rest)
    local qty, price = rest:match("^(%d+)%s+(.+)$")
    qty = tonumber(qty)
    price = ns.ParseMoney(price)
    if not qty or qty <= 0 or not price then return nil end
    return qty, price
end

local function findField(key)
    key = (key or ""):lower()
    for _, f in ipairs(ns.FIELDS) do
        if f.key:lower() == key then return f end
    end
    return nil
end

local function FieldValueText(f)
    local v = ns.db[f.key]
    if f.kind == "money" then return ns.MoneyPlain(v) end
    return tostring(v)
end

local function PrintSettings()
    ns.Print("Ustawienia (zmiana: /tsma set <klucz> <wartosc>):")
    for _, f in ipairs(ns.FIELDS) do
        ns.Print(string.format("  %s = %s   (%s)", f.key, FieldValueText(f), f.label))
    end
    ns.Print("  dom aukcyjny: " .. ns.db.house .. " (prowizja " .. ns.Cut() .. "%)  -> /tsma house faction|neutral")
end

local function PrintDebug()
    local db = ns.db
    ns.Print("--- debug ---")
    ns.Print("TSM_API: " .. tostring(ns.HasTSM()))
    if type(TSM_API) == "table" then
        for _, fn in ipairs({ "GetCustomPriceValue", "ToItemString", "GetItemName", "GetItemLink",
            "GetGroupPaths", "GetGroupItems", "IsCustomPriceValid" }) do
            ns.Print("  TSM_API." .. fn .. ": " .. tostring(type(TSM_API[fn]) == "function"))
        end
    end
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if getMeta then ns.Print("TSM wersja: " .. tostring(getMeta("TradeSkillMaster", "Version"))) end
    ns.Print("Klient (interface): " .. tostring((select(4, GetBuildInfo()))))
    ns.Print("Tooltip hook: " .. tostring(TooltipDataProcessor ~= nil))
    ns.Print("ChatFrameUtil.InsertLink: " .. tostring(ChatFrameUtil and ChatFrameUtil.InsertLink ~= nil)
        .. ", HandleModifiedItemClick: " .. tostring(HandleModifiedItemClick ~= nil))
    local imp = _G.TsmAnalizeImport
    ns.Print("Import.lua: " .. ((type(imp) == "table" and imp.generated and imp.generated > 0)
        and date("%Y-%m-%d %H:%M", imp.generated) or "brak")
        .. (db.importOff ~= nil and "  (COFNIETY: /tsma import redo)" or ""))
    local trust, age = ns.EconomyTrust()
    ns.Print(string.format("Dom: %s (prowizja %s%%), wiek ekonomii: %s dni, waga DBMarket: %.0f%%",
        db.house, tostring(ns.Cut()), age and string.format("%.1f", age) or "n/d", trust * 100))
    ns.Print("Wzor ceny ref.: " .. ((db.refFormula and db.refFormula ~= "") and db.refFormula or "(auto: DBMarket)"))
    local s = db.selected
    if s then
        ns.Print("Surowe wartosci dla " .. s .. ":")
        for _, src in ipairs({ "DBMinBuyout", "DBMarket", "DBRecent", "DBHistorical", "DBRegionMarketAvg",
            "DBRegionSaleAvg", "DBRegionSaleRate", "DBRegionSoldPerDay", "Crafting", "avgBuy", "vendorSell" }) do
            local ok, v = ns.RawTSM(src, s)
            ns.Print(string.format("  %s = %s (%s)", src, tostring(v), ok and type(v) or "blad"))
        end
        local pts = db.items[s] and #db.items[s].hist or 0
        ns.Print("Punktow historii: " .. pts)
        local d = ns.cache[s] or ns.FetchTSM(s)
        local r = ns.Analyze(s, d, ns.EffectiveBuy(s, d))
        if r.risk then
            ns.Print(string.format("Ryzyko: %d (%s), p(sprzedazy) %.0f%% (%s), depozyt/szt. %s",
                r.risk.score, r.risk.level, r.risk.p * 100,
                r.risk.pOwn and ("wlasne, n=" .. r.risk.nOwn) or "szac.", ns.MoneyPlain(r.deposit)))
            for _, w in ipairs(r.risk.why) do ns.Print("  - " .. w) end
        end
        ns.Print(string.format("Kupuj do: %s, moja najnizsza aukcja: %s", ns.MoneyPlain(r.maxBuy), ns.MoneyPlain(r.own)))
    else
        ns.Print("Wybierz przedmiot, zeby zobaczyc surowe wartosci.")
    end
    local nOpen = 0
    for _, l in pairs(db.openPosts) do nOpen = nOpen + #l end
    ns.Print(string.format("Auto-dziennik: %s, otwarte wystawienia: %d, wzorce czatu: %d, hook wystawiania: %s",
        db.autoLog and "ON" or "OFF", nOpen, #logPatterns, tostring(ns.postHooked == true)))
    ns.Print(string.format("Moje aukcje z AH: %s, poczta (faktury): %s, wzorzec tematu maila: %s",
        ns.ownedT and ("odczytane " .. date("%H:%M", ns.ownedT)) or "jeszcze nie (otworz AH)",
        db.mailLog and "ON" or "OFF", tostring(soldMailPat ~= nil)))
    local cal = db.depCal
    if cal and cal.n > 0 then
        ns.Print(string.format("Kalibracja depozytu: %d probek, srednio %.1f%% ceny NPC (uzywana od 3 probek)",
            cal.n, cal.sum / cal.n * 100))
    end
    local nErr = 0
    for _ in pairs(ns.errors) do nErr = nErr + 1 end
    ns.Print("Bledy w sesji (tagi): " .. nErr .. (nErr > 0 and "  -> /tsma errors" or ""))
    ns.Print(ns.AccuracyLine())
end

SLASH_TSMA1 = "/tsma"
SlashCmdList["TSMA"] = function(msg)
    local db = ns.db
    if not db then return end
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" or cmd == "hide" or cmd == "toggle" then
        ns.Toggle()

    elseif cmd == "panel" then
        if ns.TogglePanel then ns.TogglePanel() end

    elseif cmd == "config" or cmd == "ustawienia" then
        if ns.ToggleConfig then ns.ToggleConfig() end

    elseif cmd == "settings" then
        PrintSettings()

    elseif cmd == "set" then
        local key, val = rest:match("^(%S+)%s+(.+)$")
        local f = findField(key)
        if not f then ns.Print("Uzycie: /tsma set <klucz> <wartosc>. Lista kluczy: /tsma settings"); return end
        local ok, err = ns.SetField(f, val)
        if ok then
            ns.Print(f.key .. " = " .. FieldValueText(f))
            ns.UpdateUI()
            if ns.UpdatePanel then ns.UpdatePanel() end
        else
            ns.Print(err)
        end

    elseif cmd == "ref" then
        local f = findField("refFormula")
        local v = rest
        if v:lower() == "off" then v = "" end
        if rest == "" then
            ns.Print("Wzor ceny ref.: " .. ((db.refFormula ~= "") and db.refFormula or "(auto: DBMarket)")
                .. "   Uzycie: /tsma ref min(DBMarket, DBRegionMarketAvg)  albo  /tsma ref off")
        else
            local ok, err = ns.SetField(f, v)
            if ok then
                ns.Print("Wzor ceny ref.: " .. ((db.refFormula ~= "") and db.refFormula or "(auto: DBMarket)"))
                ns.UpdateUI()
                if ns.UpdatePanel then ns.UpdatePanel() end
            else
                ns.Print(err)
            end
        end

    elseif cmd == "house" then
        local v = rest:lower()
        if v == "neutral" or v == "faction" then
            db.house = v
            ns.Print("Dom aukcyjny: " .. v .. " (prowizja " .. ns.Cut() .. "%)")
            ns.UpdateUI()
        else
            ns.Print("Uzycie: /tsma house faction|neutral   (aktualnie " .. db.house .. ", prowizja " .. ns.Cut() .. "%)")
        end

    elseif cmd == "start" then
        if rest:lower() == "off" then
            db.economyStart = 0
            ns.Print("Tryb mlodego rynku: brak daty startu (wylaczone odliczanie).")
        else
            local y, m, d = rest:match("^(%d+)%-(%d+)%-(%d+)$")
            if y then
                db.economyStart = ns.UTCTime(tonumber(y), tonumber(m), tonumber(d))
                ns.Print("Start ekonomii: " .. rest)
            else
                ns.Print("Uzycie: /tsma start 2026-11-04  albo  /tsma start off")
                return
            end
        end
        ns.UpdateUI()

    elseif cmd == "add" then
        local s = ns.ResolveItem(rest)
        if not s then ns.Print("Nie rozpoznano przedmiotu. Uzyj linku, ID albo i:ID."); return end
        if not ns.IsWatched(s) then table.insert(db.watch, s) end
        ns.Select(s)
        ns.Print("Dodano do obserwowanych: " .. ns.ItemName(s))

    elseif cmd == "remove" then
        local s = ns.ResolveItem(rest) or db.selected
        local i = s and ns.IsWatched(s)
        if i then
            table.remove(db.watch, i)
            ns.Print("Usunieto: " .. ns.ItemName(s))
            if ns.UpdateUI then ns.UpdateUI() end
        else
            ns.Print("Tego przedmiotu nie ma na liscie.")
        end

    elseif cmd == "watch" or cmd == "lista" then
        if #db.watch == 0 then ns.Print("Lista obserwowanych jest pusta.") end
        for i, s in ipairs(db.watch) do
            ns.Print(i .. ". " .. ns.ItemName(s) .. " (" .. s .. ")")
        end

    elseif cmd == "refresh" then
        local n = tonumber(rest)
        if n then
            db.refreshMin = math.max(1, math.floor(n))
            ns.StartTicker()
            ns.Print("Odswiezanie co " .. db.refreshMin .. " min.")
        end
        ns.Safe("refresh", ns.RefreshAll)

    elseif cmd == "cut" then
        local n = tonumber(rest)
        if n and n >= 0 and n < 100 then
            db.cut = n
            ns.Print("Prowizja frakcyjna: " .. n .. "%")
            ns.UpdateUI()
        else
            ns.Print("Uzycie: /tsma cut 5   (frakcyjna: " .. db.cut .. "%, neutralna: /tsma set cutNeutral 15)")
        end

    elseif cmd == "margin" then
        local n = tonumber(rest)
        if n and n >= 0 then
            db.margin = n
            ns.Print("Minimalny zysk: " .. n .. "%")
            ns.UpdateUI()
        else
            ns.Print("Uzycie: /tsma margin 10   (aktualnie " .. db.margin .. "%)")
        end

    elseif cmd == "undercut" then
        local n = ns.ParseMoney(rest)
        if n then
            db.undercut = n
            ns.Print("Undercut: " .. ns.Money(n))
            ns.UpdateUI()
        else
            ns.Print("Uzycie: /tsma undercut 1c   (aktualnie " .. ns.Money(db.undercut) .. ")")
        end

    elseif cmd == "perday" then
        local n = tonumber(rest)
        if n and n > 0 then
            db.perDayDiv = n
            ns.Print("DBRegionSoldPerDay dzielone przez " .. n)
            ns.UpdateUI()
        else
            ns.Print("Uzycie: /tsma perday 100   (aktualnie " .. db.perDayDiv .. ")")
        end

    elseif cmd == "tooltip" then
        db.tooltip = (rest:lower() ~= "off")
        ns.Print("Tooltip: " .. (db.tooltip and "wlaczony" or "wylaczony"))

    elseif cmd == "alert" then
        local s = needSelected()
        if not s then return end
        if rest:lower() == "off" or rest == "" then
            db.alerts[s] = nil
            ns.Print("Alert wylaczony dla " .. ns.ItemName(s))
        else
            local v = ns.ParseMoney(rest)
            if not v then ns.Print("Uzycie: /tsma alert 5g 20s  albo  /tsma alert off"); return end
            db.alerts[s] = v
            ns.alertState[s] = nil
            ns.Print("Alert dla " .. ns.ItemName(s) .. ": cena <= " .. ns.Money(v))
        end
        if ns.onSelect then ns.onSelect(s) end
        ns.UpdateUI()

    elseif cmd == "buy" or cmd == "sell" or cmd == "post" or cmd == "expired" then
        local s = needSelected()
        if not s then return end
        if cmd == "expired" then
            -- /tsma expired <ilosc> [depozyt za szt.]
            local qty = tonumber(rest:match("^(%d+)"))
            local dep = ns.ParseMoney(rest:match("^%d+%s+(.+)$") or "")
            if not qty or qty <= 0 then ns.Print("Uzycie: /tsma expired <ilosc> [depozyt za szt., np. 1s]"); return end
            if not dep then
                local d = ns.cache[s] or ns.FetchTSM(s)
                dep = ns.DepositPerUnit(d, s)
            end
            local lost = ns.Expire(s, qty, dep)
            ns.Print(string.format("Wygaslo %dx %s. Utracony depozyt: %s", qty, ns.ItemName(s), ns.Money(lost)))
        else
            local qty, price = parseQtyPrice(rest)
            if not qty then ns.Print("Uzycie: /tsma " .. cmd .. " <ilosc> <cena za szt., np. 5g 20s>"); return end
            if cmd == "buy" then
                ns.Buy(s, qty, price)
                ns.Print(string.format("Kupiono %dx %s po %s. Sr. koszt: %s", qty, ns.ItemName(s),
                    ns.MoneyPlain(price), ns.MoneyPlain(db.buyPrice[s])))
            elseif cmd == "sell" then
                local ok, p = ns.Sell(s, qty, price)
                if not ok then ns.Print(p); return end
                ns.Print(string.format("Sprzedano %dx %s po %s.%s", qty, ns.ItemName(s), ns.MoneyPlain(price),
                    p and (" Zysk netto: " .. ns.Money(p)) or " (brak ceny zakupu - zysk nieznany)"))
            else
                ns.Post(s, qty, price)
                ns.Print(string.format("Wystawiono %dx %s po %s.", qty, ns.ItemName(s), ns.MoneyPlain(price)))
            end
        end
        if ns.onSelect then ns.onSelect(s) end
        ns.UpdateUI()
        if ns.UpdatePanel then ns.UpdatePanel() end

    elseif cmd == "log" or cmd == "report" then
        local profit, spent, sells, lost = ns.LedgerSummary()
        ns.Print(string.format("Dziennik: %d wpisow, %d sprzedazy, wydano %s, utracone depozyty %s, zysk netto %s",
            #db.log, sells, ns.Money(spent), ns.Money(lost), ns.Money(profit)))
        for i = math.max(1, #db.log - 9), #db.log do
            local e = db.log[i]
            ns.Print(string.format("%s %s %dx %s @ %s%s%s", date("%d.%m %H:%M", e.t), e.kind, e.qty,
                ns.ItemName(e.s), ns.MoneyPlain(e.price), e.profit and (" -> " .. ns.MoneyPlain(e.profit)) or "",
                e.c and (" [" .. e.c .. "]") or ""))
        end

    elseif cmd == "export" then
        local what = rest:lower()
        if what == "hist" then
            local s = needSelected()
            if not s then return end
            if ns.ShowExport then ns.ShowExport("Historia cen (CSV): " .. ns.ItemName(s), ns.ExportHist(s)) end
        else
            if ns.ShowExport then ns.ShowExport("Dziennik (CSV)", ns.ExportLog()) end
        end

    elseif cmd == "import" then
        local v = rest:lower()
        if v == "undo" then
            local n = ns.UndoImport()
            ns.Print("Cofnieto import: usunieto " .. n .. " zaimportowanych punktow. Ponowny import: /tsma import redo")
            ns.UpdateUI()
        elseif v == "redo" then
            local n = ns.RedoImport()
            ns.Print("Import ponowiony: dodano " .. n .. " punktow (duplikaty pomijane).")
            ns.UpdateUI()
        else
            ns.Print("Uzycie: /tsma import undo | redo   (cofa/ponawia import z Import.lua; punkty zaimportowane przed ta wersja nie sa oznaczone)")
        end

    elseif cmd == "minimap" then
        local v = rest:lower()
        if v == "on" or v == "off" then
            db.minimapShow = (v == "on")
        else
            db.minimapShow = not db.minimapShow
        end
        if ns.ApplyMinimap then ns.ApplyMinimap() end
        ns.Print("Przycisk przy minimapie: " .. (db.minimapShow and "wlaczony" or "wylaczony"))

    elseif cmd == "mail" then
        local v = rest:lower()
        if v == "on" or v == "off" then db.mailLog = (v == "on") end
        ns.Print("Realny przychod z poczty: " .. (db.mailLog and "wlaczony" or "wylaczony") .. "  (/tsma mail on|off)")

    elseif cmd == "accuracy" or cmd == "trafnosc" then
        ns.Print(ns.AccuracyLine())
        for v, a in pairs(ns.AccuracyStats()) do
            ns.Print(string.format("  %s: n=%d, bez straty %.0f%%, z zyskiem %.0f%%, sr. zmiana %+.1f%%",
                v, a.n, a.ok / a.n * 100, a.okMargin / a.n * 100, a.chg / a.n))
        end

    elseif cmd == "chart" or cmd == "wykres" then
        if ns.ToggleBigChart then ns.ToggleBigChart() end

    elseif cmd == "errors" then
        if rest:lower() == "clear" then
            ns.errors = {}
            ns.Print("Wyczyszczono liste bledow.")
        else
            local any = false
            for tag, e in pairs(ns.errors) do
                any = true
                ns.Print(string.format("%s: %dx, ostatnio %s - %s", tag, e.n, date("%H:%M:%S", e.t), e.msg))
            end
            if not any then ns.Print("Brak bledow w tej sesji.") end
        end

    elseif cmd == "open" then
        local n = 0
        for s, list in pairs(db.openPosts) do
            for _, p in ipairs(list) do
                n = n + 1
                ns.Print(string.format("%s %dx %s @ %s", date("%d.%m %H:%M", p.t), p.qty, ns.ItemName(s), ns.MoneyPlain(p.price)))
            end
        end
        if n == 0 then ns.Print("Brak otwartych wystawien (czekajacych na sprzedaz/wygasniecie).") end

    elseif cmd == "autolog" then
        local v = rest:lower()
        if v == "on" or v == "off" then db.autoLog = (v == "on") end
        ns.Print("Auto-dziennik: " .. (db.autoLog and "wlaczony" or "wylaczony") .. "  (/tsma autolog on|off)")

    elseif cmd == "sort" then
        local v = rest:lower()
        if v == "day" or v == "pct" then db.scanSortDay = (v == "day") end
        ns.Print("Sortowanie skanera: " .. (db.scanSortDay and "zysk na dobe" or "% zysku") .. "  (/tsma sort day|pct)")
        ns.SortScan()
        if ns.UpdatePanel then ns.UpdatePanel() end

    elseif cmd == "scan" then
        ns.StartScan(rest)
        if ns.ShowPanel then ns.ShowPanel("scan") end

    elseif cmd == "craft" then
        if ns.ShowPanel then ns.ShowPanel("craft") end

    elseif cmd == "debug" then
        PrintDebug()

    else
        ns.Print("Komendy: /tsma | panel | config | settings | set <klucz> <wart> | ref <wzor|off> | house faction|neutral | start <data|off>")
        ns.Print("  add <item> | remove [item] | watch | refresh [min] | cut/margin/undercut | alert <cena|off>")
        ns.Print("  buy/sell/post <ilosc> <cena> | expired <ilosc> [depozyt] | log | accuracy | scan [grupa|*] | craft | sort day|pct")
        ns.Print("  chart | open | autolog on|off | mail on|off | minimap on|off | export [hist] | import undo|redo")
        ns.Print("  errors [clear] | tooltip on/off | debug")
    end
end
