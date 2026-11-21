-- Smoke-test harness: stubbed WoW API, loads the addon in .toc order and exercises the main paths
local DIR = ...
local out = {}
local function log(s) out[#out+1] = tostring(s) end

local registry = {}
local Methods = {}
local function newFrame(ftype, name, parent, template)
  local f = { _type = ftype, _name = name, _scripts = {}, _events = {}, _text = "", _shown = true, _w = 100, _h = 100, _checked = false }
  setmetatable(f, { __index = function(t, k)
    local m = Methods[k]
    if m then return m end
    if type(k) == "string" and k:match("^%u") then return function(self, ...) return self end end
    return nil
  end })
  registry[#registry+1] = f
  if template == "InputScrollFrameTemplate" then f.EditBox = newFrame("EditBox"); f.CharCount = newFrame("FontString") end
  if name then _G[name] = f end
  return f
end
Methods.SetText = function(self, t) self._text = tostring(t == nil and "" or t) end
Methods.GetText = function(self) return self._text end
Methods.SetShown = function(self, s) self._shown = s and true or false end
Methods.Show = function(self) self._shown = true end
Methods.Hide = function(self) self._shown = false end
Methods.IsShown = function(self) return self._shown end
Methods.IsVisible = function(self) return self._shown end
Methods.SetSize = function(self, w, h) self._w = w or self._w; self._h = h or self._h end
Methods.SetWidth = function(self, w) self._w = w end
Methods.SetHeight = function(self, h) self._h = h end
Methods.GetWidth = function(self) return self._w end
Methods.GetHeight = function(self) return self._h end
Methods.GetEffectiveScale = function() return 1 end
Methods.GetLeft = function() return 0 end
Methods.GetCenter = function() return 0, 0 end
Methods.GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end
Methods.IsMouseOver = function() return false end
Methods.HasFocus = function() return false end
Methods.GetChecked = function(self) return self._checked end
Methods.SetChecked = function(self, v) self._checked = v and true or false end
Methods.SetScript = function(self, n, fn) self._scripts[n] = fn end
Methods.GetScript = function(self, n) return self._scripts[n] end
Methods.HookScript = function(self, n, fn) self._scripts[n] = fn end
Methods.RegisterEvent = function(self, e) self._events[e] = true end
Methods.UnregisterEvent = function(self, e) self._events[e] = nil end
Methods.CreateTexture = function(self) return newFrame("Texture") end
Methods.CreateFontString = function(self) return newFrame("FontString") end
Methods.CreateLine = function(self) return newFrame("Line") end
Methods.GetStringWidth = function() return 50 end
Methods.SetCursorPosition = function() end
Methods.GetNumPoints = function() return 1 end

time = os.time
date = os.date
function CreateFrame(ftype, name, parent, template) return newFrame(ftype, name, parent, template) end
UIParent = newFrame("Frame", "UIParent")
Minimap = newFrame("Frame", "Minimap")
GameTooltip = newFrame("Frame", "GameTooltip")
UIErrorsFrame = newFrame("Frame", "UIErrorsFrame")
UISpecialFrames = {}
SlashCmdList = {}
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
SOUNDKIT = { RAID_WARNING = 8959 }
Enum = {}
tinsert = table.insert
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function CopyTable(t) local r = {}; for k, v in pairs(t) do r[k] = type(v) == "table" and CopyTable(v) or v end; return r end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
function UnitName() return "Tester" end
function GetCursorPosition() return 0, 0 end
function IsShiftKeyDown() return false end
function PlaySound() end
function GetBuildInfo() return "1.60.1", "1", "Jan 1 2026", 16001 end
function debugprofilestop() return os.clock() * 1000 end
local t0 = os.clock()
function GetTime() return os.clock() - t0 + 1000 end
function ChatEdit_InsertLink() end
function HandleModifiedItemClick() end
function hooksecurefunc(a, b, c)
  local tbl, name, fn
  if type(a) == "table" then tbl, name, fn = a, b, c else tbl, name, fn = _G, a, b end
  local orig = tbl[name]
  tbl[name] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
end
local timers = {}
C_Timer = {
  After = function(d, fn) timers[#timers+1] = fn end,
  NewTicker = function(d, fn) local t = { Cancel = function() end, fn = fn }; return t end,
}
C_Item = {
  GetItemInfoInstant = function(x)
    local id = type(x) == "number" and x or tonumber(tostring(x):match("%d+"))
    if not id then return nil end
    return id, "Trade Goods", "Herb"
  end,
  GetItemNameByID = function(id) return "Item" .. id end,
  GetItemIconByID = function() return 134400 end,
}
ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s."
ERR_AUCTION_EXPIRED_S = "Your auction of %s has expired."
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"

-- TSM stub: items with id divisible by 7 have data
local function base(id) return 20000 + id * 130 end
TSM_API = {
  GetCustomPriceValue = function(src, s)
    local id = tonumber(tostring(s):match("^i:(%d+)"))
    if not id or id % 7 ~= 0 then return nil end
    local b = base(id)
    if src == "DBMinBuyout" then return b end
    if src == "DBMarket" then return b * 1.05 end
    if src == "DBRecent" then return b * 1.02 end
    if src == "DBHistorical" then return b * 1.04 end
    if src == "DBRegionMarketAvg" then return b * 1.1 end
    if src == "DBRegionSaleAvg" then return b * 1.08 end
    if src == "DBRegionSaleRate" then return 0.05 end
    if src == "DBRegionSoldPerDay" then return 20 end
    if src == "Crafting" then return (id % 14 == 0) and b * 0.6 or nil end
    if src == "vendorSell" then return b * 0.1 end
    if src:find("%(") then return b end
    return nil
  end,
  IsCustomPriceValid = function(s) return true end,
  ToItemString = function(link) local id = tostring(link):match("item:(%d+)"); return id and ("i:" .. id) end,
  GetItemName = function(s) return "Item" .. tostring(s):match("%d+") end,
  GetItemLink = function(s) return "[Item" .. tostring(s):match("%d+") .. "]" end,
  GetGroupPaths = function(t) t[1] = "Herbs"; t[2] = "Herbs`Classic"; return t end,
  GetGroupItems = function(p, sub, t) t[1] = "i:7"; t[2] = "i:14"; t[3] = "i:21"; return 3 end,
}

-- print capture
local printed = {}
function print(...) local a = {}; for i = 1, select("#", ...) do a[#a+1] = tostring((select(i, ...))) end; printed[#printed+1] = table.concat(a, " ") end

local function fire(event, ...)
  for _, f in ipairs(registry) do
    if f._events[event] and f._scripts.OnEvent then
      local args, nargs = { ... }, select("#", ...)
      local ok, err = xpcall(function() f._scripts.OnEvent(f, event, unpack(args, 1, nargs)) end, debug.traceback)
      if not ok then log("EVENT ERROR " .. event .. ": " .. tostring(err)) end
    end
  end
end
local function runTimers(limit)
  local n = 0
  while #timers > 0 and n < (limit or 20000) do
    local fn = table.remove(timers, 1)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then log("TIMER ERROR: " .. tostring(err)) end
    n = n + 1
  end
  return n
end
local function try(label, fn, ...)
  local args = { ... }
  local nargs = select("#", ...)
  local ok, err = xpcall(function() return fn(unpack(args, 1, nargs)) end, debug.traceback)
  if not ok then log("FAIL " .. label .. ": " .. tostring(err)) else log("ok   " .. label) end
  return ok
end

local ns = {}
local FILES = { "Core", "Features", "UI", "Panels", "Learn", "Risk", "Watch", "Archive", "Dock", "Import" }
for _, name in ipairs(FILES) do
  local f = io.open(DIR .. "/" .. name .. ".lua", "r")
  local src = f:read("*a"); f:close()
  local chunk, err = loadstring(src, "@" .. name .. ".lua")
  if not chunk then log("LOAD ERROR " .. name .. ": " .. tostring(err)) else
    try("load " .. name, chunk, "TsmAnalize", ns)
  end
end

fire("ADDON_LOADED", "TsmAnalize")
log("db? " .. tostring(ns.db ~= nil) .. "  frame? " .. tostring(ns.frame ~= nil) .. "  panel? " .. tostring(ns.panel ~= nil))
for tag, e in pairs(ns.errors or {}) do log("ns.errors after load: " .. tag .. " x" .. e.n .. ": " .. e.msg) end

local db = ns.db
if db then
  db.arcMaxID = 300
  -- seed history for i:14 (10 days, every 30 min, slow sine wave)
  local now = time()
  db.watch = { "i:14", "i:21", "i:7" }
  for _, s in ipairs(db.watch) do
    local rec = { hist = {} }
    for k = 0, 10 * 48 do
      local t = now - (10 * 48 - k) * 1800
      local v = base(tonumber(s:match("%d+"))) * (1 + 0.05 * math.sin(k / 20))
      rec.hist[#rec.hist+1] = { t, math.floor(v), math.floor(v * 1.05) }
    end
    db.items[s] = rec
  end
  try("Select i:14", ns.Select, "i:14")
  try("RefreshAll", ns.RefreshAll)
  runTimers()

  local d = ns.cache["i:14"]
  log("cache i:14 minbuy=" .. tostring(d and d.minbuy))
  local r
  try("Analyze", function() r = ns.Analyze("i:14", d, nil) end)
  if r then
    log(string.format("verdict=%s risk=%s/%s p=%.2f pLo=%s maxBuy=%s suggest=%s notes=%d",
      r.verdict, tostring(r.risk.level), tostring(r.risk.score), r.risk.p, tostring(r.risk.pLo), tostring(r.maxBuy), tostring(r.suggest), #r.notes))
  end

  -- ledger + learning
  for i = 1, 12 do
    try("Post/Sell/Expire " .. i, function()
      ns.Buy("i:14", 5, 20000)
      ns.Post("i:14", 5, 30000)
      if i % 3 == 0 then ns.Expire("i:14", 5, 100) else ns.Sell("i:14", 5, 30000) end
    end)
  end
  log("ML n=" .. tostring(db.ml and db.ml.n) .. " pend=" .. tostring(next(db.ml and db.ml.pend or {})))

  -- windows / tabs
  local function showWin(name)
    local w = _G[name]
    if not w then log("MISSING window " .. name); return end
    w._shown = true
    if w._scripts.OnShow then try("OnShow " .. name, w._scripts.OnShow, w) end
  end
  for _, tab in ipairs({ "overview", "market", "risk", "notes" }) do
    db.hudTab = tab
    try("UpdateUI tab=" .. tab, ns.UpdateUI)
  end
  showWin("TsmAnalizeML"); showWin("TsmAnalizeWatch"); showWin("TsmAnalizeMarket")
  runTimers()
  try("ToggleBigChart", ns.ToggleBigChart)
  try("UpdateBigChart", ns.UpdateBigChart)
  if ns.bigChart then ns.bigChart.chart.candles = true; try("BigChart candles", ns.UpdateBigChart) end
  showWin("TsmAnalizeConfig"); showWin("TsmAnalizePanel")
  try("UpdatePanel scan", function() ns.panelMode = "scan"; ns.UpdatePanel() end)
  try("StartScan *", function() ns.StartScan("*") end); runTimers()
  try("UpdatePanel craft", function() ns.panelMode = "craft"; ns.UpdatePanel() end)
  try("UpdatePanel log", function() ns.panelMode = "log"; ns.UpdatePanel() end)
  try("StartScan g:", function() ns.StartScan("g:Trade Goods: Herb") end); runTimers()

  -- how many Analyze / TSM calls does ONE ns.UpdateUI trigger with all windows open?
  local aCount, tCount = 0, 0
  local origA = ns.Analyze
  ns.Analyze = function(...) aCount = aCount + 1; return origA(...) end
  local origT = TSM_API.GetCustomPriceValue
  TSM_API.GetCustomPriceValue = function(...) tCount = tCount + 1; return origT(...) end
  ns.UpdateUI()
  log("PERF one UpdateUI (all windows open): Analyze calls=" .. aCount .. "  TSM price calls=" .. tCount)
  aCount, tCount = 0, 0
  ns.RefreshAll()
  log("PERF one RefreshAll (3 watched items): Analyze calls=" .. aCount .. "  TSM price calls=" .. tCount)
  ns.Analyze = origA
  TSM_API.GetCustomPriceValue = origT

  -- Watch window buttons
  for _, f in ipairs(registry) do
    if f._type == "Button" and f._text == "Z TSM" and f._scripts.OnClick then
      try("Watch: Z TSM (empty -> picker)", f._scripts.OnClick, f)
    end
  end
  local pk = _G["TsmAnalizeTSMPicker"]
  if pk then
    log("picker shown=" .. tostring(pk._shown))
    for _, row in ipairs(pk.rows or {}) do
      if row.path then try("Watch picker click " .. row.path, row._scripts.OnClick, row); break end
    end
  else
    log("picker frame not created")
  end

  -- ===== v1.2 features: dock, colour-blind, chart overlays/compare, archive candles =====
  try("DockSelect each tab", function()
    for _, k in ipairs({ "panel", "watch", "market", "ml", "cfg", "panel" }) do
      ns.DockSelect(k)
      local names = { panel = "TsmAnalizePanel", watch = "TsmAnalizeWatch", market = "TsmAnalizeMarket", ml = "TsmAnalizeML", cfg = "TsmAnalizeConfig" }
      local shown = {}
      for kk, nm in pairs(names) do if _G[nm] and _G[nm]._shown then shown[#shown+1] = kk end end
      table.sort(shown)
      log("   dock select " .. k .. " -> shown: " .. table.concat(shown, ","))
    end
    ns.DockSelect("panel")  -- toggles off
    local n = 0
    for _, nm in ipairs({ "TsmAnalizePanel", "TsmAnalizeWatch", "TsmAnalizeMarket", "TsmAnalizeML", "TsmAnalizeConfig" }) do if _G[nm]._shown then n = n + 1 end end
    log("   after toggle-off shown frames: " .. n .. " (db.sideTab=" .. tostring(db.sideTab) .. ")")
  end)
  try("ns.TogglePanel/ToggleConfig/ToggleWatchMenu/ShowPanel via dock", function()
    ns.TogglePanel(); ns.ToggleConfig(); ns.ToggleWatchMenu(); ns.ShowPanel("scan")
  end)
  try("Recolor", function()
    db.colorblind = true
    local r = ns.Recolor("|cff33dd66+1|r |cffff4040-1|r |cffffcc33x|r")
    log("   recolor -> " .. r)
    ns.UpdateUI(); ns.UpdatePanel()
    db.colorblind = false
  end)
  try("BigChart overlays + compare + candles + archive points", function()
    ns.ToggleBigChart()
    if not ns.bigChart:IsShown() then ns.bigChart._shown = true end
    local ch = ns.bigChart.chart
    -- make sure archive has several days for i:14 so synthetic candles exist
    local base = 20000 + 14 * 130
    local today = math.floor(time() / 86400) - 20454
    local rec = ""
    local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function enc2(n) n = math.floor(n); return ALPHA:sub(math.floor(n/64)+1, math.floor(n/64)+1) .. ALPHA:sub(n%64+1, n%64+1) end
    local function q(v) return math.floor(math.log(v) * 186 + 0.5) end
    for d = 30, 12, -1 do
      local v = base * (1 + 0.04 * math.sin(d))
      rec = rec .. enc2(today - d) .. enc2(q(v * 0.97)) .. enc2(q(v * 1.03)) .. enc2(q(v))
    end
    db.arc[14] = rec
    ch.showMedian, ch.showSMA, ch.showCost, ch.candles, ch.compare = true, true, true, true, "i:21"
    db.buyPrice["i:14"] = 21000
    ns.UpdateBigChart()
    log("   chart geom candles=" .. tostring(ch.geom and ch.geom.candles and #ch.geom.candles) .. " pts=" .. tostring(ch.geom and #ch.geom.pts))
    -- hover in candle mode
    ch.IsMouseOver = function() return true end
    local oldCursor = GetCursorPosition
    GetCursorPosition = function() return 300, 0 end
    ch._scripts.OnUpdate(ch)
    log("   hover(candle): " .. tostring(ns.bigChart.hover._text))
    ch.candles = false
    ch._scripts.OnUpdate(ch)
    log("   hover(line): " .. tostring(ns.bigChart.hover._text))
    GetCursorPosition = oldCursor
    for _, rg in ipairs({ 86400, 3*86400, 7*86400, 30*86400, false }) do ch.range = rg or nil; ns.UpdateBigChart() end
    ch.compare = nil; ch.showMedian, ch.showSMA, ch.showCost = false, false, false
    ns.UpdateBigChart()
    log("   stats line: " .. tostring(ns.bigChart.stats._text):sub(1, 160))
  end)
  try("BigChart for archive-only item (no hist)", function()
    db.selected = "i:28"
    ns.Select("i:28")
    ns.UpdateBigChart()
  end)

  -- slash commands
  local cmds = { "", "panel", "settings", "debug", "risk", "ml", "ml cal on", "ml on", "ml off", "archive", "archive full", "market", "menu",
    "export", "export hist", "import undo", "import redo", "minimap off", "mail off", "log", "accuracy", "chart", "open", "ref min(DBMarket, DBRegionMarketAvg)", "ref off",
    "alert 1g", "set margin 12", "scan", "craft", "errors" }
  for _, c in ipairs(cmds) do
    try("/tsma " .. c, function() SlashCmdList["TSMA"](c) end)
    runTimers()
  end

  -- Watch window actions
  try("Watch DoAdd via ResolveItem", function() ns.StartScan("") end); runTimers()

  -- Archive flush + read back
  try("Archive flush", function() fire("PLAYER_LOGOUT") end)
  local n, bytes = 0, 0
  for _, s in pairs(db.arc or {}) do n = n + 1; bytes = bytes + #s end
  log("archive items=" .. n .. " bytes=" .. bytes)
  runTimers()
end

for tag, e in pairs(ns.errors or {}) do log("ns.errors: " .. tag .. " x" .. e.n .. ": " .. e.msg) end
log("---- printed (last 60) ----")
for i = math.max(1, #printed - 60), #printed do log(printed[i]) end
return table.concat(out, "\n")
