# tools/ — development helper

`snapshot.lua` defines `snapshot()` / `report(label)`: a one-line summary of the RV's shield, damage entries, panel
sockets, truck parts and default items in their holders. It was used to verify RVRestore against a pristine baseline
(before / after a crash). Run it through the dev REPL of an **isolated test copy of the game** — the harness lives in the
[rv-wheel](https://github.com/Nyakodon/rv-wheel) repo under `tools/` (`test-instance.sh`, `repl.py`).
