-- Plain-Lua tests for mod/RVRestore/Scripts/rvr_logic.lua against mock game objects.
-- usage: lua5.4 tests/lua/test_restore.lua [path/to/Scripts]
local SCRIPTS = arg[1] or "mod/RVRestore/Scripts"

-- ---- stub the UE4SS environment -----------------------------------------------------------
local printed = {}
_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
local NOW = 1000
os.time = function() return NOW end
local hooks, hook_fail = {}, false
_G.RegisterHook = function(path, fn)
    if hook_fail then error("class not loaded yet") end
    hooks[path] = fn
    return 1, 1
end
local loop_fn
_G.LoopAsync = function(ms, fn) loop_fn = fn end
_G.ExecuteInGameThread = function(fn) fn() end
_G.FName = function(s) return { ToString = function() return s end } end

local world = { all = {}, gm = true }
_G.FindAllOf = function(cls) local l = world.all[cls]; if l and #l > 0 then return l end end
package.preload["UEHelpers"] = function()
    return { GetGameModeBase = function() return world.gm and { IsValid = function() return true end } or nil end }
end
package.preload["rvr_config"] = function() return { settle_seconds = 4, verbose = false } end

local M = dofile(SCRIPTS .. "/rvr_logic.lua")
RVR = M

-- ---- mock objects --------------------------------------------------------------------------
local fails, total = 0, 0
local function check(cond, msg) total = total + 1; if not cond then fails = fails + 1; io.stderr:write("FAIL: " .. msg .. "\n") end end
local function eq(a, b, msg) check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

local function fname(s) return { ToString = function() return s end } end

local function tarray(items)
    local arr = { items = items, emptied = 0 }
    function arr:GetArrayNum() return #self.items end
    function arr:Empty() self.items = {}; self.emptied = self.emptied + 1 end
    function arr:ForEach(cb) for i, v in ipairs(self.items) do cb(i, { get = function() return v end }) end end
    return arr
end

