-- Smoke test: load the real addon files (Router, Collect, Arrow, Core) against stubbed WoW + a fake Questie, then
-- drive startup, slash commands, ticks and the arrow OnUpdate. Catches runtime errors the syntax check can't.
-- `ADDON_FILES` (name -> source) is injected by run_tests.py. This does NOT prove anything about the real client.

local results, failed = {}, 0
local function check(cond, msg)
    if cond then print("PASS  " .. msg) else failed = failed + 1; print("FAIL  " .. msg) end
end

------------------------------------------------------------------ WoW stubs
local chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
local function lastChat() return chat[#chat] or "" end
local function chatHas(s)
    for _, m in ipairs(chat) do if m:find(s, 1, true) then return true end end
    return false
end

local frames = {}
local function newObject()
    local o = { scripts = {}, shown = true, calls = {} }
    return setmetatable(o, { __index = function(t, k)
        if k == "SetScript" then return function(self, name, fn) self.scripts[name] = fn end end
        if k == "GetScript" then return function(self, name) return self.scripts[name] end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "Show" then return function(self) self.shown = true end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "GetPoint" then return function() return "TOP", nil, "TOP", 0, -120 end end
        if k == "SetText" then return function(self, v) self.text = v end end
        if k == "SetRotation" then return function(self, v) self.rotation = v end end
        if k == "CreateTexture" or k == "CreateFontString" then
            return function() local c = newObject(); frames[#frames + 1] = c; return c end
        end
        return function(self, ...) self.calls[k] = { ... } end -- any other widget method: record and no-op
    end })
end
function CreateFrame() local f = newObject(); frames[#frames + 1] = f; return f end
UIParent = newObject()
GameTooltip = newObject()
GameTooltip_Hide = function() end
SlashCmdList = {}

local playerLevel, facing = 10, 0
function UnitLevel() return playerLevel end
function GetPlayerFacing() return facing end
local bags = {} -- [itemId] = count
function GetItemCount(itemId) return bags[itemId] or 0 end

local timers, tickers = {}, {}
C_Timer = {
    After = function(_, fn) timers[#timers + 1] = fn end,
    NewTicker = function(_, fn) tickers[#tickers + 1] = fn end,
}
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end
local function tick() for _, fn in ipairs(tickers) do fn() end end

function hooksecurefunc(tbl, name, hook)
    local orig = tbl[name]
    tbl[name] = function(...) local r = { orig(...) }; hook(...); return unpack(r) end
end

------------------------------------------------------------------ fake Questie
-- Coordinates: zone percent * 10 = world yards, all on instance 0, zone (area) id 12 = uiMapId 12.
local player = { x = 0, y = 0 }
local HBD = {
    GetWorldCoordinatesFromZone = function(_, x, y, map) return x * 1000, y * 1000, 0 end,
    GetPlayerWorldPosition = function() return player.x, player.y, 0 end,
    GetPlayerZone = function() return 12 end,
    GetWorldVector = function(_, inst, ox, oy, dx, dy)
        local ddx, ddy = dx - ox, dy - oy
        return math.atan2(-ddx, ddy) % (2 * math.pi), math.sqrt(ddx * ddx + ddy * ddy)
    end,
}
LibStub = function(name) if name == "HereBeDragonsQuestie-2.0" then return HBD end end

local NPCS = {
    [1] = { name = "Marshal McBride", spawns = { [12] = { { 1, 0 } } }, friendly = true },   -- 10 yd away
    [2] = { name = "Far Giver", spawns = { [12] = { { 50, 0 } } }, friendly = true },       -- 500 yd away
    [3] = { name = "Dungeon Guy", spawns = { [12] = { { -1, -1 } } }, friendly = true },    -- dungeon spawn
    [4] = { name = "High Giver", spawns = { [12] = { { 5, 0 } } }, friendly = true },
    -- 2000 yd away and filed under another zone (13): what a zone border / city / cave looks like
    [5] = { name = "Border Giver", spawns = { [13] = { { 200, 0 } } }, friendly = true },
    -- drops the item that starts quest 105; two spawns 50 yd apart, far from everything else
    [6] = { name = "Defias Thug", spawns = { [12] = { { 300, 0 }, { 305, 0 } } }, friendly = false },
    -- also drops it, closer to the drop camp but only a 2% chance (Defias Thug: 20%)
    [7] = { name = "Defias Pillager", spawns = { [12] = { { 297, 0 } } }, friendly = false },
}
local ITEMS = { [900] = { name = "Bloody Note", npcDrops = { 6, 7 } } }
local DROPRATES = { ["900:6"] = { 20, "wowhead" }, ["900:7"] = { 2, "wowhead" } }
local function mkQuest(id, name, level, starter, finisher)
    return { Id = id, name = name, level = level, Starts = { NPC = { starter } }, Finisher = { NPC = { finisher } },
        Objectives = {}, SpecialObjectives = {}, IsComplete = function(self) return self.complete or 0 end }
end
local DBQUESTS = {
    [100] = mkQuest(100, "Near Pickup", 10, 1, 1),
    [101] = mkQuest(101, "Far Pickup", 10, 2, 2),
    [102] = mkQuest(102, "Dungeon Pickup", 10, 3, 3),
    [103] = mkQuest(103, "Way Too High", 20, 4, 4),
    [104] = mkQuest(104, "Border Pickup", 10, 5, 5),
    [105] = mkQuest(105, "Mysterious Note", 10, nil, 1),
}
DBQUESTS[105].Starts = { Item = { 900 } }
-- A quest in the log with a kill objective whose spawns are at 20 yd and 60 yd.
local logQuest = mkQuest(200, "Kobold Stew", 10, 1, 1)
logQuest.Objectives[1] = { Index = 1, Description = "Kobold Vermin", Needed = 8, Collected = 3, Completed = false,
    spawnList = { [6] = { Name = "Kobold Vermin", Spawns = { [12] = { { 2, 0 }, { 6, 0 } } } } } }
local acceptances = { [200] = { questId = 200, quest = logQuest } }

local ActiveQuests = { GetAll = function() return acceptances end, Get = function(id) return acceptances[id] end }
local AvailableQuests = {
    DrawAvailableQuest = function(quest) end,
    RemoveQuest = function(questId) end,
    CalculateAndDrawAll = function() end,
}
local QuestieDB = {
    GetNPC = function(_, id) return NPCS[id] end,
    GetObject = function() return nil end,
    GetItem = function(_, id) return ITEMS[id] end,
    GetItemDroprate = function(itemId, npcId) return DROPRATES[itemId .. ":" .. npcId] end,
    GetQuest = function(id) return DBQUESTS[id] end,
}
local ZoneDB = { GetUiMapIdByAreaId = function(_, areaId) return areaId end }
local modules = { ActiveQuests = ActiveQuests, AvailableQuests = AvailableQuests, QuestieDB = QuestieDB, ZoneDB = ZoneDB }
QuestieLoader = { ImportModule = function(_, name) return modules[name] end }

local readyCallbacks, updateCallbacks = {}, {}
Questie = {
    db = { char = { complete = {}, hidden = {} } },
    API = {
        RegisterOnReady = function(cb) readyCallbacks[#readyCallbacks + 1] = cb end,
        RegisterForQuestUpdates = function(cb) updateCallbacks[#updateCallbacks + 1] = cb end,
    },
}

------------------------------------------------------------------ load the addon like WoW does
local ns = {}
for _, file in ipairs({ "Router.lua", "Collect.lua", "Arrow.lua", "Core.lua" }) do
    local fn, err = loadstring(ADDON_FILES[file], "@" .. file)
    assert(fn, err)
    fn("QuestRoute", ns)
end
check(ns.Collect.ok, "Collect imported all Questie modules (err=" .. tostring(ns.Collect.err) .. ")")

-- Questie draws its available quests (this goes through our hook)
for _, id in ipairs({ 100, 101, 102, 103, 104, 105 }) do AvailableQuests.DrawAvailableQuest(DBQUESTS[id]) end
check(ns.Collect.available[100] ~= nil, "hook mirrored an available quest")

-- ADDON_LOADED, then Questie ready
local eventFrame = frames[1]
eventFrame.scripts.OnEvent(eventFrame, "ADDON_LOADED", "QuestRoute")
check(type(QuestRouteDB) == "table" and QuestRouteDB.radius == 40, "saved variables initialised with defaults")
check(#readyCallbacks == 1, "registered with Questie.API.RegisterOnReady")
readyCallbacks[1]()
check(#tickers == 1 and #updateCallbacks == 1, "started: ticker + quest update callback registered")

local slash = SlashCmdList.QUESTROUTE
chat = {}
slash("list all")
check(chatHas("Near Pickup"), "/qr list shows the near pickup")
check(chatHas("(no location) [pickup] Dungeon Pickup"), "dungeon-only spawn hidden as 'no location'")
check(chatHas("(too high) [pickup] Way Too High"), "level 20 quest hidden as too high at level 10")
check(chatHas("1. [pickup] Near Pickup"), "nearest stop (10 yd pickup) is first")

-- arrow update draws without error and rotates
local arrowFrame
for _, f in ipairs(frames) do if f.scripts.OnUpdate then arrowFrame = f end end
check(arrowFrame ~= nil, "arrow frame has an OnUpdate")
local ok, err = pcall(arrowFrame.scripts.OnUpdate, arrowFrame, 1)
check(ok, "arrow OnUpdate runs (" .. tostring(err) .. ")")

-- skip the current target (Near Pickup) -> next target is the kobold objective (20 yd)
chat = {}
slash("skip")
check(QuestRouteDB.skipped[100] == "Near Pickup", "/qr skip saved the current quest")
slash("list")
check(chatHas("1. [objective] Kobold Stew"), "after skip, kobold objective is first")

-- skip by name, ambiguous and unknown
chat = {}
slash("skip pickup")
check(chatHas("quests match 'pickup'"), "ambiguous name asks to be specific")
slash("skip nonsense-xyz")
check(chatHas("No quest in your log"), "unknown name reports no match")

-- unskip by name, and all
slash("unskip near")
check(QuestRouteDB.skipped[100] == nil, "/qr unskip <name> restored it")
slash("skip 101")
slash("unskip all")
check(next(QuestRouteDB.skipped) == nil, "/qr unskip all cleared skips")

-- level filters
slash("maxlevel 0")
chat = {}
slash("list all")
check(chatHas("Way Too High"), "maxlevel 0 disables the high filter")
check(not chatHas("(too high)"), "nothing hidden as too high with filter off")
slash("maxlevel 3")
slash("minlevel abc")
check(chatHas("Usage: /qr minlevel"), "bad minlevel input shows usage")

-- progress on the target must NOT reroute; finishing it must
slash("reroute") -- target: Near Pickup
logQuest.Objectives[1].Collected = 4
for _, cb in ipairs(updateCallbacks) do cb(200, 1, 1) end
runTimers()
chat = {}
slash("list")
check(chatHas("1. [pickup] Near Pickup"), "objective progress keeps the same target")
check(chatHas("Kobold Vermin 4/8"), "progress text refreshed")

-- accept Near Pickup: it leaves the available set without RemoveQuest (like Questie does) and enters the log
acceptances[100] = { questId = 100, quest = DBQUESTS[100] }
eventFrame.scripts.OnEvent(eventFrame, "QUEST_ACCEPTED", 100)
runTimers()
chat = {}
slash("list")
check(not chatHas("[pickup] Near Pickup"), "accepted quest is no longer a pickup stop")
check(chatHas("1. [objective] Kobold Stew"), "route advanced to the next stop")

-- objective sweep: stand on the 20 yd spawn -> arrow moves to the 30 yd spawn
local function shownTexts()
    local out = {}
    for _, f in ipairs(frames) do local t = rawget(f, "text"); if t then out[#out + 1] = t end end
    return table.concat(out, " | ")
end
player.x, player.y = 20, 0
arrowFrame.scripts.OnUpdate(arrowFrame, 1)
check(shownTexts():find("| here", 1, true) ~= nil, "standing on the 20 yd spawn shows 'here' (" .. shownTexts() .. ")")
tick()
arrowFrame.scripts.OnUpdate(arrowFrame, 1)
check(shownTexts():find("| 40 yd", 1, true) ~= nil, "after reaching it the arrow moves to the 60 yd spawn, 40 yd away (" .. shownTexts() .. ")")

-- auto reroute: Far Pickup is at 500 yd. Walk next to it with auto on.
slash("auto on")
check(QuestRouteDB.auto == true, "/qr auto on")
player.x, player.y = 495, 0
chat = {}
tick()
check(chatHas("Rerouted to nearby quest: Far Pickup"), "auto-reroute picked the nearby quest")

-- manual mode only hints
slash("auto off")
player.x, player.y = 25, 0
slash("reroute")
player.x, player.y = 495, 0
tick()
local hint
for _, f in ipairs(frames) do
    local t = rawget(f, "text")
    if t and t:find("Nearby:", 1, true) then hint = t end
end
check(hint ~= nil, "manual mode shows a 'Nearby' hint instead of rerouting (" .. tostring(hint) .. ")")

-- pressing Reroute while the hint is up goes to the hinted quest, even when it's filed under another zone
local function currentHint()
    for _, f in ipairs(frames) do
        local t = rawget(f, "text")
        if t and t:find("Nearby:", 1, true) then return t end
    end
end
slash("reroute")
player.x, player.y = 1990, 0
tick()
check((currentHint() or ""):find("Border Pickup", 1, true) ~= nil, "hint names the other-zone quest (" .. tostring(currentHint()) .. ")")
chat = {}
slash("reroute")
check(chatHas("Rerouted to nearby quest: Border Pickup"), "manual Reroute follows the hint (" .. lastChat() .. ")")
chat = {}
slash("list")
check(chatHas("1. [pickup] Border Pickup"), "hinted quest is now the target")
tick()
check((currentHint() or "") == "", "hint cleared once its quest is the target")

-- Reroute with no hint that keeps the same target says so, instead of a bare "Rerouted."
player.x, player.y = 0, 0
slash("reroute")
tick()
check((currentHint() or "") == "", "no hint at the start position")
chat = {}
slash("reroute")
check(chatHas("still the best next stop"), "same-target reroute explains itself (" .. lastChat() .. ")")

-- item-started quest: routed to the mobs that drop the item
chat = {}
slash("list all")
check(not chatHas("(no location) [pickup] Mysterious Note"), "item-started quest is not hidden as 'no location'")
player.x, player.y = 2960, 0
slash("reroute")
chat = {}
slash("list")
check(chatHas("1. [pickup] Mysterious Note") and chatHas("@ Defias Thug"), "item-started quest targets a mob that drops the item")
arrowFrame.scripts.OnUpdate(arrowFrame, 1)
check(shownTexts():find("Loot Bloody Note from Defias Thug (20%)", 1, true) ~= nil, "arrow says what to loot, from whom, and the drop chance (" .. shownTexts() .. ")")
check(shownTexts():find("| 40 yd", 1, true) ~= nil, "arrow prefers the 20% mob at 40 yd over the 2% mob at 10 yd (" .. shownTexts() .. ")")
check(chatHas("@ Defias Thug (20%)"), "/qr list shows the drop chance")
player.x, player.y = 3000, 0
tick()
arrowFrame.scripts.OnUpdate(arrowFrame, 1)
check(shownTexts():find("| 50 yd", 1, true) ~= nil, "reaching one drop spawn sweeps to the next (" .. shownTexts() .. ")")
-- /qr mindrop: hide mobs below the chance; hide the whole stop when none are left
check(QuestRouteDB.minDrop == 0, "mindrop defaults to off")
slash("mindrop 5")
check(QuestRouteDB.minDrop == 5, "/qr mindrop 5 saved")
chat = {}
slash("list all")
check(chatHas("[pickup] Mysterious Note") and not chatHas("(low drop)"), "at 5% the 20% mob keeps the quest on the route")
slash("mindrop 25")
chat = {}
slash("list all")
check(chatHas("(low drop) [pickup] Mysterious Note"), "at 25% every source is filtered: hidden as 'low drop'")
slash("mindrop x")
check(chatHas("Usage: /qr mindrop"), "bad mindrop input shows usage")
chat = {}
slash("help")
check(chatHas("/qr mindrop <pct>") and chatHas("(now 25%, 0 = off)"), "/qr help shows the mindrop setting")
slash("mindrop 0")
chat = {}
slash("list all")
check(not chatHas("(low drop)"), "mindrop 0 turns the filter off")

bags[900] = 1
eventFrame.scripts.OnEvent(eventFrame, "BAG_UPDATE_DELAYED")
runTimers()
chat = {}
slash("list all")
check(chatHas("(in bags) [pickup] Mysterious Note"), "starter item already in bags: hidden as 'in bags'")
bags[900] = nil

-- misc commands don't error
for _, c in ipairs({ "", "", "help", "lock", "lock", "radius 60", "radius x", "lowturnins off", "skipped", "zzz" }) do
    local okc, e = pcall(slash, c)
    check(okc, "/qr " .. c .. " runs (" .. tostring(e) .. ")")
end

print(string.format("\nsmoke: %d failed", failed))
return failed
