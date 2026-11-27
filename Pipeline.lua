local ADDON, ns = ...

------------------------------------------------------------------
-- POTOK ANALYZE: jedna lista etapow z priorytetami zamiast lancucha opakowan zaleznego od kolejnosci w .toc
--   ns.AddStage(nazwa, priorytet, fn)  fn(nastepny, s, d, buy) -> r   (nizszy priorytet = blizej rdzenia Analyze)
--   Rdzen = ns.Analyze w chwili wczytania tego pliku (Core + Learn + Risk + Profit). Etapy mozna rejestrowac w dowolnej kolejnosci.
--   Priorytety: 10 Forecast, 20 Ladder. Podglad: /tsma stages
-- Wczytaj PO Profit.lua, PRZED Forecast/Ladder/AnalyzeCache (cache opakowuje caly potok).
------------------------------------------------------------------

local stages, chain, dirty = {}, nil, true
local base = ns.Analyze

function ns.AddStage(name, prio, fn)
    for i, st in ipairs(stages) do
        if st.name == name then table.remove(stages, i); break end
    end
    stages[#stages + 1] = { name = name, prio = prio, fn = fn }
    table.sort(stages, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.name < b.name
    end)
    dirty = true
end

local function Rebuild()
    local c = base
    for _, st in ipairs(stages) do
        local nxt, fn = c, st.fn
        c = function(s, d, buy) return fn(nxt, s, d, buy) end
    end
    chain, dirty = c, false
end

function ns.Analyze(s, d, buy)
    if dirty then Rebuild() end
    return chain(s, d, buy)
end

function ns.StageList()
    local out = {}
    for _, st in ipairs(stages) do out[#out + 1] = st.prio .. " " .. st.name end
    return out
end

local origSlash = SlashCmdList["TSMA"]
SlashCmdList["TSMA"] = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if cmd == "stages" and ns.db then
        ns.Print("Etapy Analyze (od rdzenia): " .. (#stages > 0 and table.concat(ns.StageList(), " -> ") or "brak"))
    elseif origSlash then
        origSlash(msg)
    end
end
