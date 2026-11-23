-- FS25_ServerRules - productions (recipes, cycles, costs, storage) and selling prices of goods
--
-- Every production point is registered when it loads (hook on ProductionPoint.load).
-- The server applies its rules right there - before the savegame fill levels are loaded, so a
-- smaller storage does not cut existing goods. Clients get the same rules from the server and
-- apply them to their own copies (only needed for the display; production runs on the server).

ServerRulesProductions = {}
ServerRulesProductions.points = {}         -- list of registered production points
ServerRulesProductions.originals = {}      -- productionPoint -> original values
ServerRulesProductions.fillTypeFactors = {} -- fillTypeIndex -> selling price factor (server)

local function fillTypeName(index)
    if g_fillTypeManager ~= nil and index ~= nil then
        local name = g_fillTypeManager:getFillTypeNameByIndex(index)
        if name ~= nil then
            return string.upper(name)
        end
    end
    return tostring(index)
end

---Key and mod name of the building a production point belongs to
function ServerRulesProductions.getPointKey(pp)
    local placeable = pp.owningPlaceable
    if placeable == nil or placeable.configFileName == nil then
        return nil, nil
    end
    local env = placeable.customEnvironment
    local key = ServerRules.getFileKey(placeable.configFileName, env, placeable.baseDirectory)
    return key, env ~= nil and string.lower(env) or nil
end

local function capture(pp)
    local o = ServerRulesProductions.originals[pp]
    if o ~= nil then
        return o
    end
    o = {productions = {}, capacities = {}, capacity = nil}
    for _, production in ipairs(pp.productions or {}) do
        local po = {cyclesPerMinute = production.cyclesPerMinute, costsPerActiveMinute = production.costsPerActiveMinute, inputs = {}, outputs = {}}
        for i, input in ipairs(production.inputs or {}) do
            po.inputs[i] = input.amount
        end
        for i, output in ipairs(production.outputs or {}) do
            po.outputs[i] = output.amount
        end
        o.productions[production] = po
    end
    local storage = pp.storage
    if storage ~= nil then
        o.capacity = storage.capacity
        if storage.capacities ~= nil then
            for ft, cap in pairs(storage.capacities) do
                o.capacities[ft] = cap
            end
        end
    end
    ServerRulesProductions.originals[pp] = o
    return o
end

local function setCycles(production, perHour)
    production.cyclesPerHour = perHour
    production.cyclesPerMinute = perHour / 60
    production.cyclesPerMonth = perHour * 24
end

local function setCosts(production, perHour)
    production.costsPerActiveHour = perHour
    production.costsPerActiveMinute = perHour / 60
    production.costsPerActiveMonth = perHour * 24
end

local function better(rule, best)
    if best == nil then
        return true
    end
    if rule.score ~= best.score then
        return rule.score > best.score
    end
    return rule.order > best.order
end

---Restores the original values of one production point and applies the rules to it.
-- @return number of changed productions, number of changed storage entries
function ServerRulesProductions.applyToPoint(pp, rules)
    if pp == nil or pp.productions == nil then
        return 0, 0
    end
    local o = capture(pp)
    local key, mod = ServerRulesProductions.getPointKey(pp)

    -- reset
    for _, production in ipairs(pp.productions) do
        local po = o.productions[production]
        if po ~= nil then
            if po.cyclesPerMinute ~= nil then
                setCycles(production, po.cyclesPerMinute * 60)
            end
            if po.costsPerActiveMinute ~= nil then
                setCosts(production, po.costsPerActiveMinute * 60)
            end
            for i, input in ipairs(production.inputs or {}) do
                input.amount = po.inputs[i] or input.amount
            end
            for i, output in ipairs(production.outputs or {}) do
                output.amount = po.outputs[i] or output.amount
            end
        end
    end
    if pp.storage ~= nil then
        if o.capacity ~= nil then
            pp.storage.capacity = o.capacity
        end
        if pp.storage.capacities ~= nil then
            for ft, cap in pairs(o.capacities) do
                pp.storage.capacities[ft] = cap
            end
        end
    end
    if rules == nil or key == nil then
        return 0, 0
    end

    -- productions
    local changedProductions = 0
    for _, production in ipairs(pp.productions) do
        local po = o.productions[production]
        local best = nil
        for _, rule in ipairs(rules.productionRules or {}) do
            if (rule.item == nil or rule.item == key) and (rule.mod == nil or rule.mod == mod)
                and (rule.id == nil or string.lower(rule.id) == string.lower(tostring(production.id))) and better(rule, best) then
                best = rule
            end
        end
        if best ~= nil and po ~= nil then
            local origCph = (po.cyclesPerMinute or 0) * 60
            if best.cyclesPerHour ~= nil then
                setCycles(production, best.cyclesPerHour)
            elseif best.cyclesFactor ~= nil then
                setCycles(production, origCph * best.cyclesFactor)
            end
            local origCost = (po.costsPerActiveMinute or 0) * 60
            if best.costsPerHour ~= nil then
                setCosts(production, best.costsPerHour)
            elseif best.costsFactor ~= nil then
                setCosts(production, origCost * best.costsFactor)
            end
            for i, input in ipairs(production.inputs or {}) do
                local name = fillTypeName(input.type)
                if best.inputs[name] ~= nil then
                    input.amount = best.inputs[name]
                elseif best.inputFactor ~= nil and po.inputs[i] ~= nil then
                    input.amount = po.inputs[i] * best.inputFactor
                end
            end
            for i, output in ipairs(production.outputs or {}) do
                local name = fillTypeName(output.type)
                if best.outputs[name] ~= nil then
                    output.amount = best.outputs[name]
                elseif best.outputFactor ~= nil and po.outputs[i] ~= nil then
                    output.amount = po.outputs[i] * best.outputFactor
                end
            end
            changedProductions = changedProductions + 1
        end
    end

    -- storage
    local changedStorage = 0
    local storage = pp.storage
    if storage ~= nil and #(rules.storageRules or {}) > 0 then
        local function bestFor(ftName)
            local best = nil
            for _, rule in ipairs(rules.storageRules) do
                if (rule.item == nil or rule.item == key) and (rule.mod == nil or rule.mod == mod)
                    and (rule.fillType == nil or rule.fillType == ftName) and better(rule, best) then
                    best = rule
                end
            end
            return best
        end
        local function newCapacity(rule, orig)
            if rule.capacity ~= nil then
                return rule.capacity
            end
            return (orig or 0) * rule.capacityFactor
        end
        if storage.capacities ~= nil and next(o.capacities) ~= nil then
            for ft, orig in pairs(o.capacities) do
                local rule = bestFor(fillTypeName(ft))
                if rule ~= nil then
                    storage.capacities[ft] = newCapacity(rule, orig)
                    changedStorage = changedStorage + 1
                end
            end
        end
        -- "*" matches no fill type name, so this finds the best rule without fillType;
        -- such a rule also sets the total capacity
        local general = bestFor("*")
        if general ~= nil and o.capacity ~= nil then
            storage.capacity = newCapacity(general, o.capacity)
            changedStorage = changedStorage + 1
        end
    end
    return changedProductions, changedStorage
