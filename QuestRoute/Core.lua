-- QuestRoute: startup, settings, when to (re)route, and slash commands.
--
-- Flow: Questie ready -> Collect.Gather (stops after filters) -> Router.Build (ordered legs) -> Arrow shows legs[1].
-- The route only changes when:
--   * the current target is finished (accepted / objective done / turned in) -> full recompute
--   * you press Reroute or type /qr reroute
--   * auto-reroute is on and another stop is within `radius` yards and closer than the target
-- Progress on the current target (3/8 -> 4/8) only refreshes the label; it does not reroute.

local addonName, ns = ...
local Router, Collect, Arrow = ns.Router, ns.Collect, ns.Arrow

local DEFAULTS = {
    hidden = false,
    locked = false,
    auto = false,
    radius = 40,     -- yards, for auto-reroute and the "Nearby" hint
    minBelow = 5,    -- skip quests more than this many levels below you (0 = off)
    maxAbove = 3,    -- skip quests more than this many levels above you (0 = off)
    lowTurnins = true,
    skipped = {},    -- [questId] = quest name
}
local RETARGET_YARDS = 15 -- reaching an unfinished objective spot moves the arrow to the next spawn of it

local db
local route = {}      -- ordered legs
local target          -- route[1]
local visited = {}    -- point indices of the target stop already reached
local stopsByKey = {}
local lastHidden = {}
local started = false

