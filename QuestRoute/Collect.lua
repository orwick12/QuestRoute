-- QuestRoute: read Questie's live data and turn it into route "stops".
--
-- In:  Questie's quest log (ActiveQuests), Questie's available-quest set (mirrored by hooking its draw/remove calls),
--      Questie's NPC/object database for quest givers and turn-in NPCs.
-- Out: Collect.Gather(filterOpts) -> kept stops, hidden stops (each hidden one has .reason)
--
-- A stop = { key, questId, questName, level, kind = "pickup"|"objective"|"turnin", step, points = {point...} }
-- A point = { x, y, instance, mapId, name }  (world yards; `name` = NPC/object/mob name at that spot)
--
-- Everything Questie-internal is reached through QuestieLoader. If Questie changes and a module is missing,
-- Collect.ok is false and Collect.err says what, so Core can print one clear message.

local _, ns = ...
local Collect = { ok = false, err = nil }
ns.Collect = Collect

local ActiveQuests, AvailableQuests, QuestieDB, ZoneDB, HBD

local available = {} -- [questId] = Quest, mirrored from Questie's draw/remove calls
Collect.available = available
Collect.onAvailableChanged = nil -- set by Core

local function import()
    if not QuestieLoader then return "QuestieLoader not found (is Questie enabled?)" end
    local function get(name)
        local ok, mod = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
        return ok and mod or nil
    end
    ActiveQuests, AvailableQuests = get("ActiveQuests"), get("AvailableQuests")
    QuestieDB, ZoneDB = get("QuestieDB"), get("ZoneDB")
    HBD = LibStub and LibStub("HereBeDragonsQuestie-2.0", true)
    if not (ActiveQuests and ActiveQuests.GetAll) then return "Questie module ActiveQuests missing" end
    if not (AvailableQuests and AvailableQuests.DrawAvailableQuest and AvailableQuests.RemoveQuest) then
        return "Questie module AvailableQuests missing"
    end
    if not (QuestieDB and QuestieDB.GetNPC and QuestieDB.GetObject) then return "Questie module QuestieDB missing" end
    if not (ZoneDB and ZoneDB.GetUiMapIdByAreaId) then return "Questie module ZoneDB missing" end
    if not HBD then return "HereBeDragonsQuestie-2.0 library missing" end
    return nil
end

