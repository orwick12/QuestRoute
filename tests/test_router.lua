-- Offline tests for QuestRoute/Router.lua. Run with: uv run --no-project --with lupa python tests/run_tests.py
-- `Router` is injected by run_tests.py (the addon namespace's Router table).

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function P(x, y, mapId, instance) return { x = x, y = y, mapId = mapId or 1, instance = instance or 0 } end
local function S(key, points) return { key = key, points = points } end
local START = P(0, 0)

local function keys(route)
    local out = {}
    for i, leg in ipairs(route) do out[i] = leg.stop.key end
    return table.concat(out, ",")
end

local function pathLength(start, route)
    local total, prev = 0, start
    for _, leg in ipairs(route) do
        total = total + Router.Distance(prev, leg.point)
        prev = leg.point
    end
    return total
end

------------------------------------------------------------------ routing

test("empty input gives empty route", function()
    eq(#Router.Build(START, {}, { currentMapId = 1 }), 0)
end)

test("single stop", function()
    local r = Router.Build(START, { S("a", { P(10, 0) }) }, { currentMapId = 1 })
    eq(keys(r), "a")
    eq(r[1].point.x, 10)
end)

test("stops with no points are dropped", function()
    eq(keys(Router.Build(START, { S("a", {}), S("b", { P(5, 5) }) }, { currentMapId = 1 })), "b")
end)

test("nearest first along a line", function()
    local stops = { S("far", { P(30, 0) }), S("near", { P(10, 0) }), S("mid", { P(20, 0) }) }
    eq(keys(Router.Build(START, stops, { currentMapId = 1 })), "near,mid,far")
end)

test("multi-point stop picks the point nearest the previous leg", function()
    local r = Router.Build(START, { S("boars", { P(100, 100), P(3, 4), P(-50, 0) }) }, { currentMapId = 1 })
    eq(r[1].point.x, 3)
    eq(r[1].point.y, 4)
end)

test("points on another continent are ignored", function()
    local stops = { S("other", { P(1, 1, 1, 9) }), S("here", { P(50, 0) }) }
    eq(keys(Router.Build(START, stops, { currentMapId = 1 })), "here")
end)

test("current zone stops come before closer stops in other zones", function()
    local stops = { S("otherzone", { P(5, 0, 2) }), S("thiszone", { P(40, 0, 1) }) }
    eq(keys(Router.Build(START, stops, { currentMapId = 1 })), "thiszone,otherzone")
end)

test("2-opt never makes the greedy route longer, and fixes a known greedy trap", function()
    -- Greedy from (0,0) goes to b(1,0) first, then back past the start to a(-3,0), then all the way to c(10,0):
    -- b,a,c = 1+4+13 = 18 yards. Going left first, a,b,c = 3+4+9 = 16 yards, which 2-opt should find.
    local stops = { S("a", { P(-3, 0) }), S("b", { P(1, 0) }), S("c", { P(10, 0) }) }
    local greedy = Router.Build(START, stops, { currentMapId = 1, skipTwoOpt = true })
    local improved = Router.Build(START, stops, { currentMapId = 1 })
    eq(keys(greedy), "b,a,c", "greedy order")
    assert(pathLength(START, improved) <= pathLength(START, greedy), "2-opt made the route longer")
    eq(keys(improved), "a,b,c", "2-opt order")
end)

test("2-opt on a random cloud is never worse than greedy", function()
    math.randomseed(42)
    for _ = 1, 25 do
        local stops = {}
        for i = 1, 20 do stops[i] = S("s" .. i, { P(math.random(-500, 500), math.random(-500, 500)) }) end
        local g = pathLength(START, Router.Build(START, stops, { currentMapId = 1, skipTwoOpt = true }))
        local o = pathLength(START, Router.Build(START, stops, { currentMapId = 1 }))
        assert(o <= g + 1e-9, "2-opt worse: " .. o .. " > " .. g)
    end
end)

test("maxStops caps the route length", function()
    local stops = {}
    for i = 1, 50 do stops[i] = S("s" .. i, { P(i, 0) }) end
    eq(#Router.Build(START, stops, { currentMapId = 1, maxStops = 30 }), 30)
end)

test("NearestPoint skips excluded points and falls back when all are excluded", function()
    local stop = S("x", { P(1, 0), P(5, 0), P(9, 0) })
    local p, i = Router.NearestPoint(stop, START, { [1] = true })
    eq(p.x, 5); eq(i, 2)
    local p2 = Router.NearestPoint(stop, START, { [1] = true, [2] = true, [3] = true })
    eq(p2, nil)
end)

------------------------------------------------------------------ filters

local base = { playerLevel = 20, minBelow = 5, maxAbove = 3, lowTurnins = true, skipped = {} }
local function opts(over)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end
local function Q(level, kind, id) return { questId = id or 1, level = level, kind = kind or "pickup" } end

test("skipped quest is filtered with reason 'skipped'", function()
    eq(Router.FilterReason(Q(20, "pickup", 77), opts({ skipped = { [77] = "Foo" } })), "skipped")
    eq(Router.FilterReason(Q(20, "turnin", 77), opts({ skipped = { [77] = "Foo" } })), "skipped")
end)

test("too low: exactly minBelow levels under is kept, one more is dropped", function()
    eq(Router.FilterReason(Q(15), opts()), nil)
    eq(Router.FilterReason(Q(14), opts()), "too low")
end)

test("too high: exactly maxAbove levels over is kept, one more is dropped", function()
    eq(Router.FilterReason(Q(23), opts()), nil)
    eq(Router.FilterReason(Q(24), opts()), "too high")
end)

test("0 disables each level filter", function()
    eq(Router.FilterReason(Q(1), opts({ minBelow = 0 })), nil)
    eq(Router.FilterReason(Q(60), opts({ maxAbove = 0 })), nil)
end)

test("low turn-in kept while lowTurnins is on, dropped when off", function()
    eq(Router.FilterReason(Q(5, "turnin"), opts()), nil)
    eq(Router.FilterReason(Q(5, "turnin"), opts({ lowTurnins = false })), "too low")
    -- low objectives are still dropped even with lowTurnins on
    eq(Router.FilterReason(Q(5, "objective"), opts()), "too low")
end)

test("turn-ins are never dropped for being too high (the work is already done)", function()
    eq(Router.FilterReason(Q(40, "turnin"), opts()), nil)
end)

test("unknown or scaling levels (nil, 0, -1) are kept", function()
    eq(Router.FilterReason(Q(nil), opts()), nil)
    eq(Router.FilterReason(Q(0), opts()), nil)
    eq(Router.FilterReason(Q(-1), opts()), nil)
end)

------------------------------------------------------------------ runner

local passed, failed = 0, 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print("PASS  " .. t.name)
    else
        failed = failed + 1
        print("FAIL  " .. t.name .. "\n      " .. tostring(err))
    end
end
print(string.format("\n%d passed, %d failed", passed, failed))
return failed
