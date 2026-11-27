local ADDON, ns = ...

------------------------------------------------------------------
-- REALNY KOSZT ZAKUPU Z DRABINY OFERT (BlizzData: pole lad = "cena:ilosc,...", rosnaco)
-- Analyze liczylo zakup po aktualnej minimum. Kupno N sztuk to przejscie po drabinie, wiec srednia jest wyzsza.
-- Gdy cena zakupu nie jest wpisana, liczymy werdykt dla sredniej ceny N sztuk (db.ladderQty), skalowanej do min z TSM.
-- Etap potoku (Pipeline.lua, priorytet 20). Wczytaj PO Pipeline.lua.
------------------------------------------------------------------

local DEFAULTS = { ladderOn = true, ladderQty = 20 }
ns.DEFAULTS = ns.DEFAULTS or {}
for k, v in pairs(DEFAULTS) do ns.DEFAULTS[k] = v end

local parsed = setmetatable({}, { __mode = "v" })
local function Parse(str)
    local p = parsed[str]
    if p then return p end
    p = {}
    for pr, q in str:gmatch("(%d+):(%d+)") do p[#p + 1] = { tonumber(pr), tonumber(q) } end
    parsed[str] = p
    return p
end

-- -> koszt, srednia, kupione  (nil gdy brak drabiny / dane starsze niz 3 h)
function ns.LadderCost(s, n)
    local bz = _G.TsmAnalizeBlizz
    if type(bz) ~= "table" or not bz.generated or time() - bz.generated > 3 * 3600 then return nil end
    local e = bz.items and bz.items[s]
    if not (e and e.lad) then return nil end
    local cost, got = 0, 0
    for _, lv in ipairs(Parse(e.lad)) do
        local take = math.min(lv[2], n - got)
        cost, got = cost + take * lv[1], got + take
        if got >= n then break end
    end
    if got < 2 then return nil end
    return cost, cost / got, got, Parse(e.lad)[1][1]
end

ns.AddStage("ladder", 20, function(nextFn, s, d, buy)
    local db = ns.db
    local lad
    if db and db.ladderOn and buy == nil and d and d.minbuy then
        local cost, avg, got, first = ns.LadderCost(s, db.ladderQty or 20)
        if avg and first and first > 0 and avg > first * 1.005 then
            lad = { n = got, pct = (avg / first - 1) * 100 }
            buy = math.floor(d.minbuy * (avg / first) + 0.5)
        end
    end
    local r = nextFn(s, d, buy)
    if lad and r.verdict ~= "NODATA" then
        r.buyIsOwn = false
        r.ladder = lad
        table.insert(r.notes, 1, string.format("Zakup %d szt. z drabiny: srednio %+.1f%% nad min - zysk liczony od tej ceny.",
            lad.n, lad.pct))
    end
    return r
end)

table.insert(ns.TOGGLES, { key = "ladderOn", label = "Zakup liczony ze sredniej ceny z drabiny ofert (Blizzard)" })
table.insert(ns.FIELDS, { key = "ladderQty", label = "Drabina: ile sztuk kupujesz naraz", kind = "num", min = 2, max = 1000, int = true })

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, arg1)
    if arg1 ~= ADDON or not ns.db then return end
    self:UnregisterEvent("ADDON_LOADED")
    for k, v in pairs(DEFAULTS) do
        if ns.db[k] == nil then ns.db[k] = v end
    end
end)
