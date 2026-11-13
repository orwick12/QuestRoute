-- QuestRoute: focus mode. A fixed, hand-written route for one quest chain (the Cozy Sleeping Bag) that replaces
-- the normal route until the chain is done.
--
-- In:  Focus.Steps(faction) -> ordered steps for "Alliance" or "Horde" (16 and 17 steps: the boats and zeppelins
--        differ, the quest steps are the same)
--      Focus.Current(steps, check) -> index of the step to do now (#steps + 1 = chain finished)
--        check = { inLog(questId), done(questId), reached(stepId), across(index) }, supplied by Core
-- Out: step = { id, kind = "pickup"|"turnin"|"travel"|"transport", title, text, zone, mapId, x, y, notes, doneIf,
--               via (travel waypoint), transport (boat/zeppelin) }
--
-- How "where am I in the chain" works: a step counts as done when any of its doneIf checks is true
-- ({"log", id} = quest in your log, {"done", id} = quest turned in). "via" steps are travel waypoints with no quest
-- behind them; they count as done once you've reached them. The current step is the one after the LAST done step,
-- so later evidence wins: if Wet Job is in your log, everything before it is treated as done.
-- Boat/zeppelin ("transport") steps are never evidence. When one comes up it is passed over as soon as you're on the
-- continent of the step after it (check.across), however you got there.
--
-- PURE LUA (no WoW API calls), so it can be tested offline.
--
-- Data source: quest ids, object names and coordinates are from the installed QuestieDB (QuestieDB_Forever.toc,
-- read 2026-11-13). They match the Wowhead / fan guides to within 0.2. The two travel waypoints (the Stonetalon path
-- and the Hillsbrad cart) aren't in QuestieDB; those come from the guides. Boat and zeppelin stops are where the
-- shipmaster / zeppelin master NPC stands in QuestieDB. Which zeppelin master flies where isn't in the DB; that part
-- is from memory of the classic game.

local _, ns = ...
local Focus = {}
ns.Focus = Focus

local Q = {
    noteAlliance = 79008, -- "...and that note you found": starts in Westfall, turned in in the Barrens
    noteHorde = 79007,    -- the same quest the other way round
    stepping = 79192,
    scramble = 79980,
    wetJob = 79974,
    eaglesFist = 79975,
    place = 79976,
}
Focus.QUESTS = Q
Focus.NAME = "Cozy Sleeping Bag"
Focus.MIN_LEVEL = 14

local function at(zone, mapId, x, y) return { zone = zone, mapId = mapId, x = x, y = y } end
-- uiMapIds (classic): Westfall 1436, The Barrens 1413, Stonetalon 1442, Loch Modan 1432, Hillsbrad 1424, Arathi 1417
local WESTFALL_REMAINS = at("Westfall", 1436, 37.41, 50.70)       -- object 415107
local WESTFALL_PLANK = at("Westfall", 1436, 37.36, 50.77)         -- object 424010
local BARRENS_REMAINS = at("The Barrens", 1413, 46.36, 73.90)     -- object 415106
local BARRENS_PLANK = at("The Barrens", 1413, 46.39, 73.82)       -- object 417072
local STONETALON_PATH = at("Stonetalon Mountains", 1442, 50.9, 52.3) -- guides: path leaves the road here
local POCKET_LITTER = at("Stonetalon Mountains", 1442, 40.75, 52.57) -- object 424005
local MOUND_OF_DIRT = at("Stonetalon Mountains", 1442, 39.62, 49.82) -- object 424012
local CARVED_FIGURINE = at("Loch Modan", 1432, 49.43, 12.90)      -- object 424007
local HILLSBRAD_CART = at("Hillsbrad Foothills", 1424, 87.3, 49.6) -- guides: cart below Thoradin's Wall
local MESSENGER_BAG = at("Arathi Highlands", 1417, 22.48, 24.14)  -- object 406918
local SATCHEL = at("Arathi Highlands", 1417, 22.48, 24.15)        -- object 424006
-- Boats and zeppelins: the NPC who stands at the dock / tower platform. Durotar 1411, Stranglethorn Vale 1434.
local BOAT_BOOTY_BAY = at("Stranglethorn Vale", 1434, 26.08, 73.35) -- npc 9559 Grizzlowe <Shipmaster>, to Ratchet
local BOAT_RATCHET = at("The Barrens", 1413, 63.54, 38.61)          -- npc 9558 Grimble <Shipmaster>, to Booty Bay
local ZEP_ORG_GROMGOL = at("Durotar", 1411, 50.69, 12.89)   -- npc 12136 Snurk Bucksquick <Zeppelin Master>
local ZEP_ORG_UNDERCITY = at("Durotar", 1411, 50.82, 13.54) -- npc 9564 Frezza <Zeppelin Master>
local ZEP_GROMGOL_ORG = at("Stranglethorn Vale", 1434, 31.43, 29.91) -- npc 3149 Nez'raz <Zeppelin Master>

local NOTE = "...and that note you found"

-- Shown with every step: the arrow is a straight line and knows nothing about the way there.
Focus.ARROW_NOTE = "The arrow points in a straight line. It doesn't know about paths or cliffs, and on a new "
    .. "continent it points at the boat or zeppelin first. When the notes say stay on a path, follow the notes."

local function step(id, kind, title, text, where, doneIf, notes)
    return { id = id, kind = kind, title = title, text = text, zone = where.zone, mapId = where.mapId,
        x = where.x, y = where.y, doneIf = doneIf, notes = notes or {}, via = kind == "travel" or nil,
        transport = kind == "transport" or nil }
end
local function inLogOrDone(questId) return { { "log", questId }, { "done", questId } } end
local function transport(id, title, text, where, notes) return step(id, "transport", title, text, where, nil, notes) end

---The chain for one faction. The quest steps are the same for both; Alliance starts in Westfall and hands the note in
---in the Barrens, Horde does the reverse, and the boats and zeppelins differ.
---Notes marked "Guide:" come from the Wowhead / fan guides. Notes marked "Suggested:" are general WoW travel advice
---the guides don't give; treat them as a starting point.
function Focus.Steps(faction)
    local horde = faction == "Horde"
    local note = horde and Q.noteHorde or Q.noteAlliance
    local from = horde and BARRENS_REMAINS or WESTFALL_REMAINS
    local to = horde and WESTFALL_REMAINS or BARRENS_REMAINS
    local plank = horde and WESTFALL_PLANK or BARRENS_PLANK
    local fromSpot = horde and "the burnt tower on the Field of Giants, south of Camp Taurajo"
        or "the wrecked cart at Alexston Farmstead"
    local toSpot = horde and "the wrecked cart at Alexston Farmstead"
        or "the burnt tower on the Field of Giants, south of Camp Taurajo"

    local list = {
        step("note", "pickup", NOTE, "Click the Burned-Out Remains", from, inLogOrDone(note), {
            "Guide: the Burned-Out Remains are in " .. fromSpot .. ".",
            "Guide: the chain needs level 14. The travel legs are safer in your low 20s.",
        }),
        step("note-in", "turnin", NOTE, "Click the Burned-Out Remains", to, { { "done", note } }, {
            horde and "Suggested: from Grom'gol run north through Stranglethorn and Duskwood into Westfall."
                or "Suggested: from Ratchet head west to the Crossroads, then south down the road to Camp Taurajo.",
            "Guide: hand it in at the Burned-Out Remains in " .. toSpot .. ".",
        }),
        step("stepping", "pickup", "Stepping Stones", "Take it from the Nailed Plank", plank, inLogOrDone(Q.stepping), {
            "Guide: the note is nailed to a plank right next to the remains.",
            "Guide: it gives a 12-slot bag, Simple Wood and Flint and Tinder. Keep the wood and flint for the "
                .. "optional Rekindle quest.",
        }),
        step("path", "travel", "Stepping Stones", "Leave the road here, take the path west", STONETALON_PATH, nil, {
            horde and "Suggested: from Orgrimmar head west through the Barrens into Stonetalon Mountains."
                or "Suggested: Sun Rock Retreat is a Horde town; the path starts north-east of it, so you don't need "
                .. "to go in.",
            "Guide: the path (Webwinder Path) leaves the road north-east of Sun Rock Retreat. Follow it to an "
                .. "abandoned camp. Stay on the path; the arrow would take you straight over the hills.",
        }),
        step("litter", "turnin", "Stepping Stones", "Click the Pocket Litter on a box", POCKET_LITTER,
            { { "done", Q.stepping } }, {
                "Guide: the Pocket Litter is on top of a box by the tent in the abandoned camp.",
                "Guide (optional): the campfire in the middle of the camp starts Rekindle. Light it with Simple Wood "
                    .. "and Flint and Tinder (you get the flint back). Skipping it doesn't block the chain.",
            }),
        step("scramble", "pickup", "Scramble", "Accept it from the Pocket Litter", POCKET_LITTER,
            inLogOrDone(Q.scramble), { "Guide: the Pocket Litter both finishes Stepping Stones and starts Scramble." }),
        step("mound", "turnin", "Scramble", "Climb the hill north, jump across to the Mound of Dirt", MOUND_OF_DIRT,
            { { "done", Q.scramble } }, {
                "Guide: walk about a hundred paces due north of the camp, climb the hill, and jump across the gap to "
                    .. "the Mound of Dirt.",
                "Guide: Scramble rewards a choice of Silver Star, Moonsight Rifle or Precision Bow, plus Student Fodder.",
            }),
        step("wetjob", "pickup", "Wet Job", "Accept it from the Mound of Dirt", MOUND_OF_DIRT, inLogOrDone(Q.wetJob),
            { "Guide: the Mound of Dirt both finishes Scramble and starts Wet Job." }),
        step("figurine", "turnin", "Wet Job", "Drop onto the carved heads, click the Carved Figurine", CARVED_FIGURINE,
            { { "done", Q.wetJob } }, {
                horde and "Suggested: from Undercity go south through Silverpine, Hillsbrad and Arathi into the "
                    .. "Wetlands, then through Dun Algaz into Loch Modan. Loch Modan is Alliance territory."
                    or "Suggested: from Booty Bay, fly north if you have the flight paths (Ironforge or Thelsamar). "
                    .. "The dam is at the north end of Loch Modan.",
                "Guide: at the Stonewrought Dam, walk out along the dam, face north (toward the Wetlands) and drop "
                    .. "onto the big carved dwarf heads. The Carved Figurine is on them.",
            }),
        step("eagle", "pickup", "Eagle's Fist", "Accept it from the Carved Figurine", CARVED_FIGURINE,
            inLogOrDone(Q.eaglesFist), { "Guide: the Carved Figurine both finishes Wet Job and starts Eagle's Fist." }),
        step("cart", "travel", "Eagle's Fist", "Jump on the cart, climb into Thoradin's Wall", HILLSBRAD_CART, nil, {
            "Guide: the supply cart is on the Hillsbrad side of Thoradin's Wall, south-east of Durnholde Keep.",
            "Guide: jump on the cart, then climb up into the wall.",
        }),
        step("bag", "turnin", "Eagle's Fist", "Through the room: the Messenger Bag hangs to the right", MESSENGER_BAG,
            { { "done", Q.eaglesFist } }, {
                "Guide: go through the room inside the wall and look outside to the right. The Messenger Bag hangs "
                    .. "there (it's on the Arathi Highlands map).",
            }),
        step("place", "pickup", "This Must Be The Place", "Accept it from the Messenger Bag", MESSENGER_BAG,
            inLogOrDone(Q.place), { "Guide: the Messenger Bag both finishes Eagle's Fist and starts This Must Be The Place." }),
        step("satchel", "turnin", "This Must Be The Place", "Click the Hastily Rolled-Up Satchel below the bag", SATCHEL,
            { { "done", Q.place } }, {
                "Guide: the Hastily Rolled-Up Satchel lies just below the Messenger Bag.",
                "Guide: it rewards the Cozy Sleeping Bag and Student Fodder. Resting in the bag gives +1% XP per "
                    .. "minute up to +3% for two hours; it has a one-hour cooldown.",
            }),
    }

    -- Boats and zeppelins go right before the first step on the other continent.
    local function before(id, t)
        for i, st in ipairs(list) do
            if st.id == id then
                table.insert(list, i, t)
                return
            end
        end
    end
    local SKIP = "Skipped automatically once you're on the other continent, however you got there."
    if horde then
        before("note-in", transport("zep-grom", "Zeppelin to Grom'gol", "Snurk Bucksquick: zeppelin to Grom'gol",
            ZEP_ORG_GROMGOL, {
                "Guide: take the zeppelin from the tower outside Orgrimmar to Grom'gol (Stranglethorn Vale).",
                "Data: the arrow points at Snurk Bucksquick <Zeppelin Master> (QuestieDB). Two zeppelins leave this "
                    .. "tower; check the master's destination before you board.",
                SKIP,
            }))
        before("path", transport("zep-org", "Zeppelin to Orgrimmar", "Nez'raz: zeppelin to Orgrimmar",
            ZEP_GROMGOL_ORG, {
                "Suggested: back to Kalimdor on the Grom'gol zeppelin to Orgrimmar.",
                "Data: the arrow points at Nez'raz <Zeppelin Master> at Grom'gol (QuestieDB). Two zeppelins leave "
                    .. "Grom'gol; check the master's destination before you board.",
                SKIP,
            }))
        before("figurine", transport("zep-uc", "Zeppelin to Undercity", "Frezza: zeppelin to Undercity",
            ZEP_ORG_UNDERCITY, {
                "Suggested: zeppelin from Orgrimmar to Undercity, then south to Loch Modan.",
                "Data: the arrow points at Frezza <Zeppelin Master> (QuestieDB). Check the master's destination "
                    .. "before you board.",
                SKIP,
            }))
    else
        before("note-in", transport("boat-ratchet", "Boat to Ratchet", "Grizzlowe: boat to Ratchet", BOAT_BOOTY_BAY, {
            "Guide: take the boat from Booty Bay to Ratchet.",
            "Data: the arrow points at Grizzlowe <Shipmaster> on the Booty Bay dock (QuestieDB).",
            "Suggested: from Westfall, go south through Stranglethorn Vale to Booty Bay.",
            SKIP,
        }))
        before("figurine", transport("boat-bb", "Boat to Booty Bay", "Grimble: boat to Booty Bay", BOAT_RATCHET, {
            "Suggested: boat from Ratchet back to Booty Bay. (Auberdine -> Menethil Harbor also works, but "
                .. "QuestieDB has no position for that dock, so the arrow can't point at it.)",
            "Data: the arrow points at Grimble <Shipmaster> on the Ratchet dock (QuestieDB).",
            SKIP,
        }))
    end
    return list
end

function Focus.StepDone(s, check)
    if s.transport then return false end -- never evidence: being on a continent says nothing about the chain
    if s.via then return check.reached(s.id) and true or false end
    for _, c in ipairs(s.doneIf or {}) do
        if (c[1] == "log" and check.inLog(c[2])) or (c[1] == "done" and check.done(c[2])) then return true end
    end
    return false
end

---Index of the step to do now: one past the last done step, then past any boat/zeppelin you no longer need (you're
---already on the continent of the step after it). #steps + 1 means the chain is finished.
function Focus.Current(steps, check)
    local last = 0
    for i, s in ipairs(steps) do
        if Focus.StepDone(s, check) then last = i end
    end
    local i = last + 1
    while steps[i] and steps[i].transport and check.across and check.across(i) do i = i + 1 end
    return i
end

---Index of the first non-transport step after `i` (the step a boat/zeppelin takes you towards), or nil.
function Focus.NextStop(steps, i)
    for j = i + 1, #steps do
        if not steps[j].transport then return j end
    end
end

---"Stonetalon Mountains 40.8, 52.6" for the frame and chat.
function Focus.Where(s) return string.format("%s %.1f, %.1f", s.zone, s.x, s.y) end

return Focus
