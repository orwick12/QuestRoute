# QuestRoute

A World of Warcraft addon for **WoW Forever** that plans the order to do your quests in and shows one arrow pointing at the next stop.

It reads [Questie](https://github.com/Questie/Questie)'s data (your quest log, the "!" quests available near you, mob and NPC spawn points), so whatever Questie shows on your map is what gets routed. No setup, no imports.

```
        ▲
 [10] Kobold Stew
 Kill Kobold Vermin 3/8 (Kobold Vermin)
        142 yd
 Nearby: Wolves Across the Border — press Reroute
 [ Reroute ]          [ Skip ]
```

## What it does

- **Routes three kinds of stops:** quest pickups ("!" givers), quest objectives (kill/collect spots), and turn-ins.
- **Current zone first**, then the nearest stop elsewhere on the continent. The order is a nearest-neighbour pass plus a 2-opt cleanup, so it doesn't zig-zag.
- **Sweeps camps:** when you reach an objective spot that isn't finished yet, the arrow moves to the next nearest spawn of the same mob or object.
- **Moves on by itself** when you accept a quest, finish an objective, or turn in. Progress like 3/8 → 4/8 only updates the text and never changes the route.
- **Nearby hint:** if another quest is within 40 yd and closer than your target, the frame says so. Press **Reroute** to go there. With `/qr auto on` it switches without asking.
- **Skips:** the **Skip** button drops the current quest from the route permanently, for this character, until you `/qr unskip` it. It doesn't touch your quest log or Questie.
- **Level filters:** quests more than 5 levels below you or 3 above are left out by default. Turn-ins for quests already in your log stay in even when they're low, because the XP is free.

## Install

1. Install **Questie** first. QuestRoute won't load without it.
2. Download **`QuestRoute.zip`** from the [latest release](../../releases/latest).
3. Unzip it into your AddOns folder so you end up with:
   ```
   World of Warcraft\_forever_\Interface\AddOns\QuestRoute\QuestRoute.toc
   ```
4. Start the game (or `/reload`) and make sure QuestRoute is ticked in the AddOns list on the character screen.

If you use the green **Code → Download ZIP** button instead, copy only the inner `QuestRoute` folder into AddOns, not the whole `QuestRoute-main` folder.

## Commands

| Command | What it does |
|---|---|
| `/qr` | Show or hide the arrow |
| `/qr reroute` | Same as the Reroute button: go to the nearby quest if the hint is showing, otherwise re-plan from where you stand |
| `/qr skip [id or name]` | Skip the current quest, or one by quest id or part of its name |
| `/qr unskip <id, name or all>` | Undo a skip |
| `/qr skipped` | List skipped quests |
| `/qr minlevel <n>` | Leave out quests more than *n* levels below you (default 5, 0 = off) |
| `/qr maxlevel <n>` | Leave out quests more than *n* levels above you (default 3, 0 = off) |
| `/qr lowturnins on\|off` | Keep turn-ins of low quests in the route (default on) |
| `/qr auto on\|off` | Switch to nearby quests automatically (default off) |
| `/qr radius <yards>` | How close counts as "nearby" (default 40) |
| `/qr lock` | Lock or unlock the frame. Drag it to move it while unlocked |
| `/qr list [all]` | Print the next 10 stops in chat. `all` also lists hidden stops and why they're hidden |
| `/qr help` | Show all commands with your current settings |

Settings and skips are saved per character.

## Limits

- **Straight-line arrow.** No pathfinding: it points through mountains and across water, and it doesn't know about flight paths.
- **Not routed yet:** quests started from an item, and quests whose spots are inside dungeons.
- **Inside instances** the arrow hides and says "position unavailable here", because the game gives no position there.
- **Zone edges, cities and caves:** "current zone first" goes by what zone the game says you're in, which doesn't always match how Questie files a nearby spawn. If the route skips something right next to you, the Nearby hint plus **Reroute** will take you there.
- **Built against Questie 12.6.5.** It reads some Questie internals beyond its public API, so a big Questie update could break it. If that happens it prints one "QuestRoute: Disabled: ..." line in chat instead of throwing errors.

## For developers

The routing (`QuestRoute/Router.lua`) is plain Lua with no WoW API calls, so it can be tested offline. A smoke test loads the real addon files against a stubbed WoW API and a fake Questie:

```
uv run --no-project --with lupa python tests/run_tests.py
```

That uses LuaJIT 2.1, the same Lua 5.1 dialect WoW runs. Passing it doesn't prove anything about the real client, so test in-game too.

| File | Job |
|---|---|
| `Router.lua` | Route order and level and skip filters (pure Lua) |
| `Collect.lua` | Turns Questie's quest log, available quests and spawns into stops |
| `Arrow.lua` | The frame: arrow rotation, text, buttons |
| `Core.lua` | Startup, events, when to reroute, slash commands |

`docs/plan.md` has the original design notes.
