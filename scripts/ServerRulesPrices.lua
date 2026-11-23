-- FS25_ServerRules - shop prices and daily upkeep
--
-- Server: computes a list of overrides from the settings (computeOverrides).
-- Server and clients: apply the same list to their own store items (applyOverrides).
-- Original values are remembered once per store item, so applying again never stacks.

ServerRulesPrices = {}
ServerRulesPrices.originals = {}   -- storeItem -> {price, dailyUpkeep, configs = {cfgTable -> {price, dailyUpkeep}}}
ServerRulesPrices.applied = {}     -- list of storeItems that are currently changed

local function getSpeciesName(storeItem)
    if StoreSpecies ~= nil then
        if storeItem.species == StoreSpecies.VEHICLE then
            return "vehicle"
        elseif storeItem.species == StoreSpecies.PLACEABLE then
            return "placeable"
        elseif storeItem.species == StoreSpecies.HANDTOOL then
            return "handtool"
        end
    end
    return "other"
end

local function getSourceName(storeItem)
    if storeItem.dlcTitle ~= nil and storeItem.dlcTitle ~= "" then
        return "dlc"
    end
    if storeItem.isMod and storeItem.customEnvironment ~= nil then
        return "mod"
    end
    return "base"
end

local function getBrandName(storeItem)
    if g_brandManager ~= nil and storeItem.brandIndex ~= nil then
        local brand = g_brandManager:getBrandByIndex(storeItem.brandIndex)
        if brand ~= nil and brand.name ~= nil then
            return string.lower(brand.name)
        end
    end
    return nil
end

local function hasCategory(storeItem, category)
    if storeItem.categoryNames ~= nil then
        for _, c in pairs(storeItem.categoryNames) do
            if string.lower(tostring(c)) == category then
                return true
            end
        end
    end
    if storeItem.categoryName ~= nil and string.lower(tostring(storeItem.categoryName)) == category then
        return true
    end
    return false
end

local function forEachConfigItem(storeItem, func)
    if storeItem.configurations == nil then
        return
    end
    for _, items in pairs(storeItem.configurations) do
        if type(items) == "table" then
            for _, cfg in pairs(items) do
                if type(cfg) == "table" then
                    func(cfg)
                end
            end
        end
    end
end

function ServerRulesPrices.captureOriginal(storeItem)
    local o = ServerRulesPrices.originals[storeItem]
    if o == nil then
        o = {price = storeItem.price or 0, dailyUpkeep = storeItem.dailyUpkeep or 0, name = storeItem.name, configs = {}}
        forEachConfigItem(storeItem, function(cfg)
            o.configs[cfg] = {price = cfg.price, dailyUpkeep = cfg.dailyUpkeep}
        end)
        ServerRulesPrices.originals[storeItem] = o
    end
    return o
end

---Restores all changed store items to their original values
function ServerRulesPrices.resetAll()
    for _, storeItem in ipairs(ServerRulesPrices.applied) do
        local o = ServerRulesPrices.originals[storeItem]
        if o ~= nil then
            storeItem.price = o.price
            storeItem.dailyUpkeep = o.dailyUpkeep
            storeItem.name = o.name
            for cfg, v in pairs(o.configs) do
                cfg.price = v.price
                cfg.dailyUpkeep = v.dailyUpkeep
            end
        end
    end
    ServerRulesPrices.applied = {}
end

local function ruleMatches(rule, storeItem, info)
    if rule.item ~= nil and rule.item ~= info.key then
        return false
    end
    if rule.mod ~= nil and rule.mod ~= info.mod then
        return false
    end
    if rule.source ~= nil and rule.source ~= info.source then
        return false
    end
    if rule.species ~= nil and rule.species ~= info.species then
        return false
    end
    if rule.brand ~= nil and rule.brand ~= info.brand then
        return false
    end
    if rule.category ~= nil and not hasCategory(storeItem, rule.category) then
        return false
    end
    return true
end

local function isBetter(rule, best)
    if best == nil then
        return true
    end
    if rule.score ~= best.score then
        return rule.score > best.score
    end
    return rule.order > best.order
end

