-- FS25_ServerRules - limit unrealistic vehicle values (E-047): load capacity and top speed
--
-- Server and clients apply the same rules (from the synced rules text) to every vehicle,
-- each on its own side (no network event), so fill levels stay consistent.
-- Original values are remembered per vehicle, a changed rule is applied again from the original.
-- Prices are not touched here.

ServerRulesVehicles = {}
ServerRulesVehicles.timer = 0
ServerRulesVehicles.INTERVAL = 2000
ServerRulesVehicles.revision = 0      -- raised whenever the rules change
ServerRulesVehicles.count = 0

local FUEL = {DIESEL = true, DEF = true, AIR = true, ELECTRICCHARGE = true, METHANE = true}

local function isFuelUnit(fillUnit)
    if g_fillTypeManager == nil or type(fillUnit.supportedFillTypes) ~= "table" then
        return false
    end
    local any = false
    for index, supported in pairs(fillUnit.supportedFillTypes) do
        if supported then
            any = true
            local name = g_fillTypeManager:getFillTypeNameByIndex(index)
            if name == nil or not FUEL[string.upper(name)] then
                return false
            end
        end
    end
    return any
end

local function getVehicles()
    local m = g_currentMission
    if m == nil then
        return {}
    end
    if m.vehicleSystem ~= nil and m.vehicleSystem.vehicles ~= nil then
        return m.vehicleSystem.vehicles
    end
    return m.vehicles or {}
end

function ServerRulesVehicles.findRule(vehicle)
    local rules = ServerRules.getActiveRules()
    local list = rules ~= nil and rules.vehicleRules or nil
    if list == nil or #list == 0 or vehicle.configFileName == nil then
        return nil
    end
    local key = ServerRules.getFileKey(vehicle.configFileName, vehicle.customEnvironment, vehicle.baseDirectory)
    local mod = vehicle.customEnvironment ~= nil and string.lower(vehicle.customEnvironment) or nil
    local best = nil
    for _, r in ipairs(list) do
        local ok = (r.item == nil or r.item == key) and (r.mod == nil or r.mod == mod)
        if ok and (best == nil or r.score > best.score or (r.score == best.score and r.order > best.order)) then
            best = r
        end
    end
    return best
end

function ServerRulesVehicles.apply(vehicle)
    local rule = ServerRulesVehicles.findRule(vehicle)
    local changed = false
    -- capacity
    local spec = vehicle.spec_fillUnit
    if spec ~= nil and spec.fillUnits ~= nil then
        for i, fu in ipairs(spec.fillUnits) do
            if fu.serverRulesOrigCapacity == nil then
                fu.serverRulesOrigCapacity = fu.capacity
            end
            local target = fu.serverRulesOrigCapacity
            if rule ~= nil and rule.maxCapacity ~= nil and target ~= nil and target > rule.maxCapacity and not isFuelUnit(fu) then
                target = rule.maxCapacity
            end
            if target ~= nil and fu.capacity ~= target then
                if vehicle.setFillUnitCapacity ~= nil then
                    vehicle:setFillUnitCapacity(i, target, true)
                else
                    fu.capacity = target
                end
                changed = true
            end
        end
    end
    -- top speed (km/h in the rule, m/s in the motor)
    local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor ~= nil and motor.maxForwardSpeed ~= nil then
        if motor.serverRulesOrigSpeed == nil then
            motor.serverRulesOrigSpeed = motor.maxForwardSpeed
            motor.serverRulesOrigSpeedOrigin = motor.maxForwardSpeedOrigin
        end
        local target = motor.serverRulesOrigSpeed
        local targetOrigin = motor.serverRulesOrigSpeedOrigin
        if rule ~= nil and rule.maxSpeed ~= nil and target > rule.maxSpeed / 3.6 then
            target = rule.maxSpeed / 3.6
            targetOrigin = target
        end
        if motor.maxForwardSpeed ~= target then
            motor.maxForwardSpeed = target
            if targetOrigin ~= nil then
                motor.maxForwardSpeedOrigin = targetOrigin
            end
            changed = true
        end
    end
    vehicle.serverRulesRevision = ServerRulesVehicles.revision
    return changed
end

---Call when the rules changed (server: reload, client: new rules text)
function ServerRulesVehicles.rulesChanged()
    ServerRulesVehicles.revision = ServerRulesVehicles.revision + 1
    ServerRulesVehicles.timer = ServerRulesVehicles.INTERVAL
end

function ServerRulesVehicles.update(dt)
    ServerRulesVehicles.timer = ServerRulesVehicles.timer + dt
    if ServerRulesVehicles.timer < ServerRulesVehicles.INTERVAL then
        return
    end
    ServerRulesVehicles.timer = 0
    local rules = ServerRules.getActiveRules()
    if rules == nil then
        return
    end
    local n = 0
    for _, vehicle in pairs(getVehicles()) do
        if type(vehicle) == "table" and vehicle.serverRulesRevision ~= ServerRulesVehicles.revision and not vehicle.isDeleted then
            local ok, changed = pcall(ServerRulesVehicles.apply, vehicle)
            if ok and changed then
                n = n + 1
            elseif not ok then
                vehicle.serverRulesRevision = ServerRulesVehicles.revision
                ServerRules.log("Warnung: Fahrzeugregel bei %s: %s", tostring(vehicle.configFileName), tostring(changed))
            end
        end
    end
    if n > 0 then
        ServerRulesVehicles.count = ServerRulesVehicles.count + n
        ServerRules.log("Fahrzeuge angepasst: %d (Kapazitaet/Hoechstgeschwindigkeit)", n)
    end
end
