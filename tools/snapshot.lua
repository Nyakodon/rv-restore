-- test instance: summarise the RV's health / panels / items.   Defines snapshot(v) -> table, report(label)
local function valid(o) if o == nil then return false end local ok, r = pcall(function() return o:IsValid() end) return ok and r == true end
local function name(o) if valid(o) then return o:GetFName():ToString() end return "nil" end
function snapshot(v)
    v = v or FindFirstOf("BP_Vehicle_Winnebago_01_C")
    local s = { shield = v.CurrentShieldHealth, base = v.BaseShieldHealth, dmg = v.CurrentDamage:GetArrayNum(),
                sockets = 0, missing = {}, partsOnVehicle = 0, apFilled = 0, apDefault = 0, apWrong = {} }
    local names, parts = v.RepairableSocketNames, v.RepairableSocketTruckParts
    local nn = names:GetArrayNum()
    s.sockets = nn
    local pl = {}
    parts:ForEach(function(i, e) pl[i] = e:get() end)
    names:ForEach(function(i, e)
        local part = pl[i]
        local ok = false
        if valid(part) then
            local p = part:GetAttachParentActor()
            ok = valid(p) and name(p) == name(v)
        end
        if not ok then s.missing[#s.missing + 1] = e:get():ToString() end
    end)
    for _, a in ipairs(FindAllOf("BP_Interactable_TruckPart_01_C") or {}) do
        local p = a:GetAttachParentActor()
        if valid(p) and name(p) == name(v) then s.partsOnVehicle = s.partsOnVehicle + 1 end
    end
    for _, ap in ipairs(FindAllOf("BP_Interactable_AttachPoint_C") or {}) do
        local par = ap:GetAttachParentActor()
        if valid(par) and name(par) == name(v) then
            local D = ap.SpawnAttachedActor
            if valid(D) then
                s.apDefault = s.apDefault + 1
                local cur = ap.SpawnedInteractable
                local good = false
                if valid(cur) then
                    local cp = cur:GetAttachParentActor()
                    good = valid(cp) and name(cp) == name(ap)
                end
                if good then s.apFilled = s.apFilled + 1 else s.apWrong[#s.apWrong + 1] = name(ap) .. "(" .. name(D) .. ")" end
            end
        end
    end
    return s
end
function report(label, v)
    local s = snapshot(v)
    print(string.format("%-14s shield %d/%d  dmg-entries %d  panelSockets %d (missing %d)  truckParts-on-RV %d  items-in-place %d/%d",
        label, s.shield, s.base, s.dmg, s.sockets, #s.missing, s.partsOnVehicle, s.apFilled, s.apDefault))
    if #s.missing > 0 then print("   missing panels:", table.concat(s.missing, ", ")) end
    if #s.apWrong > 0 then print("   items out of place:", table.concat(s.apWrong, ", ")) end
    return s
end