end

---Goods that must always be sold directly (e.g. a substitute currency like coins -> paid in euro)
ServerRulesProductions.forcedDirectSell = {}

function ServerRulesProductions.setForcedDirectSell(rules)
    local forced = {}
    for _, rule in ipairs((rules ~= nil and rules.fillTypeRules) or {}) do
        if rule.forceDirectSell and g_fillTypeManager ~= nil then
            local index = g_fillTypeManager:getFillTypeIndexByName(rule.name)
            if index ~= nil then
                forced[index] = true
            end
        end
    end
    ServerRulesProductions.forcedDirectSell = forced
end

local originalSetOutputMode = nil

---Switches every forced output of this production point to "sell directly"
function ServerRulesProductions.enforceDirectSell(pp)
    if pp.productions == nil or ProductionPoint.OUTPUT_MODE == nil or next(ServerRulesProductions.forcedDirectSell) == nil then
        return 0
    end
    local n = 0
    local done = {}
    for _, production in ipairs(pp.productions) do
        for _, output in ipairs(production.outputs or {}) do
            local ft = output.type
            if ft ~= nil and not done[ft] and ServerRulesProductions.forcedDirectSell[ft] then
                done[ft] = true
                if pp.outputFillTypeIdsDirectSell == nil or not pp.outputFillTypeIdsDirectSell[ft] then
                    local setter = originalSetOutputMode or pp.setOutputDistributionMode
                    if setter ~= nil then
                        setter(pp, ft, ProductionPoint.OUTPUT_MODE.DIRECT_SELL, true)
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

---Applies the rules to all registered production points
function ServerRulesProductions.applyAll(rules)
    ServerRulesProductions.setForcedDirectSell(rules)
    local points, productions, storage = 0, 0, 0
    local alive = {}
    for _, pp in ipairs(ServerRulesProductions.points) do
        if not pp.isDeleted then
            table.insert(alive, pp)
            local p, s = ServerRulesProductions.applyToPoint(pp, rules)
            ServerRulesProductions.enforceDirectSell(pp)
            if p > 0 or s > 0 then
                points = points + 1
            end
            productions = productions + p
            storage = storage + s
        end
    end
    ServerRulesProductions.points = alive
    return points, productions, storage
end

---Selling price factors (server only)
function ServerRulesProductions.setFillTypeFactors(rules)
    local factors = {}
    local unknown = 0
    for _, rule in ipairs((rules ~= nil and rules.fillTypeRules) or {}) do
        local index = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(rule.name) or nil
        if index == nil then
            unknown = unknown + 1
            ServerRules.log("Warnung: Ware '%s' gibt es nicht", tostring(rule.name))
        else
            factors[index] = rule.priceFactor
        end
    end
    ServerRulesProductions.fillTypeFactors = factors
    return unknown
end

