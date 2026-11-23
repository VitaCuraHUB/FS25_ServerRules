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

ServerRulesSettings.AUTO_FILENAME = "serverRules-auto.xml"
ServerRulesSettings.MANUAL_BONUS = 10000

---Loads the generated file (serverRules-auto.xml, e.g. written by a balancing tool) and the manual
-- file (serverRules.xml). Manual rules always win over generated ones where both match.
-- @return settings (nil if both files are missing or unreadable), warnings
function ServerRulesSettings.loadAll(dir)
    local autoPath = dir .. ServerRulesSettings.AUTO_FILENAME
    local manualPath = dir .. ServerRules.SETTINGS_FILENAME
    local warnings = {}
    local auto, manual = nil, nil
    if fileExists(autoPath) then
        local w
        auto, w = ServerRulesSettings.load(autoPath)
        for _, x in ipairs(w) do
            table.insert(warnings, "[auto] " .. x)
        end
    end
    if fileExists(manualPath) then
        local w
        manual, w = ServerRulesSettings.load(manualPath)
        for _, x in ipairs(w) do
            table.insert(warnings, x)
        end
    end
    if auto == nil and manual == nil then
        if #warnings == 0 then
            table.insert(warnings, "Einstellungsdatei fehlt: " .. manualPath)
        end
        return nil, warnings
    end
    if auto == nil then
        return manual, warnings
    end
    if manual == nil then
        return auto, warnings
    end
    local merged = manual
    for _, listName in ipairs({"priceRules", "productionRules", "storageRules"}) do
        local list = {}
        for _, r in ipairs(auto[listName] or {}) do
            table.insert(list, r)
        end
        for _, r in ipairs(manual[listName] or {}) do
            r.score = (r.score or 0) + ServerRulesSettings.MANUAL_BONUS
            r.order = (r.order or 0) + 100000
            table.insert(list, r)
        end
        merged[listName] = list
    end
    -- fill type factors: manual entries replace generated ones of the same good
    local byName = {}
    local list = {}
    for _, src in ipairs({auto.fillTypeRules or {}, manual.fillTypeRules or {}}) do
        for _, r in ipairs(src) do
            if byName[r.name] ~= nil then
                local old = list[byName[r.name]]
                list[byName[r.name]] = {name = r.name, priceFactor = r.priceFactor or old.priceFactor, forceDirectSell = r.forceDirectSell or old.forceDirectSell}
            else
                table.insert(list, r)
                byName[r.name] = #list
            end
        end
    end
    merged.fillTypeRules = list
    -- roles only come from the manual file; use generated ones only if the manual file has none
    if #(manual.roles or {}) == 0 and auto.roles ~= nil and #auto.roles > 0 then
        merged.roles = auto.roles
        merged.rolesById = auto.rolesById
        merged.rolesMode = auto.rolesMode
    end
    return merged, warnings
end

---Loads and validates one settings file.
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
            upkeepFactor = readNumber(xml, key .. "#upkeepFactor", warnings, name),
            name = readString(xml, key .. "#name"),
            nameSuffix = readString(xml, key .. "#nameSuffix")
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
        elseif rule.price == nil and rule.priceFactor == nil and rule.dailyUpkeep == nil and rule.upkeepFactor == nil and rule.name == nil and rule.nameSuffix == nil then
            table.insert(warnings, string.format("%s: kein Wert (price, priceFactor, dailyUpkeep, upkeepFactor, name, nameSuffix) - Regel ignoriert", name))
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

    ServerRulesSettings.loadProductionRules(xml, settings, warnings)
    if ServerRulesRoles ~= nil then
        ServerRulesRoles.loadFromXML(xml, settings, warnings)
    end

    delete(xml)
    return settings, warnings
end

