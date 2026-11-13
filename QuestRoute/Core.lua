-- QuestRoute: startup, settings, when to (re)route, and slash commands.
--
-- Flow: Questie ready -> Collect.Gather (stops after filters) -> Router.Build (ordered legs) -> Arrow shows legs[1].
-- The route only changes when:
--   * the current target is finished (accepted / objective done / turned in) -> full recompute
--   * you press Reroute or type /qr reroute
--   * auto-reroute is on and another stop is within `radius` yards and closer than the target
-- Progress on the current target (3/8 -> 4/8) only refreshes the label; it does not reroute.
--
-- Focus mode (/qr focus): the normal route is set aside and the arrow follows one fixed chain from Focus.lua (the
-- Cozy Sleeping Bag) step by step until it's done, then switches itself off. It's saved per character, so it
-- survives /reload and logging out.

local addonName, ns = ...
local Router, Collect, Arrow, Focus = ns.Router, ns.Collect, ns.Arrow, ns.Focus

local DEFAULTS = {
    hidden = false,
    locked = false,
    auto = false,
    radius = 40,     -- yards, for auto-reroute and the "Nearby" hint
    minBelow = 5,    -- skip quests more than this many levels below you (0 = off)
    maxAbove = 3,    -- skip quests more than this many levels above you (0 = off)
    lowTurnins = true,
    minDrop = 0,     -- hide mobs whose known drop chance for a quest-starting item is below this % (0 = off)
    skipped = {},    -- [questId] = quest name
    focus = false,   -- focus mode on (the chain's key) or false
    focusSkip = 0,   -- "Next step" presses: the current focus step is at least this index
    focusReached = {}, -- [stepId] = true for focus travel waypoints you've passed
}
local RETARGET_YARDS = 15 -- reaching an unfinished objective (or item-drop) spot moves the arrow to the next spawn
local VIA_YARDS = 25      -- reaching a focus travel waypoint (within this) moves on to the next step

local db
local route = {}      -- ordered legs
local target          -- route[1]
local visited = {}    -- point indices of the target stop already reached
local nearby          -- the stop named in the "Nearby: ..." hint, if one is showing
local stopsByKey = {}
local lastHidden = {}
local started = false

local function print_(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffQuestRoute:|r " .. msg) end

local function filterOpts()
    return {
        playerLevel = UnitLevel("player"), minBelow = db.minBelow, maxAbove = db.maxAbove,
        lowTurnins = db.lowTurnins, skipped = db.skipped, minDrop = db.minDrop,
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
    nearby = nil
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

------------------------------------------------------------------ focus mode (the chain itself is in Focus.lua)

local recompute -- defined below; focus mode hands back to it when it switches off

local focusCheck = {
    inLog = function(questId) return Collect.InLog(questId) end,
    done = function(questId) return Collect.IsCompleted(questId) end,
    reached = function(stepId) return db.focusReached[stepId] end,
}

---The chain for this character's faction, and the index of the step to do now. Your quest log decides the step;
---"Next step" presses can push it further on, never back.
local function focusPosition()
    local steps = Focus.Steps(UnitFactionGroup("player"))
    return steps, math.max(Focus.Current(steps, focusCheck), db.focusSkip or 0)
end

local function focusOff(msg)
    db.focus = false
    Arrow.SetFocus(false)
    if msg then print_(msg) end
    recompute()
end

---Point the arrow at the current focus step. Does nothing if the step hasn't changed, unless `force`.
local function focusUpdate(force)
    local steps, i = focusPosition()
    if i > #steps then
        db.focusSkip, db.focusReached = 0, {}
        focusOff(Focus.NAME .. " chain done! Focus off, back to the normal route.")
        return
    end
    if not force and target and target.stop.focusIndex == i then return end
    local s = steps[i]
    local leg = {
        stop = { key = "f:" .. s.id, stepId = s.id, questName = s.title, kind = s.kind, step = s.text,
            focus = true, focusIndex = i, via = s.via, notes = s.notes, where = Focus.Where(s) },
        point = Collect.ZonePoint(s.mapId, s.x, s.y),
    }
    route = { leg }
    setTarget(leg)
    Arrow.SetHint(string.format("Focus %d/%d: %s", i, #steps, Focus.Where(s)))
    print_(string.format("Focus %d/%d: %s — %s (%s)", i, #steps, s.title, s.text, Focus.Where(s)))
    for _, n in ipairs(s.notes) do print_("  " .. n) end
    if not leg.point then print_("  Couldn't place this on the map; head for the coordinates above.") end
end

---Once a second in focus mode: pick up quest log changes, and tick off a travel waypoint once you reach it (or are
---already well past it: much closer to the next stop than the waypoint is).
local function focusTick()
    focusUpdate()
    if not target or not target.stop.via then return end
    local here, tp = playerPoint(), target.point
    if not here or not tp or here.instance ~= tp.instance then return end
    local reached = Router.Distance(here, tp) <= VIA_YARDS
    if not reached then
        local steps, i = focusPosition()
        local nxt = steps[i + 1]
        local np = nxt and Collect.ZonePoint(nxt.mapId, nxt.x, nxt.y)
        reached = np and np.instance == here.instance
            and Router.Distance(here, np) < 0.5 * Router.Distance(tp, np) or false
    end
    if reached then
        db.focusReached[target.stop.stepId] = true
        focusUpdate()
    end
end

local function focusNext()
    local _, i = focusPosition()
    db.focusSkip = i + 1
    print_("Marked focus step " .. i .. " done. /qr focus reset undoes this.")
    focusUpdate(true)
end

local function cmdFocus(arg)
    if arg == "notes" then
        if not db.focus then print_("Focus is off. /qr focus to start it.") return end
        focusUpdate(true) -- re-prints the step and its notes
        print_("  " .. Focus.ARROW_NOTE)
        return
    end
    if arg == "next" then
        if db.focus then focusNext() else print_("Focus is off. /qr focus to start it.") end
        return
    end
    if arg == "reset" then
        db.focusSkip = 0 -- only undoes "Next step"; waypoints you really reached stay reached
        print_("Focus: Next step presses undone, back to what your quest log shows.")
        if db.focus then focusUpdate(true) end
        return
    end
    local on = arg == "on" or (arg ~= "off" and not db.focus)
    if not on then
        if db.focus then focusOff("Focus off, back to the normal route.") else print_("Focus is already off.") end
        return
    end
    local steps, i = focusPosition()
    if i > #steps then
        print_(Focus.NAME .. " chain is already done on this character.")
        return
    end
    if UnitLevel("player") < Focus.MIN_LEVEL then
        print_("Heads up: the chain can't be started below level " .. Focus.MIN_LEVEL .. ".")
    end
    db.focus = "sleepingbag"
    Arrow.SetFocus(true)
    print_("Focus on: " .. Focus.NAME .. " (" .. (UnitFactionGroup("player") or "?") .. "). The arrow follows only "
        .. "this chain until it's done. /qr focus again to turn it off.")
    print_(Focus.ARROW_NOTE .. " Hover the arrow frame for the current step's notes.")
    focusUpdate(true)
end

------------------------------------------------------------------ normal route

---Recompute the whole route from where you stand. `first` (a stop key) forces that stop to be the target:
---it gets its spawn nearest to you, and the rest of the route is planned onward from there.
function recompute(first)
    if db.focus then
        focusUpdate(true)
        return
    end
    local stops = gather()
    local start = playerPoint()
    if not start then
        route = {}
        setTarget(nil)
        return
    end
    local forced = first and stopsByKey[first]
    local forcedPoint = forced and Router.NearestPoint(forced, start)
    if forcedPoint then
        local rest = {}
        for _, stop in ipairs(stops) do
            if stop.key ~= first then rest[#rest + 1] = stop end
        end
        route = Router.Build(forcedPoint, rest, { currentMapId = forcedPoint.mapId, maxStops = 29 })
        table.insert(route, 1, { stop = forced, point = forcedPoint })
    else
        route = Router.Build(start, stops, { currentMapId = start.mapId, maxStops = 30 })
    end
    setTarget(route[1])
end

local function stopName(stop) return stop.questName or ("Quest " .. stop.questId) end

---Reroute button / `/qr reroute`. If the "Nearby" hint is up, go to that quest (that's what the hint promises);
---otherwise recompute from here, and say so when the best next stop turns out to be the same one.
local function manualReroute()
    if db.focus then
        focusUpdate(true)
        return
    end
    if nearby and stopsByKey[nearby.key] then
        local name = stopName(nearby)
        recompute(nearby.key)
        print_("Rerouted to nearby quest: " .. name)
        return
    end
    local before = target and target.stop.key
    recompute()
    if target and target.stop.key == before then
        print_("Rerouted: " .. stopName(target.stop) .. " is still the best next stop.")
    else
        print_("Rerouted.")
    end
end

---Quest data changed. Keep the current target unless it is gone; just refresh its text and drop finished legs.
local function refresh()
    if not started then return end
    if db.focus then
        focusUpdate()
        return
    end
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
    if not started then return end
    if db.focus then
        focusTick()
        return
    end
    if not target then return end
    local here = playerPoint()
    if not here then return end
    local tp = target.point

    if (target.stop.kind == "objective" or (tp and tp.drop)) and tp and Router.Distance(here, tp) <= RETARGET_YARDS then
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
    nearby = nearStop
    if not nearStop then
        Arrow.SetHint("")
    elseif db.auto then
        recompute(nearStop.key)
        print_("Rerouted to nearby quest: " .. stopName(nearStop))
    else
        Arrow.SetHint("Nearby: " .. stopName(nearStop) .. " — press Reroute")
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
    if arg == "" and db.focus then -- the Skip button reads "Next step" in focus mode
        focusNext()
        return
    end
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
    local chance = leg.point and leg.point.drop and Router.FormatChance(leg.point.chance)
    if chance then where = where .. " (" .. chance .. ")" end
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
    "/qr mindrop <pct> — skip mobs whose drop chance for a quest-starting item is below pct (now %s, 0 = off)",
    "/qr auto on|off — auto-reroute near other quests (now %s)",
    "/qr radius <yards> — distance for auto-reroute / nearby hint (now %d)",
    "/qr lock — lock/unlock the frame position",
    "/qr list [all] — print the route (all = also show hidden stops and why)",
    "/qr focus [on|off] — follow only the Cozy Sleeping Bag chain until it's done (now %s). Also /qr bag",
    "/qr focus next — mark the current focus step done; /qr focus reset — undo that",
    "/qr focus notes — print the guide notes for the current step again (or hover the arrow frame)",
}

local function cmdHelp()
    local vals = { [5] = db.minBelow, [6] = db.maxAbove, [7] = db.lowTurnins and "on" or "off",
        [8] = db.minDrop .. "%", [9] = db.auto and "on" or "off", [10] = db.radius,
        [13] = db.focus and "on" or "off" }
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
    elseif cmd == "reroute" then manualReroute()
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
    elseif cmd == "mindrop" then
        local n = tonumber((arg:gsub("%%", "")))
        if not n or n < 0 or n > 100 then
            print_("Minimum drop chance is " .. db.minDrop .. "% (0 = off). Usage: /qr mindrop <0-100>")
            return
        end
        db.minDrop = n
        print_(n == 0 and "Drop-chance filter off."
            or ("Skipping mobs with a known drop chance under " .. n .. "%. Unknown chances are kept."))
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
    elseif cmd == "focus" or cmd == "bag" then cmdFocus(arg:lower())
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
        reroute = function() manualReroute() end,
        skip = function() cmdSkip("") end,
    })
    Arrow.SetFocus(db.focus)
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
        -- Bags changed: a quest-starting item may have been looted (its pickup stop leaves the route).
        if not pcall(self.RegisterEvent, self, "BAG_UPDATE_DELAYED") then pcall(self.RegisterEvent, self, "BAG_UPDATE") end
    else
        queueRefresh()
    end
end)
