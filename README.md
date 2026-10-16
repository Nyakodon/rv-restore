# rv-restore — *RV There Yet?* (Linux / Proton)

An in-game mod (UE4SS, Lua) that, **whenever a checkpoint or save is loaded**:

| what | how |
|---|---|
| **RV health** | every panel / window / shield / roof / mirror / ladder that was knocked off is put back with the game's own repair function (the one the repair tool uses; it also returns the shield points), and all accumulated damage is cleared — shield back to full |
| **Players** | every player's damage is cleared and the health bar refreshed |
| **Things in the RV** | every holder that has a default item (the **map** holder, tool racks, shelves, roof, spare-wheel hook, glove box ...) gets it back: the original is re-attached if it is lying within 30 m of the RV, otherwise the game's own spawn function makes a new one. An item attached somewhere else, in someone's hands, or a holder something else was put on, is left alone — nothing is duplicated |

It detects a load by itself (checkpoint restart, the vehicle spawning, the game's own load functions) and waits
`settle_seconds` for loading to go quiet before restoring.

## Install

```sh
./rv_restore.py install        # game must be closed; installs UE4SS if missing, then the mod
```
Then, once, in Steam → the game → Properties → Launch Options: `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
`./rv_restore.py uninstall` removes the mod (`--all` also UE4SS, unless another mod still uses it).

Settings (`Mods/RVRestore/Scripts/rvr_config.lua`, kept across updates): `settle_seconds`, `restore_vehicle`,
`restore_players`, `restore_items`, `spawn_missing_items`, `reseat_radius`, `on_checkpoint_reached`, `verbose`.
The log (`.../Win64/ue4ss/UE4SS.log`) shows what each restore did, e.g.
`restored after vehicle spawned: players healed 1/1; RV shield 100->140, 8 panel(s) restored ...; items: 10 already in place, 1 put back ...`.

## Works with rv-wheel (and any other UE4SS mod)

Independent of the steering-wheel package ([rv-wheel](https://github.com/Nyakodon/rv-wheel)). If both are installed they share one UE4SS and one launch option; each
mod runs in its own Lua state, hooks different game functions and keeps its own files. Each installer reuses an
existing UE4SS and its settings, and `uninstall --all` keeps UE4SS while the other mod is still installed.
(Verified by running both together in a live game: the simulated wheel drove the RV while this mod reacted.)

## Limits

* **Host / single player only.** In a session someone else hosts it does nothing (the shared state belongs to the
  host's game) — install it on the host's machine.
* It is a free full repair at every checkpoint load. That is the point, but it changes the difficulty.
* The RV's **interior furniture** (seats, sofa, toilet, sink, lockers ...) is not touched: those parts are screwed
  down, have level-specific variants and no safe way to re-create them. A lost **wheel** is not handled either.
  Dead players are not revived by the mod (the game respawns them itself on a checkpoint restart).

## Verified (in an isolated, offline copy of the game)

A real crash (shield 85/140, 11 panels off, 3 damage entries), a damaged player and a knocked-off, a destroyed and
a flung-away item were all restored to the pristine baseline (28/28 panels, 51 truck parts and no duplicates, 11/11
items in place, shield 140/140); with the mod installed, a real game checkpoint restart made it restore everything by
itself within seconds. Not reproducible without a real multi-checkpoint save: a *damaged* RV coming back from disk.

```sh
python3 -m unittest discover -s tests     # offline: installer + mock-game Lua tests (needs lua5.4 for those)
```
