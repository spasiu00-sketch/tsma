"""Smoke/logic testy nowych modulow addonu (Pipeline, Forecast, Ladder, Online, Weekly, Tracker, Todo) na atrapie API.
Uzycie: pip install lupa pytest ; pytest tests/test_new_modules.py   (katalog addonu: ../TsmAnalize albo zmienna TSMA_ADDON)"""
import os
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.environ.get("TSMA_ADDON", os.path.join(HERE, "..", "TsmAnalize"))

PRELUDE = r'''
NOW = 1800000000
time = function() return NOW end
date = os.date
math.randomseed(7)
debugprofilestop = function() return os.clock() * 1000 end
SlashCmdList = {}
SOUNDKIT = { RAID_WARNING = 1 }
function PlaySound() end
GetItemInfoInstant = function(id) return id, "Trade Goods", "Herb" end
local frames, timers = {}, {}
function CreateFrame()
  local f = { ev = {} }
  function f:RegisterEvent(e) self.ev[e] = true end
  function f:UnregisterEvent(e) self.ev[e] = nil end
  function f:SetScript(n, fn) self[n] = fn end
  frames[#frames + 1] = f
  return f
end
function fire(event, ...)
  for _, f in ipairs(frames) do if f.ev[event] and f.OnEvent then f:OnEvent(event, ...) end end
end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
function runTimers() local n = 0 while #timers > 0 and n < 5000 do table.remove(timers, 1)() n = n + 1 end end
function hooksecurefunc(t, n, f) local o = t[n]; t[n] = function(...) local r = o(...); f(...); return r end end
printed = {}
ns = { TOGGLES = {}, FIELDS = {}, DEFAULTS = {}, cache = {}, errors = {} }
ns.db = { items = {}, watch = {}, log = {}, undercut = 1, margin = 10, perDayDiv = 1, alertSound = false, fcOn = true,
          capital = 0, lots = {}, openPosts = {}, buyPrice = {} }
function ns.Safe(tag, fn, ...) local ok, e = pcall(fn, ...) if not ok then ns.errors[tag] = tostring(e) end return ok end
function ns.Print(m) printed[#printed + 1] = tostring(m) end
ns.Cut = function() return 5 end
ns.DepositPerUnit = function() return 10 end
ns.ItemName = function(s) return s end
ns.ItemLink = function(s) return s end
ns.ItemIcon = function() return 1 end
ns.MoneyPlain = function(c) return tostring(math.floor(c or 0)) end
ns.HasTSM = function() return true end
ns.RawTSM = function(src, s) return true, nil end
ns.FetchTSM = function(s) return { minbuy = 100 } end
ns.RefreshList = function() local l = {} for _, s in ipairs(ns.db.watch) do l[#l + 1] = s end return l end
ns.RefreshAll = function() end
ns.AccuracyLine = function() return "acc" end
ns.Analyze = function(s, d, buy)
  return { verdict = "BUY", notes = {}, buy = buy or d.minbuy, buyIsOwn = buy ~= nil, risk = { p = 0.8 }, profit = { net = 100, days = 2 }, suggest = 150 }
end
local function load(name)
  local f = assert(loadfile(ADDON .. "/" .. name .. ".lua"))
  f("TsmAnalize", ns)
end
for _, n in ipairs({ "Pipeline", "Forecast", "Online", "Weekly", "Ladder", "Tracker", "Todo" }) do load(n) end
fire("ADDON_LOADED", "TsmAnalize")
'''


def run(body):
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.globals().ADDON = ADDON.replace("\\", "/")
    L.execute(PRELUDE)
    L.execute(body)
    return L


def test_pipeline_order_and_stages():
    L = run(r'''
      _G.TsmAnalizeForecast = { generated = NOW, skill = { [24] = 0.05 }, items = { ["i:1"] = { f24 = { -9, -5, 2 } } } }
      _G.TsmAnalizeBlizz = { generated = NOW, items = { ["i:1"] = { lad = "1000:5,1200:10,1500:50" } } }
      ns.db.ladderQty = 20
      local d = { minbuy = 1000 }
      r = ns.Analyze("i:1", d, nil)
      stages = table.concat(ns.StageList(), ",")
    ''')
    g = L.globals()
    assert g.stages == "10 forecast,20 ladder"
    assert g.r.verdict == "MARGINAL"          # prognoza spadku obniza KUP
    assert g.r.buyIsOwn is False and g.r.ladder.pct > 5
    assert not dict(g.ns.errors)


