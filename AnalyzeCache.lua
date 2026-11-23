local ADDON, ns = ...

------------------------------------------------------------------
-- WSPOLNY CACHE ns.Analyze
-- HUD, wykresy, Hub, Lista (RightText), ML i alerty wolaly Analyze osobno przy kazdym odswiezeniu.
-- Teraz wynik jest liczony raz na "generacje" i wspoldzielony; generacja rosnie przy ns.InvalidateTips()
-- (wolane z ns.UpdateUI i ns.SetField, czyli po kazdej zmianie danych / ustawien).
-- Cache obejmuje tylko wywolania z danymi z ns.cache[s] (skaner i komendy z swiezym FetchTSM licza jak dotad).
-- Wynik jest wspoldzielony: nie modyfikuj zwroconej tabeli r w kodzie wywolujacym.
-- Wczytaj PO Profit.lua (ktory jest ostatnim opakowaniem Analyze), np. zaraz po nim w .toc.
------------------------------------------------------------------

local MAX_ENTRIES = 400
local store, count, gen = {}, 0, 0
ns.analyzeStats = { hit = 0, miss = 0 }

local function Reset()
    gen = gen + 1
    store, count = {}, 0
end

local origAnalyze = ns.Analyze
function ns.Analyze(s, d, buy)
    if not (s and d and ns.cache and ns.cache[s] == d) then
        return origAnalyze(s, d, buy)
    end
    local slot = store[s]
    local key = buy or false
    if slot and slot.d == d and slot.r[key] then
        ns.analyzeStats.hit = ns.analyzeStats.hit + 1
        return slot.r[key]
    end
    ns.analyzeStats.miss = ns.analyzeStats.miss + 1
    local r = origAnalyze(s, d, buy)
    if not slot or slot.d ~= d then
        if not slot then
            if count >= MAX_ENTRIES then Reset() end
            count = count + 1
        end
        slot = { d = d, r = {} }
        store[s] = slot
    end
    slot.r[key] = r
    return r
end

-- unieważnienie: po kazdej zmianie danych / ustawien (UpdateUI wola InvalidateTips na poczatku)
local origInvalidate = ns.InvalidateTips
function ns.InvalidateTips()
    Reset()
    if origInvalidate then origInvalidate() end
end

-- statystyki skutecznosci: ns.analyzeStats.hit / ns.analyzeStats.miss