-- generic actor: unknown methods are recorded and return nothing; listed ones are real
local function actor(nm, fields, methods)
    local calls = {}
    local a = { __calls = calls, __name = nm, __dead = false, __loc = { X = 0, Y = 0, Z = 0 }, __parent = nil, __children = {} }
    for k, v in pairs(fields or {}) do a[k] = v end
    local base = {
        IsValid = function(self) return not self.__dead end,
        GetFName = function(self) return fname(self.__name) end,
        GetAttachParentActor = function(self) return self.__parent end,
        K2_GetActorLocation = function(self) return self.__loc end,
        GetAttachedActors = function(self, out) out.OutActors = tarray(self.__children) end,
    }
    for k, v in pairs(methods or {}) do base[k] = v end
    return setmetatable(a, { __index = function(t, k)
        if base[k] then
            return function(self, ...) calls[#calls + 1] = { k, ... }; return base[k](self, ...) end
        end
        return function(self, ...) calls[#calls + 1] = { k, ... } end
    end })
end
local function ncalls(a, name) local n = 0; for _, c in ipairs(a.__calls) do if c[1] == name then n = n + 1 end end; return n end
local function calls_of(a, name) local r = {}; for _, c in ipairs(a.__calls) do if c[1] == name then r[#r + 1] = c end end; return r end

local function class_obj(nm) return { IsValid = function() return true end, GetFName = function() return fname(nm) end } end

-- ---- scenario builders -----------------------------------------------------------------------
local function make_vehicle(sockets, attached_flags, opts)
    opts = opts or {}
    local v = actor("BP_Vehicle_Winnebago_01_C_0", {
        CurrentShieldHealth = opts.shield or 140, BaseShieldHealth = 140, CurrentDamage = tarray(opts.damage or {}),
        RepairableSocketNames = tarray({}), RepairableSocketTruckParts = tarray({}),
    })
    local names, parts = {}, {}
    for i, s in ipairs(sockets) do
        names[i] = fname(s)
        local p = actor("Part_" .. i)
        if attached_flags[i] == "ok" then p.__parent = v
        elseif attached_flags[i] == "loose" then p.__parent = nil
        elseif attached_flags[i] == "dead" then p.__dead = true end
        parts[i] = p
    end
    v.RepairableSocketNames, v.RepairableSocketTruckParts = tarray(names), tarray(parts)
    -- the game's RepairShield: restores the panel and 5 shield points
    rawset(v, "RepairShield", nil)
    local calls = v.__calls
    getmetatable(v).__index = (function(old)
        return function(t, k)
            if k == "RepairShield" then
                return function(self, sock, out)
                    calls[#calls + 1] = { "RepairShield", sock:ToString() }
                    self.CurrentShieldHealth = self.CurrentShieldHealth + 5
                end
            end
            return old(t, k)
        end
    end)(getmetatable(v).__index)
    return v
end

local function make_point(nm, vehicle, default_class, cur)
    local ap = actor(nm, { SpawnAttachedActor = default_class and class_obj(default_class) or nil, SpawnedInteractable = cur })
    ap.__parent = vehicle
    ap.SpawnAttachment = nil
    return ap
end

local function reset_world() world.all = {}; world.gm = true; printed = {} end
local function register(cls, list) world.all[cls] = list end

-- ======================================================================= tests

do -- 1. player healing
    local ch = actor("BP_FirstPersonCharacter_C_0", { CurrentDamage = tarray({ 1, 2, 3 }), LastSeenTotalDamage = 55 })
    check(M.heal_player(ch) == true, "heal returns true when there was damage")
    eq(ch.CurrentDamage:GetArrayNum(), 0, "damage emptied")
    eq(ch.LastSeenTotalDamage, 0, "last seen reset")
    eq(ncalls(ch, "OnRep_CurrentDamage"), 1, "health bar refreshed")
    local healthy = actor("BP_FirstPersonCharacter_C_1", { CurrentDamage = tarray({}) })
    check(M.heal_player(healthy) == false, "healthy player untouched")
    eq(ncalls(healthy, "OnRep_CurrentDamage"), 0, "nothing refreshed on a healthy player")
    eq(healthy.CurrentDamage:GetArrayNum(), 0, "healthy player unchanged")
    local dead = actor("x"); dead.__dead = true
    check(M.heal_player(dead) == false, "invalid player ignored")
    check(M.heal_player(nil) == false, "nil player ignored")
end

do -- 2. heal_players covers everyone
    reset_world()
    local a = actor("A", { CurrentDamage = tarray({ 1 }), LastSeenTotalDamage = 5 })
    local b = actor("B", { CurrentDamage = tarray({}), LastSeenTotalDamage = 0 })
    local c = actor("C", { CurrentDamage = tarray({ 1, 1 }), LastSeenTotalDamage = 5 })
    register("BP_FirstPersonCharacter_C", { a, b, c })
    local healed, total = M.heal_players()
    eq(healed, 2, "two of three needed healing"); eq(total, 3, "three players seen")
end

do -- 3. vehicle: repair exactly the missing panels, clear damage, full shield
    local v = make_vehicle({ "Roof", "Door", "Window", "Ladder" }, { "ok", "loose", "dead", "ok" },
        { shield = 130, damage = { 1, 2, 3 } })
    local r = M.heal_vehicle(v)
    eq(r.panels, 2, "two panels repaired")
    local rep = calls_of(v, "RepairShield")
    eq(#rep, 2, "RepairShield called twice")
    local names = { rep[1][2], rep[2][2] }; table.sort(names)
    eq(names[1] .. "," .. names[2], "Door,Window", "the right panels")
    eq(v.CurrentDamage:GetArrayNum(), 0, "damage cleared")
    eq(v.CurrentShieldHealth, 140, "shield full")
    eq(r.damage, 3, "reported 3 damage entries"); eq(r.shield_before, 130, "reported old shield")
    eq(ncalls(v, "OnRep_CurrentDamage"), 1, "damage refreshed"); eq(ncalls(v, "OnRep_CurrentShieldHealth"), 1, "shield refreshed")
end

do -- 4. vehicle in good shape: nothing repaired
    local v = make_vehicle({ "Roof", "Door" }, { "ok", "ok" })
    local r = M.heal_vehicle(v)
    eq(r.panels, 0, "nothing to repair"); eq(#calls_of(v, "RepairShield"), 0, "RepairShield not called")
    eq(v.CurrentShieldHealth, 140, "shield untouched")
end

do -- 5. duplicate socket names (the game lists a socket twice) are repaired once
    local v = make_vehicle({ "Roof", "Roof", "Door", "Door" }, { "dead", "dead", "loose", "loose" })
    M.heal_vehicle(v)
    eq(#calls_of(v, "RepairShield"), 2, "one repair per distinct socket")
end

do -- 6. a failing game call is contained and the rest still happens
    local v = make_vehicle({ "Roof", "Door" }, { "dead", "dead" }, { shield = 130, damage = { 1 } })
    getmetatable(v).__index = (function(old)
        return function(t, k)
            if k == "RepairShield" then return function() error("game exploded") end end
            return old(t, k)
        end
    end)(getmetatable(v).__index)
    local ok = pcall(M.heal_vehicle, v)
    check(ok, "heal_vehicle does not throw")
    eq(v.CurrentDamage:GetArrayNum(), 0, "damage still cleared"); eq(v.CurrentShieldHealth, 140, "shield still topped up")
end

do -- 7. items
    reset_world()
    local v = actor("RV")
    local map_item = actor("Map_0", { RelativeAttachTransform = "xf-map" }); map_item.__parent = nil; map_item.__loc = { X = 100, Y = 0, Z = 0 }
    local ap_map = make_point("AP_Map", v, "BP_Interactable_Map_C", map_item)            -- original is loose nearby
    getmetatable(map_item).__index = (function(old)                                        -- ForceAttach really re-parents
        return function(t, k)
            if k == "ForceAttach" then return function(self, parent, xf) map_item.__calls[#map_item.__calls + 1] = { "ForceAttach", parent, xf }; map_item.__parent = parent end end
            return old(t, k)
        end
    end)(getmetatable(map_item).__index)
    local drill = actor("Drill_0"); local ap_drill = make_point("AP_Drill", v, "BP_Interactable_PowerDrill_C", drill)
    drill.__parent = ap_drill                                                              -- already in place
    local gone = actor("Tool_gone"); gone.__dead = true
    local ap_tool = make_point("AP_Tool", v, "BP_Interactable_RepairTool_01_C", gone)      -- destroyed
    local held = actor("Winch_held"); held.__parent = actor("PlayerCharacter")
    local ap_winch = make_point("AP_Winch", v, "BP_Interactable_WinchController_C", held)   -- in a player's hands
    local far = actor("Beer_far"); far.__loc = { X = 99999, Y = 0, Z = 0 }
    local ap_beer = make_point("AP_Beer", v, "BP_Interactable_BeerPack_01_C", nil)         -- far loose copy only
    local ap_other = make_point("AP_Occupied", v, "BP_Interactable_OneTimeGrill_C", nil)
    ap_other.__children = { actor("SomethingElse") }                                        -- player put another thing here
    local ap_empty = make_point("AP_Empty", v, nil, nil)                                   -- no default item
    local on_other_vehicle = make_point("AP_Elsewhere", actor("OtherVehicle"), "BP_Interactable_Map_C", nil)
    register("BP_Interactable_AttachPoint_C", { ap_map, ap_drill, ap_tool, ap_winch, ap_beer, ap_other, ap_empty, on_other_vehicle })
    register("BP_Interactable_Map_C", { map_item })
    register("BP_Interactable_BeerPack_01_C", { far })
    -- SpawnAttachment: the game's own spawner (just record it)
    local r = M.reseat_items(v)
    eq(r.ok, 1, "drill already home")
    eq(r.reseated, 1, "map put back")
    eq(ncalls(map_item, "ForceAttach"), 1, "map: ForceAttach")
    eq(calls_of(map_item, "ForceAttach")[1][2], ap_map, "map attached to its own holder")
    eq(calls_of(map_item, "ForceAttach")[1][3], "xf-map", "using the item's stored transform")
    eq(ncalls(ap_map, "SpawnAttachment"), 0, "no duplicate map")
    eq(ncalls(ap_tool, "SpawnAttachment"), 1, "destroyed tool recreated")
    eq(calls_of(ap_tool, "SpawnAttachment")[1][2].GetFName().ToString(), "BP_Interactable_RepairTool_01_C", "with the right class")
    eq(ncalls(ap_winch, "SpawnAttachment"), 0, "held item: no duplicate")
    eq(ncalls(far, "ForceAttach"), 0, "far loose copy is left alone")
    eq(ncalls(ap_beer, "SpawnAttachment"), 1, "missing beer recreated (far copy is not claimed)")
    eq(ncalls(ap_other, "SpawnAttachment"), 0, "occupied holder untouched")
    eq(ncalls(ap_empty, "SpawnAttachment"), 0, "holder without a default item ignored")
    eq(ncalls(on_other_vehicle, "SpawnAttachment"), 0, "other vehicles' holders ignored")
    eq(r.spawned, 2, "two creations in total"); eq(r.skipped, 2, "held + occupied skipped")
end

do -- 8. loose original gets re-parented -> counted as reseated and registered; spawning disabled keeps empties empty
    reset_world()
    local v = actor("RV")
    local item = actor("Tool_loose", { RelativeAttachTransform = "xf" })
    local ap = make_point("AP", v, "BP_Interactable_PowerDrill_C", nil)
    getmetatable(item).__index = (function(old)
        return function(t, k)
            if k == "ForceAttach" then return function(self, parent) item.__calls[#item.__calls + 1] = { "ForceAttach", parent }; item.__parent = parent end end
            return old(t, k)
        end
    end)(getmetatable(item).__index)
    register("BP_Interactable_AttachPoint_C", { ap }); register("BP_Interactable_PowerDrill_C", { item })
    local r = M.reseat_items(v)
    eq(r.reseated, 1, "reseated"); eq(rawget(ap, "SpawnedInteractable"), item, "holder remembers its item again")
    -- now nothing nearby and spawning disabled
    M._cfg.spawn_missing_items = false
    local ap2 = make_point("AP2", v, "BP_Interactable_BeerPack_01_C", nil)
    register("BP_Interactable_AttachPoint_C", { ap2 })
    r = M.reseat_items(v)
    eq(ncalls(ap2, "SpawnAttachment"), 0, "spawn_missing_items=false is respected"); eq(r.skipped, 1, "counted as skipped")
    M._cfg.spawn_missing_items = true
end

do -- 9. one loose item is never used for two holders
    reset_world()
    local v = actor("RV")
    local grill = actor("Grill_0", { RelativeAttachTransform = "x" })
    local ap1 = make_point("AP1", v, "BP_Interactable_OneTimeGrill_C", nil)
    local ap2 = make_point("AP2", v, "BP_Interactable_OneTimeGrill_C", nil)
    getmetatable(grill).__index = (function(old)
        return function(t, k)
            if k == "ForceAttach" then return function(self, parent) grill.__calls[#grill.__calls + 1] = { "ForceAttach", parent }; grill.__parent = parent end end
            return old(t, k)
        end
    end)(getmetatable(grill).__index)
    register("BP_Interactable_AttachPoint_C", { ap1, ap2 }); register("BP_Interactable_OneTimeGrill_C", { grill })
    local r = M.reseat_items(v)
    eq(r.reseated, 1, "the one grill was reseated once"); eq(ncalls(grill, "ForceAttach"), 1, "attached exactly once")
    eq(r.spawned, 1, "the other holder got a new grill")
end

do -- 10. restore_all: host runs everything, a client touches nothing
    reset_world()
    local v = make_vehicle({ "Roof" }, { "dead" }, { shield = 135, damage = { 1 } })
    v.__name = "BP_Vehicle_Winnebago_01_C_0"
    register("BP_Vehicle_Winnebago_01_C", { v })
    local ch = actor("Char", { CurrentDamage = tarray({ 1 }), LastSeenTotalDamage = 3 }); register("BP_FirstPersonCharacter_C", { ch })
    world.gm = false
    check(M.restore_all("test") == false, "client does nothing")
    eq(#calls_of(v, "RepairShield"), 0, "no vehicle changes on a client"); eq(ch.CurrentDamage:GetArrayNum(), 1, "no player changes on a client")
    world.gm = true
    check(M.restore_all("test") == true, "host restores")
    eq(v.CurrentShieldHealth, 140, "vehicle healed"); eq(ch.CurrentDamage:GetArrayNum(), 0, "player healed")
    local log = table.concat(printed, "\n")
    check(log:find("restored after test", 1, true) ~= nil, "summary logged: " .. log)
end

do -- 11. config switches turn each part off
    reset_world()
    local v = make_vehicle({ "Roof" }, { "dead" }, { shield = 135, damage = { 1 } }); register("BP_Vehicle_Winnebago_01_C", { v })
    local ch = actor("Char", { CurrentDamage = tarray({ 1 }), LastSeenTotalDamage = 3 }); register("BP_FirstPersonCharacter_C", { ch })
    M._cfg.restore_vehicle, M._cfg.restore_players = false, false
    M.restore_all("t")
    eq(v.CurrentShieldHealth, 135, "vehicle untouched when disabled"); eq(ch.CurrentDamage:GetArrayNum(), 1, "players untouched when disabled")
    M._cfg.restore_vehicle, M._cfg.restore_players = true, true
end

do -- 12. scheduler: debounce, wait for the level, run once
    reset_world()
    local v = make_vehicle({ "Roof" }, { "dead" }, { shield = 135 }); v.__name = "BP_Vehicle_Winnebago_01_C_0"
    NOW = 5000
    M.request("restart")
    eq(M.pending(), "restart", "pending after request")
    NOW = 5002; M.request("vehicle spawned")                 -- more loading events push the deadline back
    NOW = 5005; M.tick()
    eq(M.pending() ~= nil, true, "still waiting (debounced)")
    NOW = 5006
    M.tick()                                                  -- due, but no vehicle yet -> keep waiting
    eq(M.pending() ~= nil, true, "waits for the vehicle to exist")
    register("BP_Vehicle_Winnebago_01_C", { v })
    M.tick()
    eq(M.pending(), nil, "ran and cleared"); eq(v.CurrentShieldHealth, 140, "restored once the level was ready")
    local n = #calls_of(v, "RepairShield")
    M.tick(); eq(#calls_of(v, "RepairShield"), n, "does not run twice")
end

do -- 13. scheduler gives up on a level that never loads
    reset_world()
    NOW = 9000; M.request("restart")
    NOW = 9000 + 100; M.tick()
    eq(M.pending(), nil, "gave up after 90 s without a vehicle")
end

do -- 14. hooks
    reset_world(); hooks = {}
    M.install()
    check(loop_fn ~= nil, "installer scheduled")
    hook_fail = true; loop_fn(); eq(next(hooks), nil, "nothing registered while classes are missing")
    hook_fail = false; loop_fn()
    local n = 0; for _ in pairs(hooks) do n = n + 1 end
    eq(n, 5, "three required + two optional load signals by default")
    hooks = {}; M._cfg.on_checkpoint_reached = true; M.install(); loop_fn()
    check(hooks["/Game/Ride/Game/BP_CheckPoint.BP_CheckPoint_C:TriggerCheckpoint"] ~= nil, "reached-hook when enabled")
    M._cfg.on_checkpoint_reached = false
    -- an unavailable OPTIONAL hook must not disable the mod
    hooks = {}; local real = _G.RegisterHook
    _G.RegisterHook = function(path, fn) if path:find("AttachPoint", 1, true) then error("nope") end return real(path, fn) end
    M.install(); loop_fn()
    check(hooks["/Game/Ride/Character/Blueprints/GM_FirstPerson.GM_FirstPerson_C:RestartFromCheckpoint"] ~= nil, "required hooks still installed")
    _G.RegisterHook = real
    hooks = {}; M.install(); loop_fn()
    check(hooks["/Game/Ride/Character/Blueprints/GM_FirstPerson.GM_FirstPerson_C:RestartFromCheckpoint"] ~= nil, "restart hook")
    check(hooks["/Game/Ride/Vehicle/Blueprints/BP_Vehicle_Winnebago_01.BP_Vehicle_Winnebago_01_C:StaticLoad"] ~= nil, "save-load hook")
    check(hooks["/Game/Ride/Game/BP_CheckPoint.BP_CheckPoint_C:TriggerCheckpoint"] == nil, "reached-hook off by default")
    NOW = 20000; hooks["/Game/Ride/Character/Blueprints/GM_FirstPerson.GM_FirstPerson_C:RestartFromCheckpoint"]()
    eq(M.pending(), "restart from checkpoint", "the hook requests a restore")
    M.tick(); NOW = 30000; M.tick()
end

if fails == 0 then io.write(string.format("lua restore tests: %d checks, 0 failed\n", total)) else
    io.write(string.format("lua restore tests: %d checks, %d FAILED\n", total, fails)) end
os.exit(fails == 0 and 0 or 1)
