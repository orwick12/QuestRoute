# QuestRoute — a quest-routing arrow addon for WoW Forever, built on Questie

## Context
Brian plays World of Warcraft Forever (client at `C:\Program Files (x86)\World of Warcraft\_forever_`, Interface **16001**, flavor `wowf`) with Questie v12.6.5 + QuestieDB installed. He wants an addon that:
- picks a good order to do quests in (a route),
- shows **one arrow** pointing where to walk, plus a label saying which quest/step it's heading to,
- can **reroute** when near another quest — manual by default (button / slash command), with an "auto-reroute" setting.

Decisions confirmed with Brian:
- Route includes **quest log objectives + turn-ins + available pickups** (the Questie "!" givers).
- **Current zone first**; when nothing is left in the zone, go to nearest stop elsewhere on the continent.
- Reroute is **manual by default**; checkbox / `/qr auto` enables automatic proximity rerouting.
- **No Claude/Haiku.** WoW addons run in a sandbox with no network or process access, so an LLM can't be called in-game anyway. Routing is a small traveling-salesman problem; greedy nearest-neighbor + 2-opt solves it instantly in Lua.

**Source of record:** Questie's runtime data (its baked QuestieDB + its live quest-log state), read in-game. We do not export or copy the DB.

## What we reuse from Questie (verified on disk)
All paths under `...\_forever_\Interface\AddOns\Questie\`.
- `Public\RegisterOnReady.lua` — `Questie.API.RegisterOnReady(cb)`: start once Questie's data is loaded.
- `Public\RegisterForQuestUpdates.lua` — `Questie.API.RegisterForQuestUpdates(cb(questId, objIndex, reason))`: our trigger to advance/recompute.
- `Modules\Libs\QuestieLoader.lua` — global `QuestieLoader:ImportModule(name)` to reach modules below.
- `Modules\Quest\ActiveQuests.lua` — `ActiveQuests.GetAll()` → quest-log `Quest` objects. Each has `Objectives[i].spawnList[*].Spawns` (`{[areaId] = {{x,y},...}}`, 0–100 coords), `.Needed/.Collected/.Completed`, `SpecialObjectives`, `Finisher` (`{NPC={..}, GameObject={..}}`), `:IsComplete()` / `.isComplete`.
- `Modules\Quest\AvailableQuests\AvailableQuests.lua` — the available set is a private local, but **every** draw path calls the table field `AvailableQuests.DrawAvailableQuest(quest)` and removal goes through `AvailableQuests.RemoveQuest(questId)`. We `hooksecurefunc` both to mirror the set. This applies Questie's own level/faction/prereq filters for free.
- `Modules\Libs\DistanceUtils.lua` — pattern for spawn → world coords: `ZoneDB:GetUiMapIdByAreaId(areaId)` then `HBD:GetWorldCoordinatesFromZone(x/100, y/100, uiMapId)`; skips `-1,-1` dungeon spawns. HBD is `LibStub("HereBeDragonsQuestie-2.0")` (world coords are in **yards**, instance id tells continent).
- `QuestieDB:GetNPC(id)` / `QuestieDB:GetObject(id)` → `.spawns`, `.name`, `.friendly` for starters/finishers.

These are Questie internals (except `Questie.API.*`), so a Questie update could break them. All imports are wrapped so a missing module prints one clear chat error instead of Lua spam.

## Addon layout
Source in `C:\Users\Brian\projects\questaddon\QuestRoute\`; installed by a **directory junction** `...\AddOns\QuestRoute → projects\questaddon\QuestRoute` (so edits + `/reload` are live; I'll confirm before creating it since it writes into Program Files).

```
QuestRoute/
  QuestRoute.toc      Interface 16001, ## Dependencies: Questie, ## SavedVariablesPerCharacter: QuestRouteDB
  Router.lua          PURE Lua, no WoW API — the route algorithm (unit-tested offline)
  Collect.lua         Questie → list of "stops"
  Arrow.lua           arrow frame, label, buttons, OnUpdate
  Core.lua            init, events, settings, slash commands
tests/
  test_router.lua     offline tests for Router.lua
  run_tests.py        runs the Lua tests under LuaJIT via the `lupa` package (uv run --with lupa)
