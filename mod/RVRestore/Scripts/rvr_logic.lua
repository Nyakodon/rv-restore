-- RVRestore logic. Everything here talks to the game through guarded calls: an object read from a property is
-- always checked with valid() before use (a null UObject method call would crash the whole game, and pcall
-- cannot catch that).
local M = {}

local DEFAULTS = {
    settle_seconds = 4, restore_vehicle = true, restore_players = true, restore_items = true,
    join_heal_seconds = 30, spawn_missing_items = true, reseat_radius = 3000, on_checkpoint_reached = false, verbose = true,
}
local CFG = {}
do
    local ok, user = pcall(require, "rvr_config")
    for k, v in pairs(DEFAULTS) do CFG[k] = v end
    if ok and type(user) == "table" then for k, v in pairs(user) do CFG[k] = v end end
end

local function log(msg) print("[RVRestore] " .. msg .. "\n") end
local logged = {}
local function log_once(key, msg)
    if not logged[key] then
        logged[key] = true
        log(msg)
    end
end
local function say(msg) if CFG.verbose then log(msg) end end

-- ------------------------------------------------------------------ helpers
local function valid(o)
    if o == nil then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

local function name(o)
    if not valid(o) then return "nil" end
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or "?"
end

local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log_once(label .. tostring(err), label .. " failed: " .. tostring(err)) end
    return ok
end

-- TArray -> plain Lua list of its elements
local function to_list(arr)
    local out = {}
    if arr == nil then return out end
    local ok = pcall(function() arr:ForEach(function(i, e) out[i] = e:get() end) end)
    return ok and out or {}
end

local function find_all(class_name)
    local ok, r = pcall(FindAllOf, class_name)
    if ok and type(r) == "table" then return r end
    return {}
end

local function parent_actor(o)
    if not valid(o) then return nil end
    local ok, p = pcall(function() return o:GetAttachParentActor() end)
    if ok and valid(p) then return p end
    return nil
end

local function same(a, b) return valid(a) and valid(b) and name(a) == name(b) end

local function distance(a, b)
    local ok, d = pcall(function()
        local p, q = a:K2_GetActorLocation(), b:K2_GetActorLocation()
        return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2)
    end)
    return ok and d or math.huge
end

-- Only the host / single player runs the game mode, and only it may change shared game state.
local function game_mode()
    local ok, gm = pcall(function() return require("UEHelpers").GetGameModeBase() end)
    if ok and valid(gm) then return gm end
    return nil
end

-- ------------------------------------------------------------------ players
function M.heal_player(ch)
    if not valid(ch) then return false end
    local n = ch.CurrentDamage:GetArrayNum()
    if n <= 0 then return false end
    ch.CurrentDamage:Empty()
    try("LastSeenTotalDamage", function() ch.LastSeenTotalDamage = 0 end)
    try("OnRep_CurrentDamage", function() ch:OnRep_CurrentDamage() end) -- refreshes the health bar
    return true
end

function M.heal_players()
    local healed, total = 0, 0
    for _, ch in ipairs(find_all("BP_FirstPersonCharacter_C")) do
        if valid(ch) then
            total = total + 1
            if M.heal_player(ch) then healed = healed + 1 end
        end
    end
    return healed, total
end

-- ------------------------------------------------------------------ vehicle
-- Put every knocked-off panel back with the game's own repair function (what the repair tool does: it also gives
-- the panel's shield points back), then clear the accumulated damage.
function M.heal_vehicle(v)
    local r = { panels = 0, damage = 0, shield_before = 0, shield_after = 0 }
    if not valid(v) then return r end
    r.shield_before = v.CurrentShieldHealth
    r.damage = v.CurrentDamage:GetArrayNum()

    local sockets = to_list(v.RepairableSocketNames)
    local parts = to_list(v.RepairableSocketTruckParts)
    local done = {}
    for i, sock in ipairs(sockets) do
        local ok_name, sname = pcall(function() return sock:ToString() end)
        if ok_name and not done[sname] then
            done[sname] = true
            local part = parts[i]
            local attached = valid(part) and same(parent_actor(part), v)
            if not attached then
                if try("RepairShield " .. sname, function() v:RepairShield(FName(sname), {}) end) then
                    r.panels = r.panels + 1
                end
            end
        end
    end

    try("clear vehicle damage", function() v.CurrentDamage:Empty() end)
    if v.CurrentShieldHealth < v.BaseShieldHealth then
        try("shield", function() v.CurrentShieldHealth = v.BaseShieldHealth end)
    end
    try("OnRep_CurrentDamage", function() v:OnRep_CurrentDamage() end)
    try("OnRep_CurrentShieldHealth", function() v:OnRep_CurrentShieldHealth() end)
    r.shield_after = v.CurrentShieldHealth
    return r
