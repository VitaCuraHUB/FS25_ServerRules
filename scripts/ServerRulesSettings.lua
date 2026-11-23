-- FS25_ServerRules - reading the settings file (server only)
--
-- File: <profile>/modSettings/FS25_ServerRules/serverRules.xml
--
-- <serverRules version="1">
--   <general reloadInterval="60"/>                  seconds, 0 = only at server start
--   <prices>
--     <rule priceFactor="1.0" upkeepFactor="1.0"/>  no criteria = all items
--     <rule source="mod" category="productionPoints" priceFactor="5"/>
--     <rule mod="FS25_Example" priceFactor="10" upkeepFactor="2"/>
--     <rule brand="FENDT" species="vehicle" priceFactor="1.1"/>
--     <rule item="FS25_Example/xml/bakery.xml" price="250000" dailyUpkeep="120"/>
--   </prices>
-- </serverRules>
--
-- Criteria (all given ones must match): item, mod, category, brand, species (vehicle|placeable|handTool),
-- source (mod|base|dlc). Values: price | priceFactor, dailyUpkeep | upkeepFactor.
-- The most specific matching rule wins (item > mod > category/brand > species > source > none);
-- on a tie the later rule in the file wins. Price and upkeep are decided independently.

ServerRulesSettings = {}

ServerRulesSettings.WEIGHTS = {
    item = 1000,
    mod = 100,
    category = 10,
    brand = 10,
    species = 3,
    source = 1
}

local function readString(xml, key)
    local v = getXMLString(xml, key)
    if v ~= nil then
        v = string.gsub(v, "^%s+", "")
        v = string.gsub(v, "%s+$", "")
        if v == "" then
            return nil
        end
    end
    return v
end

local function readNumber(xml, key, warnings, ruleName)
    local s = readString(xml, key)
    if s == nil then
        return nil
    end
    local n = tonumber(s)
    if n == nil or n < 0 then
        table.insert(warnings, string.format("%s: '%s' ist keine gueltige Zahl (%s)", ruleName, s, key))
        return nil
    end
    return n
end

---Loads and validates the settings file.
-- @return table settings, table warnings (list of strings); settings is nil if the file is missing/unreadable
function ServerRulesSettings.load(path)
    local warnings = {}
    if not fileExists(path) then
        return nil, {"Einstellungsdatei fehlt: " .. path}
    end
    local xml = loadXMLFile("ServerRulesSettings", path)
    if xml == nil or xml == 0 then
        return nil, {"Einstellungsdatei nicht lesbar (XML-Fehler?): " .. path}
    end

    local settings = {
        version = getXMLInt(xml, "serverRules#version") or 1,
        reloadInterval = 60,
        priceRules = {}
    }
    local ri = getXMLInt(xml, "serverRules.general#reloadInterval")
    if ri ~= nil and ri >= 0 then
        settings.reloadInterval = ri
    end
    settings.writeCheckFile = getXMLBool(xml, "serverRules.general#writeCheckFile") == true

    local i = 0
    while true do
        local key = string.format("serverRules.prices.rule(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local name = string.format("Preisregel %d", i + 1)
        local rule = {
            order = i,
            item = ServerRules.normalizeKey(readString(xml, key .. "#item")),
            mod = readString(xml, key .. "#mod"),
            category = readString(xml, key .. "#category"),
            brand = readString(xml, key .. "#brand"),
            species = readString(xml, key .. "#species"),
            source = readString(xml, key .. "#source"),
            price = readNumber(xml, key .. "#price", warnings, name),
            priceFactor = readNumber(xml, key .. "#priceFactor", warnings, name),
            dailyUpkeep = readNumber(xml, key .. "#dailyUpkeep", warnings, name),
            upkeepFactor = readNumber(xml, key .. "#upkeepFactor", warnings, name)
        }
        for _, field in ipairs({"mod", "category", "brand", "species", "source"}) do
            if rule[field] ~= nil then
                rule[field] = string.lower(rule[field])
            end
        end
        if rule.source ~= nil and rule.source ~= "mod" and rule.source ~= "base" and rule.source ~= "dlc" then
            table.insert(warnings, string.format("%s: source='%s' unbekannt (mod|base|dlc) - Regel ignoriert", name, rule.source))
        elseif rule.species ~= nil and rule.species ~= "vehicle" and rule.species ~= "placeable" and rule.species ~= "handtool" then
            table.insert(warnings, string.format("%s: species='%s' unbekannt (vehicle|placeable|handTool) - Regel ignoriert", name, rule.species))
        elseif rule.price == nil and rule.priceFactor == nil and rule.dailyUpkeep == nil and rule.upkeepFactor == nil then
            table.insert(warnings, string.format("%s: kein Wert (price, priceFactor, dailyUpkeep, upkeepFactor) - Regel ignoriert", name))
        else
            if rule.price ~= nil and rule.priceFactor ~= nil then
                table.insert(warnings, string.format("%s: price und priceFactor zugleich - price gilt", name))
                rule.priceFactor = nil
            end
            if rule.dailyUpkeep ~= nil and rule.upkeepFactor ~= nil then
                table.insert(warnings, string.format("%s: dailyUpkeep und upkeepFactor zugleich - dailyUpkeep gilt", name))
                rule.upkeepFactor = nil
            end
            local score = 0
            for field, weight in pairs(ServerRulesSettings.WEIGHTS) do
                if rule[field] ~= nil then
                    score = score + weight
                end
            end
            rule.score = score
            table.insert(settings.priceRules, rule)
        end
        i = i + 1
    end

    delete(xml)
    return settings, warnings
end

---Creates an empty settings file so the admin knows where it belongs
function ServerRulesSettings.createDefault(path)
    local dir = ServerRules.getSettingsDirectory()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(dir)
    local xml = createXMLFile("ServerRulesSettings", path, "serverRules")
    if xml == nil or xml == 0 then
        return false
    end
    setXMLInt(xml, "serverRules#version", 1)
    setXMLInt(xml, "serverRules.general#reloadInterval", 60)
    setXMLString(xml, "serverRules.prices#info", "rule-Eintraege siehe README des Projekts FS25_ServerRules")
    saveXMLFile(xml)
    delete(xml)
    return true
end