```

## How it works

**1. Collect stops (`Collect.lua`).** A *stop* = `{questId, kind = "pickup"|"objective"|"turnin", label, points = {{x,y,instance,areaId},...}}`.
- Quest in log, complete → one `turnin` stop, points = finisher NPC/object spawns.
- Quest in log, incomplete → one `objective` stop per unfinished objective, points = all its spawns (e.g. every boar spawn). Label e.g. "Kill Kobold Vermin 3/8 — Kobold Stew".
- Available quest (from the hook mirror) → `pickup` stop, points = starter NPC/object spawns (item-started quests skipped in v1).
- Dropped: dungeon spawns (`-1,-1`), spawns on a different instance/continent, and anything filtered out by **Skipping** below.

**1b. Skipping quests (added at Brian's request).** Applied in `Collect.lua` before routing; affects only the route, never your quest log or Questie's map.
- **Specific quests — saved permanently** in `QuestRouteDB.skipped[questId] = questName` (survives `/reload` and logout; per character).
  - **Skip** button on the arrow → skips the quest currently targeted, then recomputes.
  - `/qr skip <questId>` or `/qr skip <part of name>` (matches quests in log/available; asks you to be specific if several match).
  - `/qr skipped` lists skipped quests with ids; `/qr unskip <questId|name>` / `/qr unskip all` restores them.
- **Level range** using `quest.level` vs `UnitLevel("player")`:
  - `/qr minlevel <n>` → skip quests more than n levels **below** you (default 5; 0 = off). Turn-ins for quests already in your log are **still routed** even if low, since they're free XP — `/qr lowturnins off` to drop those too.
  - `/qr maxlevel <n>` → skip quests more than n levels **above** you (default 3; 0 = off).
  - Re-evaluated on `PLAYER_LEVEL_UP`, so a quest that was "too high" joins the route when you ding.
- `/qr list` marks why something is hidden when you run `/qr list all` (skipped / too low / too high), so a filter that hides too much is easy to spot.

**2. Route (`Router.lua`).** Input: player position + stops. Distance from a point to a stop = min over its points.
- Zone-first: stops whose `areaId` = current zone get used first; other-zone stops only after current-zone ones run out.
- Greedy nearest-neighbor from player position, then 2-opt passes to remove crossings (cap ~30 stops; cheap).
- Output: ordered stops, each with the concrete point chosen.

**3. Arrow (`Arrow.lua`).** Small draggable frame:
- Arrow texture rotated with `texture:SetRotation(atan2(dx,dy) - GetPlayerFacing())`, player world pos from `HBD:GetPlayerWorldPosition()`. Updates ~20×/sec (cheap trig only, no rerouting in OnUpdate).
- Line 1: quest name. Line 2: step ("Pick up from Marshal McBride" / "Kill Kobold Vermin 3/8" / "Turn in to …"). Line 3: distance in yards.
- Buttons: **Reroute**, **Skip** (permanently skips this quest — see 1b; undo with `/qr unskip`). Hint line in manual mode: "Nearby: <quest> — press Reroute".
- Arriving at an objective point that isn't done yet → retarget to the next-nearest spawn of the same objective (so you sweep the camp).

**4. When the route changes (`Core.lua`).**
- **Always (progression, not "rerouting"):** current target finished — quest accepted, objective completed, or turned in (via `RegisterForQuestUpdates` + `QUEST_ACCEPTED` / `QUEST_TURNED_IN`) → drop it, recompute, point at next stop. Debounced ~0.5s.
- **Manual reroute:** Reroute button or `/qr reroute`.
- **Auto reroute (off by default):** once per second, if another stop is within N yards (default 40) and closer than the target → recompute.
- Slash: `/qr` (show/hide), `/qr reroute`, `/qr skip [id|name]`, `/qr unskip <id|name|all>`, `/qr skipped`, `/qr minlevel <n>`, `/qr maxlevel <n>`, `/qr lowturnins on|off`, `/qr auto on|off`, `/qr radius <yd>`, `/qr lock`, `/qr list [all]` (prints the next ~10 stops in chat so the route can be checked), `/qr help`.
- `QuestRouteDB` (per character, `SavedVariablesPerCharacter`) saves: frame position, lock, auto-reroute, radius, skipped quests, min/max level, low-turn-ins flag.

## Build order
1. `Router.lua` + offline tests (red → green).
2. `Collect.lua` + `Core.lua` with `/qr list` only — check in-game that the stop list matches the Questie map.
3. `Arrow.lua` frame + rotation.
4. Reroute/auto + skip list + level filters + settings persistence. The filter logic (skip list, level window, low-turn-in exception) lives in a pure function in `Router.lua` so it's unit-tested offline too.
5. Write this plan to `questaddon/docs/plan.md`; offer `git init`.

## Verification
- **Offline (I run these):** `uv run --with lupa python tests/run_tests.py` runs `test_router.lua` under LuaJIT (5.1-compatible, like WoW): empty input, single stop, nearest-first order, 2-opt shortens a crossed route, zone-first preference, multi-point stops pick the nearest point; filters: skipped quest removed, too-low / too-high removed at the boundaries (exactly n levels kept, n+1 dropped), 0 disables a filter, low turn-in kept unless `lowturnins off`. Also a syntax check of every `.lua` file (load each without running it).
- **In-game (Brian runs; I can't launch WoW):** `/reload`, then checklist: frame appears and no Lua errors (`/console scriptErrors 1`); `/qr list` matches Questie's map icons; arrow points correctly as you turn and walk; distance goes down as you approach; accepting/completing/turning in moves to the next stop; Reroute + Skip work and skips survive `/reload`; `/qr maxlevel 1` hides higher quests and `/qr list all` says why; auto mode reroutes near another quest; settings survive `/reload`.
- Known gaps to state up front: no pathfinding (straight-line arrow; ignores cliffs/water), no flight paths, item-started and dungeon quests skipped in v1, relies on Questie internals that could change.