-- Runs when this file loads (after Questie, because of ## Dependencies), so the hooks catch Questie's first pass.
Collect.err = import()
Collect.ok = Collect.err == nil
Collect.HBD = HBD

if Collect.ok then
    hooksecurefunc(AvailableQuests, "DrawAvailableQuest", function(quest)
        if quest and quest.Id and available[quest.Id] ~= quest then
            available[quest.Id] = quest
            if Collect.onAvailableChanged then Collect.onAvailableChanged() end
        end
    end)
    hooksecurefunc(AvailableQuests, "RemoveQuest", function(questId)
        if available[questId] then
            available[questId] = nil
            if Collect.onAvailableChanged then Collect.onAvailableChanged() end
        end
    end)
end

---Ask Questie to redo its available pass (only used if our mirror is empty at startup).
function Collect.RequestAvailablePass()
    if AvailableQuests and AvailableQuests.CalculateAndDrawAll then AvailableQuests.CalculateAndDrawAll() end
end

------------------------------------------------------------------ coordinates

local pointCache = {} -- "areaId:x:y" -> point without name (false when it can't be converted)

---Questie spawn (areaId, x 0-100, y 0-100) -> world point, or nil (dungeon spawn / unknown map).
local function toPoint(areaId, x, y, name)
    if not x or not y or x < 0 or y < 0 then return nil end -- -1,-1 marks a dungeon spawn
    local key = areaId .. ":" .. x .. ":" .. y
    local base = pointCache[key]
    if base == nil then
        base = false
        local uiMapId = ZoneDB:GetUiMapIdByAreaId(areaId)
        if uiMapId then
            local wx, wy, instance = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, uiMapId)
            if wx and wy then base = { x = wx, y = wy, instance = instance, mapId = uiMapId } end
        end
        pointCache[key] = base
    end
    if not base then return nil end
    return { x = base.x, y = base.y, instance = base.instance, mapId = base.mapId, name = name }
end

local function addSpawns(points, spawns, name)
    if type(spawns) ~= "table" then return end
    for areaId, list in pairs(spawns) do
        for _, s in pairs(list) do
            local p = toPoint(areaId, s[1], s[2], name)
            if p then points[#points + 1] = p end
        end
    end
end

-- NPC/object ids (Questie's Starts/Finisher shape: { NPC = {ids}, GameObject = {ids} }) -> points
local function giverPoints(giver)
    local points = {}
    if type(giver) ~= "table" then return points end
    for _, npcId in pairs(giver.NPC or {}) do
        local npc = QuestieDB:GetNPC(npcId)
        if npc then addSpawns(points, npc.spawns, npc.name) end
    end
    for _, objectId in pairs(giver.GameObject or {}) do
        local obj = QuestieDB:GetObject(objectId)
        if obj then addSpawns(points, obj.spawns, obj.name) end
    end
    return points
end

------------------------------------------------------------------ stops

local function isComplete(quest)
    local c = quest.IsComplete and quest:IsComplete()
    return c == 1 or (c ~= -1 and quest.isComplete == true)
end

local function objectiveStep(obj)
    local text = obj.Description or "Objective"
    if obj.Needed and obj.Needed > 0 then
        text = text .. " " .. (obj.Collected or 0) .. "/" .. obj.Needed
    end
    return text
end

local function objectiveStops(out, quest, list, prefix)
    for index, obj in pairs(list or {}) do
        if type(obj) == "table" and not obj.Completed and obj.spawnList then
            local points = {}
            for _, spawnData in pairs(obj.spawnList) do
                addSpawns(points, spawnData.Spawns, spawnData.Name)
            end
            out[#out + 1] = {
                key = prefix .. quest.Id .. ":" .. index, questId = quest.Id, questName = quest.name,
                level = quest.level, kind = "objective", step = objectiveStep(obj), points = points,
            }
        end
    end
end

local function inLog(questId)
    return ActiveQuests.Get and ActiveQuests.Get(questId) ~= nil
end

-- Questie removes some quests from its available set without calling RemoveQuest (accepted, completed, hidden),
-- so re-check the mirrored set against Questie's own state every time.
local function stillAvailable(questId)
    if inLog(questId) then return false end
    local char = Questie and Questie.db and Questie.db.char
    if char and ((char.complete and char.complete[questId]) or (char.hidden and char.hidden[questId])) then
        return false
    end
    return true
end

---All candidate stops before filtering. Each has `points` (possibly empty).
function Collect.AllStops()
    local out = {}
    for questId, acceptance in pairs(ActiveQuests.GetAll()) do
        local quest = acceptance.quest
        if quest and quest.Id then
            if isComplete(quest) then
                out[#out + 1] = {
                    key = "t:" .. questId, questId = questId, questName = quest.name, level = quest.level,
                    kind = "turnin", step = "Turn in", points = giverPoints(quest.Finisher),
                }
            else
                objectiveStops(out, quest, quest.Objectives, "o:")
                objectiveStops(out, quest, quest.SpecialObjectives, "s:")
            end
        end
    end
    for questId, quest in pairs(available) do
        if stillAvailable(questId) then
            out[#out + 1] = {
                key = "p:" .. questId, questId = questId, questName = quest.name, level = quest.level,
                kind = "pickup", step = "Pick up", points = giverPoints(quest.Starts),
            }
        else
            available[questId] = nil
        end
    end
    return out
end

---Kept stops and hidden stops. Hidden ones carry .reason ("skipped", "too low", "too high", "no location").
function Collect.Gather(filterOpts)
    local kept, hidden = {}, {}
    for _, stop in ipairs(Collect.AllStops()) do
        local reason = ns.Router.FilterReason(stop, filterOpts)
        if not reason and #stop.points == 0 then reason = "no location" end
        if reason then
            stop.reason = reason
            hidden[#hidden + 1] = stop
        else
            kept[#kept + 1] = stop
        end
    end
    return kept, hidden
end

---Quest name for an id (log, available, or database).
function Collect.QuestName(questId)
    local acc = ActiveQuests.Get and ActiveQuests.Get(questId)
    if acc and acc.quest then return acc.quest.name end
    if available[questId] then return available[questId].name end
    local q = QuestieDB.GetQuest and QuestieDB.GetQuest(questId)
    return q and q.name or nil
end

---Quests you could skip by name: everything in the log or available, as { [questId] = name }.
function Collect.KnownQuests()
    local out = {}
    for questId, acc in pairs(ActiveQuests.GetAll()) do
        if acc.quest then out[questId] = acc.quest.name end
    end
    for questId, quest in pairs(available) do out[questId] = quest.name end
    return out
end