---Writes the values in effect for all production points to the check file (server)
function ServerRulesProductions.writeCheck(xml, rootKey)
    local i = 0
    local seen = {}
    for _, pp in ipairs(ServerRulesProductions.points) do
        local key = ServerRulesProductions.getPointKey(pp)
        if key ~= nil and not seen[key] and not pp.isDeleted then
            seen[key] = true
            local base = string.format("%s.production(%d)", rootKey, i)
            setXMLString(xml, base .. "#key", key)
            local j = 0
            for _, production in ipairs(pp.productions or {}) do
                local pk = string.format("%s.recipe(%d)", base, j)
                local ins, outs = {}, {}
                for _, input in ipairs(production.inputs or {}) do
                    table.insert(ins, string.format("%g %s", input.amount, fillTypeName(input.type)))
                end
                for _, output in ipairs(production.outputs or {}) do
                    table.insert(outs, string.format("%g %s", output.amount, fillTypeName(output.type)))
                end
                setXMLString(xml, pk .. "#id", tostring(production.id))
                setXMLFloat(xml, pk .. "#cyclesPerHour", (production.cyclesPerMinute or 0) * 60)
                setXMLFloat(xml, pk .. "#costsPerHour", (production.costsPerActiveMinute or 0) * 60)
                setXMLString(xml, pk .. "#recipe", table.concat(ins, " + ") .. " -> " .. table.concat(outs, " + "))
                j = j + 1
            end
            if pp.storage ~= nil then
                local caps = {}
                for ft, cap in pairs(pp.storage.capacities or {}) do
                    table.insert(caps, string.format("%s=%g", fillTypeName(ft), cap))
                end
                table.sort(caps)
                setXMLString(xml, base .. "#storage", table.concat(caps, ","))
                setXMLFloat(xml, base .. "#storageTotal", pp.storage.capacity or 0)
            end
            i = i + 1
        end
    end
    return i
end

---------------------------------------------------------------------------------------------------
-- Hooks

ServerRulesProductions.clientLogCount = 0

local function onProductionPointLoaded(pp)
    table.insert(ServerRulesProductions.points, pp)
    local rules = ServerRules.getActiveRules()
    if rules ~= nil and g_server == nil then
        -- client: log which buildings get adjusted (to verify the display in tests)
        local p, s = ServerRulesProductions.applyToPoint(pp, rules)
        if (p > 0 or s > 0) and ServerRulesProductions.clientLogCount < 30 then
            ServerRulesProductions.clientLogCount = ServerRulesProductions.clientLogCount + 1
            ServerRules.log("Produktion angepasst: %s (%d Rezepte, %d Lagerplaetze)", tostring(ServerRulesProductions.getPointKey(pp)), p, s)
        end
    end
    if rules ~= nil then
        if g_server ~= nil then
            ServerRulesProductions.applyToPoint(pp, rules)
        end
        if g_fillTypeManager ~= nil and next(ServerRulesProductions.forcedDirectSell) == nil then
            ServerRulesProductions.setForcedDirectSell(rules)
        end
        ServerRulesProductions.enforceDirectSell(pp)
    end
end

if ProductionPoint ~= nil and ProductionPoint.load ~= nil then
    ProductionPoint.load = Utils.overwrittenFunction(ProductionPoint.load, function(self, superFunc, ...)
        local result = superFunc(self, ...)
        if result ~= false then
            local ok, err = pcall(onProductionPointLoaded, self)
            if not ok then
                ServerRules.log("FEHLER beim Anpassen einer Produktion: %s", tostring(err))
            end
        end
        return result
    end)
else
    ServerRules.log("FEHLER: ProductionPoint.load fehlt - Produktionsregeln inaktiv")
end

if SellingStation ~= nil and SellingStation.getEffectiveFillTypePrice ~= nil then
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(SellingStation.getEffectiveFillTypePrice, function(self, superFunc, fillTypeIndex, ...)
        local price = superFunc(self, fillTypeIndex, ...)
        if g_server ~= nil and price ~= nil and fillTypeIndex ~= nil then
            local f = ServerRulesProductions.fillTypeFactors[fillTypeIndex]
            if f ~= nil then
                price = price * f
            end
        end
        return price
    end)
else
    ServerRules.log("FEHLER: SellingStation.getEffectiveFillTypePrice fehlt - Warenpreise inaktiv")
end

-- A forced good can only be sold directly: other output modes are turned into "sell directly"
if ProductionPoint ~= nil and ProductionPoint.setOutputDistributionMode ~= nil then
    originalSetOutputMode = ProductionPoint.setOutputDistributionMode
    ProductionPoint.setOutputDistributionMode = Utils.overwrittenFunction(ProductionPoint.setOutputDistributionMode, function(self, superFunc, fillTypeId, mode, ...)
        if fillTypeId ~= nil and ServerRulesProductions.forcedDirectSell[fillTypeId] and ProductionPoint.OUTPUT_MODE ~= nil then
            mode = ProductionPoint.OUTPUT_MODE.DIRECT_SELL
        end
        return superFunc(self, fillTypeId, mode, ...)
    end)
else
    ServerRules.log("Warnung: ProductionPoint.setOutputDistributionMode fehlt - Direktverkauf-Regel inaktiv")
end
