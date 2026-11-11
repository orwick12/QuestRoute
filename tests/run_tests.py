"""Run QuestRoute's offline Lua tests under LuaJIT (Lua 5.1, same dialect as WoW).

Usage (from the repo root):
    uv run --no-project --with lupa python tests/run_tests.py

Steps:
  1. Syntax-check every .lua file in QuestRoute/ (compile only, nothing runs).
  2. Load Router.lua the way WoW does (chunk called with addonName, namespace) and run tests/test_router.lua.
Exit code is non-zero on any syntax error or failed test.
"""
import pathlib
import sys

from lupa import luajit21

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT / "QuestRoute"


def main() -> int:
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua_load = lua.eval("function(src, name) local f, err = loadstring(src, name); return f, err end")

    bad = 0
    files = sorted(ADDON.glob("*.lua"))
    for path in files:
        fn, err = lua_load(path.read_text(encoding="utf-8"), "@" + path.name)
        if fn is None:
            print(f"SYNTAX  {path.name}: {err}")
            bad += 1
        else:
            print(f"syntax ok  {path.name}")
    print(f"{len(files)} files checked, {bad} with syntax errors\n")
    if not files:
        print("no .lua files found — is QuestRoute/ missing?")
        return 1

    ns = lua.table()
    router_fn, err = lua_load((ADDON / "Router.lua").read_text(encoding="utf-8"), "@Router.lua")
    if router_fn is None:
        return 1
    router_fn("QuestRoute", ns)
    lua.globals().Router = ns.Router

    test_fn, err = lua_load((ROOT / "tests" / "test_router.lua").read_text(encoding="utf-8"), "@test_router.lua")
    if test_fn is None:
        print("SYNTAX  test_router.lua:", err)
        return 1
    failed = test_fn()

    # Smoke test in a fresh runtime: real addon files + stubbed WoW API + fake Questie.
    print("\n--- smoke test ---")
    smoke_lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    files = smoke_lua.table()
    for name in ("Router.lua", "Collect.lua", "Arrow.lua", "Core.lua"):
        files[name] = (ADDON / name).read_text(encoding="utf-8")
    smoke_lua.globals().ADDON_FILES = files
    smoke_src = (ROOT / "tests" / "smoke.lua").read_text(encoding="utf-8")
    smoke_fn, err = smoke_lua.eval("function(src) local f, e = loadstring(src, '@smoke.lua'); return f, e end")(smoke_src)
    if smoke_fn is None:
        print("SYNTAX  smoke.lua:", err)
        return 1
    smoke_failed = smoke_fn()
    return 1 if (bad or failed or smoke_failed) else 0


if __name__ == "__main__":
    sys.exit(main())