local function print_(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffQuestRoute:|r " .. msg) end

local function filterOpts()
    return {
        playerLevel = UnitLevel("player"), minBelow = db.minBelow, maxAbove = db.maxAbove,
        lowTurnins = db.lowTurnins, skipped = db.skipped,
    }
end

local function playerPoint()
    local x, y, instance = Collect.HBD:GetPlayerWorldPosition()
    if not x then return nil end
    return { x = x, y = y, instance = instance, mapId = Collect.HBD:GetPlayerZone() }
end

local function setTarget(leg)
    target = leg
    visited = {}
    Arrow.SetTarget(leg)
    Arrow.SetHint("")
end

local function gather()
    local kept, hidden = Collect.Gather(filterOpts())
    stopsByKey = {}
    for _, stop in ipairs(kept) do stopsByKey[stop.key] = stop end
    lastHidden = hidden
    return kept
end

---Recompute the whole route from where you stand. `first` (a stop key) forces that stop to be the target.
local function recompute(first)
    local stops = gather()
    local start = playerPoint()
    if not start then
        route = {}
        setTarget(nil)
        return
    end
    route = Router.Build(start, stops, { currentMapId = start.mapId, maxStops = 30 })
    if first then
        for i, leg in ipairs(route) do
            if leg.stop.key == first then
                table.remove(route, i)
                table.insert(route, 1, leg)
                break
            end
        end
    end
    setTarget(route[1])
end

---Quest data changed. Keep the current target unless it is gone; just refresh its text and drop finished legs.
local function refresh()
    if not started then return end
    gather()
    if not target or not stopsByKey[target.stop.key] then
        recompute()
        return
    end
    local kept = {}
    for _, leg in ipairs(route) do
        local stop = stopsByKey[leg.stop.key]
        if stop then
            leg.stop = stop
            kept[#kept + 1] = leg
        end
    end
    route = kept
    Arrow.SetTarget(target) -- same target, updated progress text
end

local refreshQueued = false
local function queueRefresh()
    if refreshQueued or not started then return end
    refreshQueued = true
    C_Timer.After(0.5, function()
        refreshQueued = false
        refresh()
    end)
end

-- Once a second: sweep objective spawns, and handle "another quest is close".
local function tick()
    if not started or not target then return end
    local here = playerPoint()
    if not here then return end
    local tp = target.point

    if target.stop.kind == "objective" and tp and Router.Distance(here, tp) <= RETARGET_YARDS then
        for i, p in ipairs(target.stop.points) do
            if p.x == tp.x and p.y == tp.y then visited[i] = true end
        end
        local nextPoint = Router.NearestPoint(target.stop, here, visited)
        if not nextPoint then -- every spawn visited: start the sweep over
            visited = {}
            nextPoint = Router.NearestPoint(target.stop, here, nil)
        end
        if nextPoint and (nextPoint.x ~= tp.x or nextPoint.y ~= tp.y) then
            target.point = nextPoint
            Arrow.SetTarget(target)
        end
        tp = target.point
    end

    local targetDist = tp and tp.instance == here.instance and Router.Distance(here, tp) or math.huge
    local nearStop, nearDist = nil, db.radius
    for key, stop in pairs(stopsByKey) do
        if key ~= target.stop.key and stop.questId ~= target.stop.questId then
            local _, _, d = Router.NearestPoint(stop, here)
            if d <= nearDist and d < targetDist then nearStop, nearDist = stop, d end
        end
    end
    if not nearStop then
        Arrow.SetHint("")
    elseif db.auto then
        recompute(nearStop.key)
        print_("Rerouted to nearby quest: " .. (nearStop.questName or nearStop.questId))
    else
        Arrow.SetHint("Nearby: " .. (nearStop.questName or nearStop.questId) .. " — press Reroute")
    end
end

------------------------------------------------------------------ skipping

local function findQuests(text, pool)
    local id = tonumber(text)
    if id then return { id } end
    local needle, matches = text:lower(), {}
    for questId, name in pairs(pool) do
        if name and name:lower():find(needle, 1, true) then matches[#matches + 1] = questId end
    end
    return matches
end

local function skipQuest(questId, name)
    db.skipped[questId] = name or Collect.QuestName(questId) or ("Quest " .. questId)
    print_("Skipped: " .. db.skipped[questId] .. " (" .. questId .. "). Undo with /qr unskip " .. questId)
    recompute()
end

local function cmdSkip(arg)
    if arg == "" then
        if not target then print_("Nothing to skip.") return end
        skipQuest(target.stop.questId, target.stop.questName)
        return
    end
    local matches = findQuests(arg, Collect.KnownQuests())
    if #matches == 0 then
        print_("No quest in your log or available nearby matches '" .. arg .. "'. Use the quest id instead.")
    elseif #matches > 1 then
        print_(#matches .. " quests match '" .. arg .. "', be more specific:")
        for _, id in ipairs(matches) do print_("  " .. id .. "  " .. (Collect.QuestName(id) or "?")) end
    else
        skipQuest(matches[1])
    end
end

local function cmdUnskip(arg)
    if arg == "all" then
        local n = 0
        for _ in pairs(db.skipped) do n = n + 1 end
        db.skipped = {}
        print_("Unskipped " .. n .. " quest(s).")
        recompute()
        return
    end
    local matches = findQuests(arg, db.skipped)
    if tonumber(arg) and not db.skipped[tonumber(arg)] then matches = {} end
    if #matches ~= 1 then
        print_(#matches == 0 and ("No skipped quest matches '" .. arg .. "'. See /qr skipped")
            or ("Several skipped quests match '" .. arg .. "', use the id. See /qr skipped"))
        return
    end
    print_("Unskipped: " .. db.skipped[matches[1]])
    db.skipped[matches[1]] = nil
    recompute()
end

------------------------------------------------------------------ slash commands

local function onOff(arg, current)
    if arg == "on" then return true elseif arg == "off" then return false end
    return not current
end

local function setLevel(field, arg, label, cmd)
    local n = tonumber(arg)
    if not n or n < 0 then
        print_(label .. " is " .. db[field] .. " (0 = off). Usage: /qr " .. cmd .. " <levels>")
        return
    end
    db[field] = math.floor(n)
    print_(label .. " set to " .. db[field] .. (db[field] == 0 and " (off)" or ""))
    recompute()
end

local function legLine(i, leg)
    local s = leg.stop
    local where = leg.point and leg.point.name and (" @ " .. leg.point.name) or ""
    return string.format("%2d. [%s] %s — %s%s", i, s.kind, s.questName or s.questId, s.step, where)
end

local function cmdList(arg)
    if #route == 0 then print_("Route is empty.") end
    for i = 1, math.min(10, #route) do print_(legLine(i, route[i])) end
    if #route > 10 then print_("  ... " .. (#route - 10) .. " more") end
    if arg == "all" then
        print_(#lastHidden .. " hidden stop(s):")
        for _, s in ipairs(lastHidden) do
            print_(string.format("  (%s) [%s] %s — %s", s.reason, s.kind, s.questName or s.questId, s.step))
        end
    elseif #lastHidden > 0 then
        print_(#lastHidden .. " stop(s) hidden by filters — /qr list all to see them")
    end
end

local HELP = {
    "/qr — show/hide the arrow",
    "/qr reroute — recompute the route from here",
    "/qr skip [id|name] — skip the current quest, or one by id/name",
    "/qr unskip <id|name|all>, /qr skipped — undo / list skips",
    "/qr minlevel <n> — skip quests more than n levels below you (now %d, 0 = off)",
    "/qr maxlevel <n> — skip quests more than n levels above you (now %d, 0 = off)",
    "/qr lowturnins on|off — still turn in low quests (now %s)",
    "/qr auto on|off — auto-reroute near other quests (now %s)",
    "/qr radius <yards> — distance for auto-reroute / nearby hint (now %d)",
    "/qr lock — lock/unlock the frame position",
    "/qr list [all] — print the route (all = also show hidden stops and why)",
}

local function cmdHelp()
    local vals = { [5] = db.minBelow, [6] = db.maxAbove, [7] = db.lowTurnins and "on" or "off",
        [8] = db.auto and "on" or "off", [9] = db.radius }
    for i, line in ipairs(HELP) do print_(vals[i] and line:format(vals[i]) or line) end
end

local function onSlash(msg)
    if not started then
        print_(Collect.ok and "Waiting for Questie to finish loading." or ("Disabled: " .. tostring(Collect.err)))
        return
    end
    local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        print_(Arrow.Toggle(db) and "Shown." or "Hidden. /qr to show again.")
    elseif cmd == "reroute" then
        recompute()
        print_("Rerouted.")
    elseif cmd == "skip" then cmdSkip(arg)
    elseif cmd == "unskip" then cmdUnskip(arg)
    elseif cmd == "skipped" then
        local any = false
        for id, name in pairs(db.skipped) do print_("  " .. id .. "  " .. name); any = true end
        if not any then print_("No skipped quests.") end
    elseif cmd == "minlevel" then setLevel("minBelow", arg, "Levels below you allowed", cmd)
    elseif cmd == "maxlevel" then setLevel("maxAbove", arg, "Levels above you allowed", cmd)
    elseif cmd == "lowturnins" then
        db.lowTurnins = onOff(arg, db.lowTurnins)
        print_("Low-level turn-ins " .. (db.lowTurnins and "kept." or "skipped."))
        recompute()
    elseif cmd == "auto" then
        db.auto = onOff(arg, db.auto)
        print_("Auto-reroute " .. (db.auto and "on" or "off") .. ".")
    elseif cmd == "radius" then
        local n = tonumber(arg)
        if n and n > 0 then db.radius = n; print_("Radius " .. n .. " yd.") else print_("Usage: /qr radius <yards>") end
    elseif cmd == "lock" then
        db.locked = not db.locked
        print_(db.locked and "Frame locked." or "Frame unlocked (drag to move).")
    elseif cmd == "list" then cmdList(arg:lower())
    else cmdHelp() end
end

SLASH_QUESTROUTE1 = "/qr"
SLASH_QUESTROUTE2 = "/questroute"
SlashCmdList.QUESTROUTE = onSlash

------------------------------------------------------------------ startup

local function start()
    if started then return end
    started = true
    Arrow.Create(db, {
        reroute = function() recompute(); print_("Rerouted.") end,
        skip = function() cmdSkip("") end,
    })
    Collect.onAvailableChanged = queueRefresh
    if Questie.API.RegisterForQuestUpdates then Questie.API.RegisterForQuestUpdates(queueRefresh) end
    if next(Collect.available) == nil then Collect.RequestAvailablePass() end
    C_Timer.NewTicker(1, tick)
    recompute()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        QuestRouteDB = QuestRouteDB or {}
        db = QuestRouteDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = type(v) == "table" and {} or v end
        end
        if not Collect.ok then
            print_("Disabled: " .. tostring(Collect.err))
            return
        end
        if not (Questie and Questie.API and Questie.API.RegisterOnReady) then
            print_("Disabled: this Questie version has no Questie.API.RegisterOnReady")
            return
        end
        Questie.API.RegisterOnReady(start)
        -- pcall: an event this client doesn't have (QUEST_REMOVED is newer) would otherwise raise an error.
        for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP" }) do
            pcall(self.RegisterEvent, self, e)
        end
    else
        queueRefresh()
    end
end)
