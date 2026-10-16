-- RVRestore: after a checkpoint / save is loaded, put the RV, the players and everything in the RV back in order.
local ok, logic = pcall(require, "rvr_logic")
if not ok then
    print("[RVRestore] failed to load: " .. tostring(logic) .. "\n")
    return
end
RVR = logic -- global (this mod's own Lua state): hook callbacks call through it
logic.install()