---Server: computes overrides for all store items.
-- @return list of {key, price, priceFactor, upkeep, upkeepFactor}, number of rules without any matching item
function ServerRulesPrices.computeOverrides(settings)
    local result = {}
    local rules = settings ~= nil and settings.priceRules or {}
    if #rules == 0 or g_storeManager == nil then
        return result, 0
    end
    local ruleUsed = {}
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        local o = ServerRulesPrices.originals[storeItem]
        local origPrice = (o ~= nil and o.price) or storeItem.price or 0
        local origUpkeep = (o ~= nil and o.dailyUpkeep) or storeItem.dailyUpkeep or 0
        local info = {
            key = ServerRules.getItemKey(storeItem),
            mod = storeItem.customEnvironment ~= nil and string.lower(storeItem.customEnvironment) or nil,
            source = getSourceName(storeItem),
            species = getSpeciesName(storeItem),
            brand = getBrandName(storeItem)
        }
        local bestPrice, bestUpkeep, bestName = nil, nil, nil
        for _, rule in ipairs(rules) do
            if ruleMatches(rule, storeItem, info) then
                ruleUsed[rule] = true
                if (rule.price ~= nil or rule.priceFactor ~= nil) and isBetter(rule, bestPrice) then
                    bestPrice = rule
                end
                if (rule.dailyUpkeep ~= nil or rule.upkeepFactor ~= nil) and isBetter(rule, bestUpkeep) then
                    bestUpkeep = rule
                end
                if (rule.name ~= nil or rule.nameSuffix ~= nil) and isBetter(rule, bestName) then
                    bestName = rule
                end
            end
        end
        local price, priceFactor = origPrice, 1
        if bestPrice ~= nil then
            if bestPrice.price ~= nil then
                price = bestPrice.price
                priceFactor = origPrice > 0 and (price / origPrice) or 1
            else
                priceFactor = bestPrice.priceFactor
                price = origPrice * priceFactor
            end
        end
        local upkeep, upkeepFactor = origUpkeep, 1
        if bestUpkeep ~= nil then
            if bestUpkeep.dailyUpkeep ~= nil then
                upkeep = bestUpkeep.dailyUpkeep
                upkeepFactor = origUpkeep > 0 and (upkeep / origUpkeep) or 1
            else
                upkeepFactor = bestUpkeep.upkeepFactor
                upkeep = origUpkeep * upkeepFactor
            end
        end
        local newName, nameSuffix = "", ""
        if bestName ~= nil then
            newName = bestName.name or ""
            nameSuffix = bestName.nameSuffix or ""
        end
        if price ~= origPrice or upkeep ~= origUpkeep or priceFactor ~= 1 or upkeepFactor ~= 1 or newName ~= "" or nameSuffix ~= "" then
            table.insert(result, {
                key = info.key,
                price = math.floor(price + 0.5),
                priceFactor = priceFactor,
                upkeep = upkeep,
                upkeepFactor = upkeepFactor,
                name = newName,
                nameSuffix = nameSuffix
            })
        end
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    local unused = 0
    for _, rule in ipairs(rules) do
        if not ruleUsed[rule] then
            unused = unused + 1
            ServerRules.log("Hinweis: Preisregel %d trifft keinen Artikel (item=%s mod=%s category=%s brand=%s)",
                rule.order + 1, tostring(rule.item), tostring(rule.mod), tostring(rule.category), tostring(rule.brand))
        end
    end
    return result, unused
end

---Server and clients: resets and applies a list of overrides.
-- @return number applied, number unknown keys
function ServerRulesPrices.applyOverrides(list)
    ServerRulesPrices.resetAll()
    if g_storeManager == nil then
        return 0, #list
    end
    local index = {}
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        index[ServerRules.getItemKey(storeItem)] = storeItem
    end
    local applied, unknown = 0, 0
    for _, e in ipairs(list) do
        local storeItem = index[e.key]
        if storeItem == nil then
            unknown = unknown + 1
            if unknown <= 10 then
                ServerRules.log("Warnung: Artikel '%s' gibt es hier nicht (andere Mods als der Server?)", e.key)
            end
        else
            local o = ServerRulesPrices.captureOriginal(storeItem)
            storeItem.price = e.price
            storeItem.dailyUpkeep = e.upkeep
            if e.name ~= nil and e.name ~= "" then
                storeItem.name = e.name
            end
            if e.nameSuffix ~= nil and e.nameSuffix ~= "" then
                storeItem.name = tostring(storeItem.name) .. e.nameSuffix
            end
            for cfg, v in pairs(o.configs) do
                local p = tonumber(v.price)
                if p ~= nil then
                    cfg.price = p * e.priceFactor
                end
                local u = tonumber(v.dailyUpkeep)
                if u ~= nil then
                    cfg.dailyUpkeep = u * e.upkeepFactor
                end
            end
            table.insert(ServerRulesPrices.applied, storeItem)
            applied = applied + 1
        end
    end
    return applied, unknown
end

---Short text that changes whenever any override changes
function ServerRulesPrices.getFingerprint(list)
    local parts = {}
    for _, e in ipairs(list) do
        table.insert(parts, string.format("%s=%d/%.6f/%.4f/%.6f/%s/%s", e.key, e.price, e.priceFactor, e.upkeep, e.upkeepFactor, e.name or "", e.nameSuffix or ""))
    end
    return table.concat(parts, ";")
end