end

-- -------------------------------------------------------------------- items
local function attached_children(ap)
    -- other actors attached to the point (GetAttachedActors needs 3 args and returns an opaque out-param in UE4SS,
    -- so walk the root component's AttachChildren and ask each child for its owner)
    local n = 0
    try("AttachChildren", function()
        local root = ap.RootComponent
        if not valid(root) then return end
        root.AttachChildren:ForEach(function(_, e)
            local c = e:get()
            if valid(c) then
                local o = c:GetOwner()
                if valid(o) and not same(o, ap) then n = n + 1 end
            end
        end)
    end)
    return n
end

-- Every attach point of the vehicle that has a default item (map holder, tool racks, shelves, roof, spare wheel...)
-- should hold it again: put the original back if it is lying around, else make a fresh one.
function M.reseat_items(v)
    local r = { reseated = 0, spawned = 0, ok = 0, skipped = 0 }
    if not valid(v) then return r end
    local points = {}
    for _, ap in ipairs(find_all("BP_Interactable_AttachPoint_C")) do
        if valid(ap) and same(parent_actor(ap), v) then
            local D = ap.SpawnAttachedActor
            if valid(D) then points[#points + 1] = { ap = ap, class = D } end
        end
    end
    local used = {}
    for _, pt in ipairs(points) do
        local ap, D = pt.ap, pt.class
        local cur = ap.SpawnedInteractable
        if valid(cur) and same(parent_actor(cur), ap) then
            r.ok = r.ok + 1
            used[name(cur)] = true
        elseif valid(cur) and parent_actor(cur) ~= nil then
            -- the item exists and is attached somewhere else (another rack, or in a player's hands): leave it,
            -- never create a second copy
            r.skipped = r.skipped + 1
            used[name(cur)] = true
        else
            -- 1. the original, if it is loose near the vehicle
            local best, best_d
            for _, cand in ipairs(find_all(D:GetFName():ToString())) do
                if valid(cand) and not used[name(cand)] and parent_actor(cand) == nil then
                    local d = distance(cand, v)
                    if d <= CFG.reseat_radius and (not best_d or d < best_d) then best, best_d = cand, d end
                end
            end
            if best then
                local ok = try("ForceAttach", function() best:ForceAttach(ap, best.RelativeAttachTransform, {}) end)
                if ok and same(parent_actor(best), ap) then
                    try("SpawnedInteractable", function() ap.SpawnedInteractable = best end)
                    used[name(best)] = true
                    r.reseated = r.reseated + 1
                    say("put " .. name(D) .. " back on " .. name(ap))
                end
            elseif attached_children(ap) > 0 then
                r.skipped = r.skipped + 1 -- something else was put there on purpose: leave it
            elseif CFG.spawn_missing_items then
                if try("SpawnAttachment", function() ap:SpawnAttachment(D) end) then
                    r.spawned = r.spawned + 1
                    say("created a new " .. name(D) .. " on " .. name(ap))
                end
            else
                r.skipped = r.skipped + 1
            end
        end
    end
    return r
end

-- ------------------------------------------------------------ orchestration
function M.restore_all(reason)
    local gm = game_mode()
    if not gm then
        log_once("notmaster", "not the host of this session: the host's game restores the shared state")
        return false
    end
    local vehicles = find_all("BP_Vehicle_Winnebago_01_C")
    local out = {}
    if CFG.restore_players then
        local ok = try("heal players", function()
            local healed, total = M.heal_players()
            out[#out + 1] = string.format("players healed %d/%d", healed, total)
        end)
        if not ok then out[#out + 1] = "players FAILED" end
    end
    for _, v in ipairs(vehicles) do
        if valid(v) then
            if CFG.restore_vehicle then
                try("heal vehicle", function()
                    local r = M.heal_vehicle(v)
                    out[#out + 1] = string.format("RV shield %d->%d, %d panel(s) restored, %d damage entr%s cleared",
                        r.shield_before, r.shield_after, r.panels, r.damage, r.damage == 1 and "y" or "ies")
                end)
            end
            if CFG.restore_items then
                try("reseat items", function()
                    local r = M.reseat_items(v)
                    out[#out + 1] = string.format("items: %d already in place, %d put back, %d recreated, %d left alone",
                        r.ok, r.reseated, r.spawned, r.skipped)
                end)
            end
        end
    end
    log("restored after " .. tostring(reason) .. ": " .. table.concat(out, "; "))
    return true
end

-- ---------------------------------------------------------------- scheduler
local S = { pending = nil, due = 0, started = 0 }
local seen = {}

function M.request(reason)
    local now = os.time()
    if not S.pending then S.started = now end
    S.pending = reason
    S.due = now + CFG.settle_seconds -- every new load event pushes the restore back: wait until things go quiet
    say("checkpoint / save load detected (" .. tostring(reason) .. "), restoring in " .. CFG.settle_seconds .. "s")
end

function M.tick()
    if not S.pending or os.time() < S.due then return end
    local vehicles = find_all("BP_Vehicle_Winnebago_01_C")
    local ready = false
    for _, v in ipairs(vehicles) do if valid(v) then ready = true end end
    if not ready and os.time() - S.started < 90 then return end -- level still loading
    local reason = S.pending
    S.pending = nil
    if ready then
        local ok, err = pcall(M.restore_all, reason)
        if not ok then log("error: " .. tostring(err)) end
        S.loaded = true
        seen = {} -- a new load: everyone's heal window starts now
    end
end

function M.pending() return S.pending end

-- Players whose saved damage arrives AFTER the restore (clients joining, the host's own character being set up late):
-- every character is kept healed for `join_heal_seconds` from the moment we first see it (after a load happened).
function M.watch_players()
    if not S.loaded or not CFG.restore_players or CFG.join_heal_seconds <= 0 then return end
    local now = os.time()
    for _, ch in ipairs(find_all("BP_FirstPersonCharacter_C")) do
        if valid(ch) then
            local id = ch:GetFullName()
            if not seen[id] then seen[id] = now end
            if now - seen[id] <= CFG.join_heal_seconds then
                local ok, healed = pcall(M.heal_player, ch)
                if ok and healed then say("healed " .. name(ch) .. " (saved damage arrived after the restore)") end
            end
        end
    end
end

-- --------------------------------------------------------------------- hooks
local PATHS = {
    restart = "/Game/Ride/Character/Blueprints/GM_FirstPerson.GM_FirstPerson_C:RestartFromCheckpoint",
    veh_begin = "/Game/Ride/Vehicle/Blueprints/BP_Vehicle_Winnebago_01.BP_Vehicle_Winnebago_01_C:ReceiveBeginPlay",
    veh_load = "/Game/Ride/Vehicle/Blueprints/BP_Vehicle_Winnebago_01.BP_Vehicle_Winnebago_01_C:StaticLoad",
    state_load = "/Game/Ride/Game/RideGameState.RideGameState_C:StaticLoad",
    point_load = "/Game/Ride/Interactables/AttachPoints/BP_Interactable_AttachPoint.BP_Interactable_AttachPoint_C:StaticLoad",
    reached = "/Game/Ride/Game/BP_CheckPoint.BP_CheckPoint_C:TriggerCheckpoint",
}

-- Required hooks must all register (the classes load lazily, so we retry). Optional ones only add extra "the game is
-- still loading" signals that push the restore back; failing to hook them must never disable the mod.
local function try_install()
    local required = {
        { PATHS.restart, function() RVR.request("restart from checkpoint") end },
        { PATHS.veh_begin, function() RVR.request("vehicle spawned") end },
        { PATHS.veh_load, function() RVR.request("save loaded") end },
    }
    local optional = {
        { PATHS.state_load, function() RVR.request("game state loaded") end },
        { PATHS.point_load, function() RVR.request("item holder loaded") end },
    }
    if CFG.on_checkpoint_reached then
        optional[#optional + 1] = { PATHS.reached, function() RVR.request("checkpoint reached") end }
    end
    for _, h in ipairs(required) do
        local ok, err = pcall(RegisterHook, h[1], h[2])
        if not ok then return false, err end
    end
    for _, h in ipairs(optional) do
        local ok, err = pcall(RegisterHook, h[1], h[2])
        if not ok then log_once("opt" .. h[1], "optional hook unavailable (" .. h[1]:match("[%w_]+:[%w_]+$") .. "): " .. tostring(err)) end
    end
    return true
end

function M.install()
    local installed, tries = false, 0
    LoopAsync(1000, function()
        ExecuteInGameThread(function()
            if not installed then
                local ok, err = try_install()
                tries = tries + 1
                if ok then
                    installed = true
                    log("ready: will restore after a checkpoint / save is loaded")
                elseif tries == 1 or tries % 30 == 0 then
                    log("waiting for the game classes to load: " .. tostring(err))
                end
            end
            M.tick()
            pcall(M.watch_players)
        end)
        return false
    end)
end

M._cfg = CFG
return M