-- Productions (stage 2):
-- <productions>
--   <production item="FS25_X/xml/bakery.xml" id="cake" cyclesPerHour="0.5" costsPerHour="10">
--     <input fillType="FLOUR" amount="8"/>     <output fillType="CAKE" amount="21"/>
--   </production>
--   <production mod="FS25_X" cyclesFactor="0.1" costsFactor="5" inputFactor="1" outputFactor="0.5"/>
--   <storage item="FS25_X/xml/bakery.xml" fillType="CAKE" capacity="5000"/>
--   <storage mod="FS25_X" capacityFactor="0.5"/>
-- </productions>
-- <fillTypes>
--   <fillType name="CAKE" priceFactor="0.8"/>      selling price factor at all selling points
-- </fillTypes>
-- Most specific rule wins: item > mod; with id/fillType > without; tie -> later rule.
function ServerRulesSettings.loadProductionRules(xml, settings, warnings)
    settings.productionRules = {}
    settings.storageRules = {}
    settings.fillTypeRules = {}

    local i = 0
    while true do
        local key = string.format("serverRules.productions.production(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local name = string.format("Produktionsregel %d", i + 1)
        local rule = {
            order = i,
            item = ServerRules.normalizeKey(readString(xml, key .. "#item")),
            mod = readString(xml, key .. "#mod"),
            id = readString(xml, key .. "#id"),
            cyclesPerHour = readNumber(xml, key .. "#cyclesPerHour", warnings, name),
            cyclesFactor = readNumber(xml, key .. "#cyclesFactor", warnings, name),
            costsPerHour = readNumber(xml, key .. "#costsPerHour", warnings, name),
            costsFactor = readNumber(xml, key .. "#costsFactor", warnings, name),
            inputFactor = readNumber(xml, key .. "#inputFactor", warnings, name),
            outputFactor = readNumber(xml, key .. "#outputFactor", warnings, name),
            inputs = {},
            outputs = {}
        }
        if rule.mod ~= nil then
            rule.mod = string.lower(rule.mod)
        end
        for _, kind in ipairs({"input", "output"}) do
            local j = 0
            while true do
                local k = string.format("%s.%s(%d)", key, kind, j)
                if not hasXMLProperty(xml, k) then
                    break
                end
                local ft = readString(xml, k .. "#fillType")
                local amount = readNumber(xml, k .. "#amount", warnings, name)
                if ft ~= nil and amount ~= nil then
                    rule[kind .. "s"][string.upper(ft)] = amount
                else
                    table.insert(warnings, string.format("%s: %s %d ohne fillType/amount - ignoriert", name, kind, j + 1))
                end
                j = j + 1
            end
        end
        if rule.item == nil and rule.mod == nil then
            table.insert(warnings, string.format("%s: item oder mod fehlt - Regel ignoriert", name))
        else
            rule.score = (rule.item ~= nil and 100 or 0) + (rule.mod ~= nil and 10 or 0) + (rule.id ~= nil and 1 or 0)
            table.insert(settings.productionRules, rule)
        end
        i = i + 1
    end

    i = 0
    while true do
        local key = string.format("serverRules.productions.storage(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local name = string.format("Lagerregel %d", i + 1)
        local rule = {
            order = i,
            item = ServerRules.normalizeKey(readString(xml, key .. "#item")),
            mod = readString(xml, key .. "#mod"),
            fillType = readString(xml, key .. "#fillType"),
            capacity = readNumber(xml, key .. "#capacity", warnings, name),
            capacityFactor = readNumber(xml, key .. "#capacityFactor", warnings, name)
        }
        if rule.mod ~= nil then
            rule.mod = string.lower(rule.mod)
        end
        if rule.fillType ~= nil then
            rule.fillType = string.upper(rule.fillType)
        end
        if rule.item == nil and rule.mod == nil then
            table.insert(warnings, string.format("%s: item oder mod fehlt - Regel ignoriert", name))
        elseif rule.capacity == nil and rule.capacityFactor == nil then
            table.insert(warnings, string.format("%s: capacity oder capacityFactor fehlt - Regel ignoriert", name))
        else
            rule.score = (rule.item ~= nil and 100 or 0) + (rule.mod ~= nil and 10 or 0) + (rule.fillType ~= nil and 1 or 0)
            table.insert(settings.storageRules, rule)
        end
        i = i + 1
    end

    i = 0
    while true do
        local key = string.format("serverRules.fillTypes.fillType(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local name = string.format("Warenregel %d", i + 1)
        local ft = readString(xml, key .. "#name")
        local f = readNumber(xml, key .. "#priceFactor", warnings, name)
        local direct = getXMLBool(xml, key .. "#forceDirectSell") == true
        if ft == nil or (f == nil and not direct) then
            table.insert(warnings, string.format("%s: name oder priceFactor/forceDirectSell fehlt - ignoriert", name))
        else
            table.insert(settings.fillTypeRules, {name = string.upper(ft), priceFactor = f, forceDirectSell = direct})
        end
        i = i + 1
    end
end

---------------------------------------------------------------------------------------------------
-- Compact text form of the production/storage/fillType rules (server -> clients)

local SEP = "\t"
local function enc(v)
    if v == nil then
        return ""
    end
    if type(v) == "number" then
        return string.format("%.10g", v)
    end
    return (string.gsub(tostring(v), "[\t\n]", " "))
end
local function dec(s)
    if s == nil or s == "" then
        return nil
    end
    return s
end
local function decNum(s)
    if s == nil or s == "" then
        return nil
    end
    return tonumber(s)
end
local function encMap(map)
    local parts = {}
    for k, v in pairs(map or {}) do
        table.insert(parts, k .. "=" .. enc(v))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end
local function decMap(s)
    local map = {}
    if s ~= nil and s ~= "" then
        for pair in string.gmatch(s, "[^,]+") do
            local k, v = string.match(pair, "^(.-)=(.*)$")
            if k ~= nil and tonumber(v) ~= nil then
                map[k] = tonumber(v)
            end
        end
    end
    return map
end
local function split(line)
    local fields = {}
    local start = 1
    while true do
        local i = string.find(line, SEP, start, true)
        if i == nil then
            table.insert(fields, string.sub(line, start))
            break
        end
        table.insert(fields, string.sub(line, start, i - 1))
        start = i + 1
    end
    return fields
end

function ServerRulesSettings.serializeRules(settings)
    local lines = {}
    for _, r in ipairs(settings.productionRules or {}) do
        table.insert(lines, table.concat({"P", enc(r.order), enc(r.item), enc(r.mod), enc(r.id), enc(r.cyclesPerHour), enc(r.cyclesFactor),
            enc(r.costsPerHour), enc(r.costsFactor), enc(r.inputFactor), enc(r.outputFactor), encMap(r.inputs), encMap(r.outputs), enc(r.score)}, SEP))
    end
    for _, r in ipairs(settings.storageRules or {}) do
        table.insert(lines, table.concat({"S", enc(r.order), enc(r.item), enc(r.mod), enc(r.fillType), enc(r.capacity), enc(r.capacityFactor), enc(r.score)}, SEP))
    end
    for _, r in ipairs(settings.fillTypeRules or {}) do
        table.insert(lines, table.concat({"F", enc(r.name), enc(r.priceFactor), r.forceDirectSell and "1" or ""}, SEP))
    end
    if ServerRulesRoles ~= nil then
        ServerRulesRoles.serialize(settings, lines)
    end
    return table.concat(lines, "\n")
end

function ServerRulesSettings.deserializeRules(text)
    local rules = {productionRules = {}, storageRules = {}, fillTypeRules = {}}
    for line in string.gmatch(text or "", "[^\n]+") do
        local f = split(line)
        if f[1] == "P" then
            table.insert(rules.productionRules, {order = decNum(f[2]) or 0, item = dec(f[3]), mod = dec(f[4]), id = dec(f[5]),
                cyclesPerHour = decNum(f[6]), cyclesFactor = decNum(f[7]), costsPerHour = decNum(f[8]), costsFactor = decNum(f[9]),
                inputFactor = decNum(f[10]), outputFactor = decNum(f[11]), inputs = decMap(f[12]), outputs = decMap(f[13]), score = decNum(f[14]) or 0})
        elseif f[1] == "S" then
            table.insert(rules.storageRules, {order = decNum(f[2]) or 0, item = dec(f[3]), mod = dec(f[4]), fillType = dec(f[5]),
                capacity = decNum(f[6]), capacityFactor = decNum(f[7]), score = decNum(f[8]) or 0})
        elseif f[1] == "F" then
            table.insert(rules.fillTypeRules, {name = dec(f[2]), priceFactor = decNum(f[3]), forceDirectSell = f[4] == "1"})
        elseif ServerRulesRoles ~= nil and string.sub(f[1] or "", 1, 1) == "R" then
            ServerRulesRoles.deserializeLine(rules, f)
        end
    end
    return rules
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
