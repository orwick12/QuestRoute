-- QuestRoute: focus mode. A fixed, hand-written route for one quest chain (the Cozy Sleeping Bag) that replaces
-- the normal route until the chain is done.
--
-- In:  Focus.Steps(faction) -> ordered steps for "Alliance" or "Horde" (same length and order for both)
--      Focus.Current(steps, check) -> index of the step to do now (#steps + 1 = chain finished)
--        check = { inLog(questId), done(questId), reached(stepId) }, supplied by Core (WoW/Questie lookups)
-- Out: step = { id, kind = "pickup"|"turnin"|"travel", title, text, zone, mapId, x, y, tip, via, doneIf }
--
-- How "where am I in the chain" works: a step counts as done when any of its doneIf checks is true
-- ({"log", id} = quest in your log, {"done", id} = quest turned in). "via" steps are travel waypoints with no quest
-- behind them; they count as done once you've reached them. The current step is the one after the LAST done step,
-- so later evidence wins: if Wet Job is in your log, everything before it is treated as done.
--
-- PURE LUA (no WoW API calls), so it can be tested offline.
--
-- Data source: quest ids, object names and coordinates are from the installed QuestieDB (QuestieDB_Forever.toc,
-- read 2026-11-13). They match the Wowhead / fan guides to within 0.2. The two travel waypoints (the Stonetalon path
-- and the Hillsbrad cart) aren't in QuestieDB; those come from the guides.

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

local NOTE = "...and that note you found"

-- Shown with every step: the arrow is a straight line and knows nothing about the way there.
Focus.ARROW_NOTE = "The arrow points in a straight line. It doesn't know about boats, zeppelins, paths or cliffs, "
    .. "so when the notes say take a boat or a path, follow the notes, not the arrow."

local function step(id, kind, title, text, where, doneIf, notes)
    return { id = id, kind = kind, title = title, text = text, zone = where.zone, mapId = where.mapId,
        x = where.x, y = where.y, doneIf = doneIf, notes = notes or {}, via = kind == "travel" or nil }
end
local function inLogOrDone(questId) return { { "log", questId }, { "done", questId } } end

---The chain for one faction. The quest steps are the same for both; Alliance starts in Westfall and hands the note in
---in the Barrens, Horde does the reverse, and the travel notes differ.
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

    local toNoteTurnin = horde and {
        "Guide: take the zeppelin from outside Orgrimmar to Grom'gol (Stranglethorn Vale). The arrow will point "
            .. "across the sea instead of at the zeppelin tower.",
        "Suggested: from Grom'gol run north through Stranglethorn and Duskwood into Westfall.",
    } or {
        "Guide: take the boat from Booty Bay to Ratchet. The arrow will point across the sea instead of at Booty Bay.",
        "Suggested: from Ratchet head west to the Crossroads, then south down the road to Camp Taurajo.",
    }
    local toStonetalon = horde and {
        "Suggested: get back to Kalimdor (zeppelin Grom'gol -> Orgrimmar). The arrow points across the sea, not at "
            .. "the zeppelin.",
    } or {
        "Suggested: Sun Rock Retreat is a Horde town; the path starts north-east of it, so you don't need to go in.",
    }
    local toLochModan = horde and {
        "Suggested: zeppelin Orgrimmar -> Undercity (or Grom'gol), then travel to the Wetlands side of Loch Modan. "
            .. "Loch Modan is Alliance territory. The arrow points across the sea, not at the zeppelin.",
    } or {
        "Suggested: boat Auberdine (Darkshore) -> Menethil Harbor, then east through the Wetlands. The arrow points "
            .. "across the sea, not at the boat.",
    }

    return {
        step("note", "pickup", NOTE, "Click the Burned-Out Remains", from, inLogOrDone(note), {
            "Guide: the Burned-Out Remains are in " .. fromSpot .. ".",
            "Guide: the chain needs level 14. The travel legs are safer in your low 20s.",
        }),
        step("note-in", "turnin", NOTE, "Click the Burned-Out Remains", to, { { "done", note } },
            { toNoteTurnin[1], toNoteTurnin[2], "Guide: hand it in at the Burned-Out Remains in " .. toSpot .. "." }),
        step("stepping", "pickup", "Stepping Stones", "Take it from the Nailed Plank", plank, inLogOrDone(Q.stepping), {
            "Guide: the note is nailed to a plank right next to the remains.",
            "Guide: it gives a 12-slot bag, Simple Wood and Flint and Tinder. Keep the wood and flint for the "
                .. "optional Rekindle quest.",
        }),
        step("path", "travel", "Stepping Stones", "Leave the road here, take the path west", STONETALON_PATH, nil, {
            toStonetalon[1],
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
                toLochModan[1],
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
end

function Focus.StepDone(s, check)
    if s.via then return check.reached(s.id) and true or false end
    for _, c in ipairs(s.doneIf or {}) do
        if (c[1] == "log" and check.inLog(c[2])) or (c[1] == "done" and check.done(c[2])) then return true end
    end
    return false
end

---Index of the step to do now: one past the last done step. #steps + 1 means the chain is finished.
function Focus.Current(steps, check)
    local last = 0
    for i, s in ipairs(steps) do
        if Focus.StepDone(s, check) then last = i end
    end
    return last + 1
end

---"Stonetalon Mountains 40.8, 52.6" for the frame and chat.
function Focus.Where(s) return string.format("%s %.1f, %.1f", s.zone, s.x, s.y) end

return Focus
