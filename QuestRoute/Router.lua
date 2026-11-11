-- QuestRoute: route algorithm + quest filters.
-- PURE LUA: no WoW API calls in this file, so it can be unit-tested offline (tests/test_router.lua).
--
-- Types used here:
--   point = { x, y, instance, mapId, weight }  world coordinates in yards (from HereBeDragons),
--                                        instance = continent, mapId = uiMapId of the zone the point is in,
--                                        weight (optional, >= 1) = "counts as this many times further away"
--                                        (low drop chance); real distances are still what gets returned
--   stop  = { key, points = {point...}, ... }  anything else on the stop is passed through untouched
--   leg   = { stop = stop, point = point }     one step of a route, with the concrete point chosen

local _, ns = ...
local Router = {}
ns.Router = Router

local sqrt, huge = math.sqrt, math.huge

function Router.Distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end
local Distance = Router.Distance

---Nearest point of `stop` to `from`, ignoring indices in `exclude` (a set) and points on another instance.
---"Nearest" compares distance * point.weight; the distance returned is the real one.
---@return table|nil point, number|nil index, number distance
function Router.NearestPoint(stop, from, exclude, onlyMapId)
    local best, bestIndex, bestDist, bestCost = nil, nil, huge, huge
    for i, p in ipairs(stop.points) do
        if (not exclude or not exclude[i])
            and p.instance == from.instance
            and (not onlyMapId or p.mapId == onlyMapId) then
            local d = Distance(from, p)
            local cost = p.weight and d * p.weight or d
            if cost < bestCost then
                best, bestIndex, bestDist, bestCost = p, i, d, cost
            end
        end
    end
    return best, bestIndex, bestDist
end
local NearestPoint = Router.NearestPoint

-- Greedy nearest-neighbour: from `from`, repeatedly go to the closest remaining stop.
local function greedy(from, stops, onlyMapId, limit, out)
    local remaining = {}
    for i = 1, #stops do remaining[i] = stops[i] end
    local here = from
    while #remaining > 0 and #out < limit do
        local bestI, bestP, bestD = nil, nil, huge
        for i, stop in ipairs(remaining) do
            local p, _, d = NearestPoint(stop, here, nil, onlyMapId)
            if p and d < bestD then bestI, bestP, bestD = i, p, d end
        end
        if not bestI then break end
        out[#out + 1] = { stop = remaining[bestI], point = bestP }
        here = bestP
        table.remove(remaining, bestI)
    end
    return here
end

-- 2-opt on the open path out[first..last], whose predecessor is `anchor` (fixed). Reverses a segment whenever that
-- shortens the path; repeats until no reversal helps (bounded). Points stay fixed during this step.
local function twoOpt(anchor, out, first, last)
    local function pt(i)
        if i < first then return anchor end
        return out[i].point
    end
    local improved, passes = true, 0
    while improved and passes < 50 do
        improved, passes = false, passes + 1
        for i = first, last - 1 do
            for j = i + 1, last do
                local before = Distance(pt(i - 1), pt(i))
                local after = Distance(pt(i - 1), pt(j))
                if j < last then
                    before = before + Distance(pt(j), pt(j + 1))
                    after = after + Distance(pt(i), pt(j + 1))
                end
                if after < before - 1e-9 then
                    local a, b = i, j
                    while a < b do
                        out[a], out[b] = out[b], out[a]
                        a, b = a + 1, b - 1
                    end
                    improved = true
                end
            end
        end
    end
end

-- After reordering, re-pick each multi-point stop's point as the one nearest the previous leg.
local function repick(from, out, first, last, onlyMapId)
    local here = from
    for i = first, last do
        local p = NearestPoint(out[i].stop, here, nil, onlyMapId)
        if p then out[i].point = p end
        here = out[i].point
    end
    return here
end

---Order `stops` into a route starting at `start`.
---Stops with a point in `opts.currentMapId` go first (zone-first), then the rest of the continent.
---@param start table point
---@param stops table[] stop list
---@param opts table { currentMapId, maxStops = 30, skipTwoOpt = false }
---@return table[] legs
function Router.Build(start, stops, opts)
    opts = opts or {}
    local limit = opts.maxStops or 30
    local here, there = {}, {}
    for _, stop in ipairs(stops) do
        local local_ = opts.currentMapId and NearestPoint(stop, start, nil, opts.currentMapId)
        if local_ then
            here[#here + 1] = stop
        elseif NearestPoint(stop, start) then
            there[#there + 1] = stop
        end
    end

    local out = {}
    local last = greedy(start, here, opts.currentMapId, limit, out)
    local nLocal = #out
    if not opts.skipTwoOpt and nLocal > 2 then
        twoOpt(start, out, 1, nLocal)
        last = repick(start, out, 1, nLocal, opts.currentMapId)
    end

    greedy(last, there, nil, limit, out)
    if not opts.skipTwoOpt and #out - nLocal > 2 then
        twoOpt(last, out, nLocal + 1, #out)
        repick(last, out, nLocal + 1, #out)
    end
    return out
end

---Drop points (p.drop set) whose known drop chance (p.chance, percent) is below `minDrop`. Points with an unknown
---chance, and points that aren't item drops, are always kept. minDrop 0/nil = keep everything.
---@return table[] kept, number removed
function Router.FilterDropPoints(points, minDrop)
    if not minDrop or minDrop <= 0 then return points, 0 end
    local kept, removed = {}, 0
    for _, p in ipairs(points) do
        if p.drop and p.chance and p.chance < minDrop then
            removed = removed + 1
        else
            kept[#kept + 1] = p
        end
    end
    return kept, removed
end

---"20%", "0.4%", or nil when the chance is unknown.
function Router.FormatChance(chance)
    if not chance then return nil end
    if chance < 1 then return string.format("%.1f%%", chance) end
    return string.format("%d%%", math.floor(chance + 0.5))
end

---Why a quest/stop is left out of the route, or nil to keep it.
---@param q table { questId, level, kind = "pickup"|"objective"|"turnin" }
---@param o table { playerLevel, minBelow, maxAbove, lowTurnins, skipped = {[questId]=name} } (0 disables a level filter)
---@return string|nil reason  "skipped" | "too low" | "too high"
function Router.FilterReason(q, o)
    if o.skipped and o.skipped[q.questId] then return "skipped" end
    local level = q.level
    if not level or level <= 0 or not o.playerLevel then return nil end -- unknown or scales with the player
    local below = o.playerLevel - level
    if o.minBelow and o.minBelow > 0 and below > o.minBelow then
        if not (q.kind == "turnin" and o.lowTurnins) then return "too low" end
    end
    if o.maxAbove and o.maxAbove > 0 and -below > o.maxAbove and q.kind ~= "turnin" then
        return "too high"
    end
    return nil
end

return Router
