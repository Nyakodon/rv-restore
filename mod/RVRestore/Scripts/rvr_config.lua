-- Settings. Edit and restart the game.
return {
    -- Seconds to wait after a checkpoint / save has loaded before restoring (lets the game finish spawning everything).
    settle_seconds = 4,

    -- What to restore:
    restore_vehicle = true,   -- clear all RV damage and put every knocked-off panel back (shield back to full)
    restore_players = true,   -- heal every player to full health
    join_heal_seconds = 30,   -- keep healing each player for this long after it appears (late-arriving saved damage, joiners); 0 = off
    restore_items = true,     -- put the map, tools, food, spare wheel ... back in their holders in the RV

    -- If an item's default holder is empty and the item is gone (not lying around within `reseat_radius`),
    -- create a fresh one with the game's own spawn function.
    spawn_missing_items = true,
    reseat_radius = 3000,     -- cm (30 m): loose items this close to the RV are put back, not duplicated

    -- Also restore when the group merely REACHES a checkpoint (default: only when one is loaded).
    on_checkpoint_reached = false,

    verbose = true,           -- log what was restored
}