def test_tracker_flow_flip_and_size():
    L = run(r'''
      ROWS = {}
      C_AuctionHouse = {
        GetNumCommoditySearchResults = function() return #ROWS end,
        GetCommoditySearchResultInfo = function(id, i) return ROWS[i] end,
      }
      local function scan(rows) ROWS = rows; fire("COMMODITY_SEARCH_RESULTS_UPDATED", 5) end
      scan({ { auctionID = 1, unitPrice = 100, quantity = 10 }, { auctionID = 2, unitPrice = 110, quantity = 20 },
             { auctionID = 3, unitPrice = 400, quantity = 5 } })
      NOW = NOW + 9000
      scan({ { auctionID = 2, unitPrice = 110, quantity = 12 }, { auctionID = 3, unitPrice = 400, quantity = 5 } })
      fl, cov = ns.OwnFlow("i:5")
      d = ns.FetchTSM("i:5")
      -- flip: 3@100, 5@110, sciana 200 x 50
      NOW = NOW + 600
      scan({ { auctionID = 10, unitPrice = 100, quantity = 3 }, { auctionID = 11, unitPrice = 110, quantity = 5 },
             { auctionID = 12, unitPrice = 200, quantity = 50 } })
      flip = ns.Flips()[1]
      snap = #ns.db.mt[5].h
      todo = ns.Todo()
      ns.db.maxSV = 1000
      steps, total = ns.TrimDB()
      SlashCmdList.TSMA("data"); SlashCmdList.TSMA("flip"); SlashCmdList.TSMA("size"); SlashCmdList.TSMA("flow")
    ''')
    g = L.globals()
    assert abs(g.fl - (10 + 8) / 9000 * 86400) < 1e-6        # 10 szt. zeszlo calkiem + 8 czesciowo
    assert g.cov == 2.5
    assert abs(g.d.perDay - g.fl) < 1e-9 and g.d.perDaySrc == "addon"
    assert g.flip.units == 8 and g.flip.sell == 199 and g.flip.profit > 600
    assert g.snap >= 2
    assert any(t.kind == "FLIP" for _, t in g.todo.items())
    assert not dict(g.ns.errors), dict(g.ns.errors)


def test_online_learns_mean_reversion():
    L = run(r'''
      local function gauss() return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random()) end
      local N = 12 * 48
      local mk = {}
      local m = 0
      for t = 1, N do m = 0.99 * m + 0.004 * gauss(); mk[t] = m end
      for it = 1, 24 do
        local s = "i:" .. (1000 + it)
        local x, h = 0, {}
        for t = 1, N do
          x = 0.97 * x + 0.012 * gauss()
          local lp = math.log(20000 + it * 500) + x + mk[t]
          local v = math.floor(math.exp(lp))
          h[#h + 1] = { NOW - (N - t) * 1800, v, math.floor(v * 1.05) }
        end
        ns.db.items[s] = { hist = h }
        ns.db.watch[#ns.db.watch + 1] = s
      end
      ns.OnlineTrain(nil, true)
      ok, skill, lo, hi, ne = ns.OnlineStats()
      fc = ns.OnlineFc("i:1001")
      f2 = ns.FcFor("i:1001")
      SlashCmdList.TSMA("online")
    ''')
    g = L.globals()
    assert g.skill is not None and g.skill > 0.0, (g.skill, g.lo, g.hi, g.ne)
    assert not dict(g.ns.errors), dict(g.ns.errors)
    if g.ok:
        assert g.fc is not None and g.f2.f24[1] <= g.f2.f24[2] <= g.f2.f24[3]


def test_weekly_runs_with_online_chain():
    L = run(r'''
      ns.db.log = { { t = NOW, kind = "sell", s = "i:1", qty = 2, profit = 3000 } }
      SlashCmdList.TSMA("weekly")
      SlashCmdList.TSMA("stages")
    ''')
    assert not dict(L.globals().ns.errors)
