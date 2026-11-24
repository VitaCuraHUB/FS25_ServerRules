-- FS25_ServerRules - building outside the own land (I-34) and placement self test (I-33)
--
-- Setting (serverRules.xml):  <build anywhere="off|admin|roles|all"/>
--   off   = game default (only on own land)
--   admin = only the server admin
--   roles = admin + farms whose role has <build anywhere="true"/>
--   all   = everyone
-- Only the "is the land owned by the farm" answer is changed, and only while one of these runs
-- for an allowed player (all other checks stay):
--   client: ConstructionBrush.verifyAccess, ConstructionBrushPlaceable.verifyPlacement
--   both:   Landscaping.isModificationAreaOnOwnedLand (terraforming / leveling)
--   server: BuyPlaceableEvent.run, LandscapingSculptEvent.run (the connection decides who is asking)

ServerRulesBuild = {}
ServerRulesBuild.context = nil      -- connection of the event that is running right now (server)
ServerRulesBuild.testPlaceables = {}
ServerRulesBuild.testDeleteTimer = nil

local function getMode()
    local rules = ServerRules.getActiveRules()
    return (rules ~= nil and rules.buildAnywhere) or "off"
end

local function roleAllows(farmId)
    local role = ServerRulesRoles.getRoleOfFarm(farmId)
    return role ~= nil and role.buildAnywhere == true
end

---Server: may the user of this connection build outside the own land?
function ServerRulesBuild.isAllowedConnection(connection)
    local mode = getMode()
    if mode == "off" or connection == nil then
        return false
    end
    if mode == "all" then
        return true
    end
    if ServerRulesRoles.isAdminConnection(connection) then
        return true
    end
    if mode == "roles" then
        return roleAllows(ServerRulesRoles.getFarmIdOfConnection(connection))
    end
    return false
end

---Client: may the local player build outside the own land?
function ServerRulesBuild.isAllowedLocal()
    local mode = getMode()
    if mode == "off" or g_currentMission == nil then
        return false
    end
    if mode == "all" then
        return true
    end
    if g_currentMission.isMasterUser then
        return true
    end
    if mode == "roles" then
        return roleAllows(g_currentMission:getFarmId())
    end
    return false
end

local function isAllowedHere()
    if g_server ~= nil and ServerRulesBuild.context ~= nil then
        return ServerRulesBuild.isAllowedConnection(ServerRulesBuild.context)
    end
    if g_client ~= nil and g_server == nil then
        return ServerRulesBuild.isAllowedLocal()
    end
    return false
end

local function listFunctions(name, class)
    if type(class) ~= "table" then
        ServerRules.log("Diagnose Bauen: %s fehlt", name)
        return
    end
    local names = {}
    for k, v in pairs(class) do
        if type(v) == "function" then
            table.insert(names, tostring(k))
        end
    end
    table.sort(names)
    ServerRules.log("Diagnose Bauen: %s = %s", name, table.concat(names, ","))
end

function ServerRulesBuild.logDiagnostics()
    listFunctions("ConstructionBrush", ConstructionBrush)
    listFunctions("ConstructionBrushPlaceable", ConstructionBrushPlaceable)
    listFunctions("Landscaping", Landscaping)
    listFunctions("LandscapingSculptEvent", LandscapingSculptEvent)
    listFunctions("BuyPlaceableEvent", BuyPlaceableEvent)
    if ConstructionBrush ~= nil and type(ConstructionBrush.ERROR) == "table" then
        local names = {}
        for k, v in pairs(ConstructionBrush.ERROR) do
            table.insert(names, tostring(k) .. "=" .. tostring(v))
        end
        table.sort(names)
        ServerRules.log("Diagnose Bauen: ConstructionBrush.ERROR = %s", table.concat(names, ","))
    end
    for _, s in ipairs(ServerRulesBuild.SCAN or {}) do
        ServerRulesBuild.scanFunction(s[1], ServerRulesBuild.originals[s[1]])
    end
    ServerRules.log("Diagnose Bauen: Modus build#anywhere = %s, %s Haken gesetzt (erwartet 8)", getMode(), tostring(ServerRulesBuild.hookCount))
end

-- While ignoreLand > 0 every "is this land owned by the farm" question answers yes.
-- It is only raised around the building checks of an allowed player, so all other checks stay as they are.
ServerRulesBuild.ignoreLand = 0

local function withLand(allowed, func, ...)
    if not allowed then
        return func(...)
    end
    ServerRulesBuild.ignoreLand = ServerRulesBuild.ignoreLand + 1
    local ok, a, b, c = pcall(func, ...)
    ServerRulesBuild.ignoreLand = ServerRulesBuild.ignoreLand - 1
    if not ok then
        error(a)
    end
    return a, b, c
end

local function hookLand(name)
    if FarmlandManager ~= nil and FarmlandManager[name] ~= nil then
        FarmlandManager[name] = Utils.overwrittenFunction(FarmlandManager[name], function(self, superFunc, ...)
            if ServerRulesBuild.ignoreLand > 0 then
                ServerRulesBuild.noteCheck(name, true, true)
                return true
            end
            local result = superFunc(self, ...)
            ServerRulesBuild.noteCheck(name, result, false)
            return result
        end)
        return true
    end
    return false
end

-- original functions (before our hooks), for the diagnosis below
ServerRulesBuild.originals = {}
local SCAN = {
    {"ConstructionBrush.verifyAccess (Kontrolle)", function() return ConstructionBrush and ConstructionBrush.verifyAccess end},
    {"ConstructionBrushPlaceable.verifyPlacement", function() return ConstructionBrushPlaceable and ConstructionBrushPlaceable.verifyPlacement end},
    {"BuyPlaceableEvent.run", function() return BuyPlaceableEvent and BuyPlaceableEvent.run end},
    {"BuyPlaceableEvent.onPlaceableBoughtCallback", function() return BuyPlaceableEvent and BuyPlaceableEvent.onPlaceableBoughtCallback end},
    {"BuyPlaceableData.buy", function() return BuyPlaceableData and BuyPlaceableData.buy end},
    {"LandscapingSculptEvent.run", function() return LandscapingSculptEvent and LandscapingSculptEvent.run end},
    {"Landscaping.sculpt", function() return Landscaping and Landscaping.sculpt end},
    {"Landscaping.onSculptingValidated", function() return Landscaping and Landscaping.onSculptingValidated end},
    {"Landscaping.isModificationAreaOnOwnedLand", function() return Landscaping and Landscaping.isModificationAreaOnOwnedLand end}
}
local KEYWORDS = {"Owned", "OwnedBy", "farmland", "Farmland", "verifyAccess", "verifyPlacement", "hasPlayerPermission",
    "isModificationAreaOnOwnedLand", "canFarmAccess", "getCanAccessLand", "NO_PERMISSION", "LAND_UNOWNED", "sculpt", "Landscaping"}

---Which ownership related names does a game function use? (string constants of the compiled function)
function ServerRulesBuild.scanFunction(name, fn)
    if type(fn) ~= "function" then
        ServerRules.log("Diagnose Besitz: %s fehlt", name)
        return
    end
    if string.dump == nil then
        ServerRules.log("Diagnose Besitz: string.dump nicht verfuegbar")
        return
    end
    local ok, code = pcall(string.dump, fn)
    if not ok or type(code) ~= "string" then
        ServerRules.log("Diagnose Besitz: %s nicht lesbar (%s)", name, tostring(code))
        return
    end
    local found = {}
    for _, k in ipairs(KEYWORDS) do
        if string.find(code, k, 1, true) ~= nil then
            table.insert(found, k)
        end
    end
    ServerRules.log("Diagnose Besitz: %s (%d Bytes) nutzt: %s", name, string.len(code), #found > 0 and table.concat(found, ",") or "-")
end

ServerRulesBuild.SCAN = SCAN
-- captured when this file is loaded: before any hook of this mod (roles hooks come later from Main)
for _, s in ipairs(SCAN) do
    local ok, fn = pcall(s[2])
    ServerRulesBuild.originals[s[1]] = ok and fn or nil
end

-- diagnosis (server): does the server ask for land ownership while a player event runs?
ServerRulesBuild.contextName = nil
ServerRulesBuild.contextChecks = nil
function ServerRulesBuild.noteCheck(name, result, relaxed)
    if g_server ~= nil and ServerRulesBuild.contextName ~= nil and ServerRulesBuild.contextChecks ~= nil then
        local c = ServerRulesBuild.contextChecks
        c[name] = string.format("%s%s", tostring(result), relaxed and " (gelockert)" or "")
    end
end

function ServerRulesBuild.installHooks()
    local n = 0
    for _, name in ipairs({"getIsOwnedByFarmAlongLine", "getIsOwnedByFarmAtWorldPosition", "getCanAccessLandAtWorldPosition"}) do
        if hookLand(name) then
            n = n + 1
        end
    end
    -- client: construction brush (all brushes) and placeable placement
    if ConstructionBrush ~= nil and ConstructionBrush.verifyAccess ~= nil then
        ConstructionBrush.verifyAccess = Utils.overwrittenFunction(ConstructionBrush.verifyAccess, function(self, superFunc, ...)
            return withLand(ServerRulesBuild.isAllowedLocal(), superFunc, self, ...)
        end)
        n = n + 1
    end
    if ConstructionBrushPlaceable ~= nil and ConstructionBrushPlaceable.verifyPlacement ~= nil then
        ConstructionBrushPlaceable.verifyPlacement = Utils.overwrittenFunction(ConstructionBrushPlaceable.verifyPlacement, function(self, superFunc, ...)
            return withLand(ServerRulesBuild.isAllowedLocal(), superFunc, self, ...)
        end)
        n = n + 1
    end
    -- terraforming / leveling (client check and server check)
    if Landscaping ~= nil and Landscaping.isModificationAreaOnOwnedLand ~= nil then
        Landscaping.isModificationAreaOnOwnedLand = Utils.overwrittenFunction(Landscaping.isModificationAreaOnOwnedLand, function(self, superFunc, ...)
            return withLand(isAllowedHere(), superFunc, self, ...)
        end)
        n = n + 1
    end
    -- server: the events run with the connection of the player as context
    for _, cls in ipairs({LandscapingSculptEvent, BuyPlaceableEvent}) do
        if cls ~= nil and cls.run ~= nil then
            cls.run = Utils.overwrittenFunction(cls.run, function(self, superFunc, connection, ...)
                local old = ServerRulesBuild.context
                local oldName, oldChecks = ServerRulesBuild.contextName, ServerRulesBuild.contextChecks
                ServerRulesBuild.context = connection
                ServerRulesBuild.contextName = cls == BuyPlaceableEvent and "Kauf/Platzieren" or "Planieren"
                ServerRulesBuild.contextChecks = {}
                local allowed = g_server ~= nil and connection ~= nil and not connection:getIsServer() and ServerRulesBuild.isAllowedConnection(connection)
                local ok, a, b, c = pcall(withLand, allowed, superFunc, self, connection, ...)
                if g_server ~= nil and connection ~= nil and not connection:getIsServer() then
                    local parts = {}
                    for k, v in pairs(ServerRulesBuild.contextChecks or {}) do
                        table.insert(parts, k .. "=" .. v)
                    end
                    ServerRules.log("Diagnose Besitz: Server-Event %s von Hof %s (erlaubt=%s): Besitz-Abfragen: %s", ServerRulesBuild.contextName,
                        tostring(ServerRulesRoles.getFarmIdOfConnection(connection)), tostring(allowed), #parts > 0 and table.concat(parts, ", ") or "keine")
                end
                ServerRulesBuild.context = old
                ServerRulesBuild.contextName, ServerRulesBuild.contextChecks = oldName, oldChecks
                if not ok then
                    error(a)
                end
                return a, b, c
            end)
            n = n + 1
        end
    end
    for _, cls in ipairs({BuyPlaceableEvent, LandscapingSculptEvent}) do
        if cls ~= nil and cls.newServerToClient ~= nil then
            local orig = cls.newServerToClient
            local label = cls == BuyPlaceableEvent and "Kauf/Platzieren" or "Planieren"
            cls.newServerToClient = function(state, ...)
                if g_server ~= nil then
                    ServerRules.log("Diagnose Besitz: Antwort %s an Spieler: Status %s", label, tostring(state))
                end
                return orig(state, ...)
            end
        end
    end
    ServerRulesBuild.hookCount = n
end
---------------------------------------------------------------------------------------------------
-- Self test (server): load placeables listed in serverRules.xml once, log the result, remove them.
--   <test><placeable xml="fs25_serverrules_gebaeude/placeables/x.xml" x="0" z="0"/></test>

function ServerRulesBuild.runPlacementTest()
    if g_server == nil or g_storeManager == nil or PlaceableLoadingData == nil then
        return
    end
    local path = ServerRules.getSettingsDirectory() .. ServerRules.SETTINGS_FILENAME
    if not fileExists(path) then
        return
    end
    local xml = loadXMLFile("ServerRulesTest", path)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while i < 20 do
        local key = string.format("serverRules.test.placeable(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local want = string.lower(getXMLString(xml, key .. "#xml") or "")
        local x = getXMLFloat(xml, key .. "#x") or 0
        local z = getXMLFloat(xml, key .. "#z") or 0
        local farm = getXMLInt(xml, key .. "#farm") or 0
        local storeItem = nil
        for _, si in ipairs(g_storeManager:getItems()) do
            if want ~= "" and si.xmlFilenameLower ~= nil and string.find(si.xmlFilenameLower, want, 1, true) ~= nil then
                storeItem = si
                break
            end
        end
        if storeItem == nil then
            ServerRules.log("Test: Artikel '%s' nicht im Shop", want)
        else
            ServerRules.log("Test: Artikel im Shop: '%s' Preis %s, Datei %s, Bild %s", tostring(storeItem.name),
                tostring(storeItem.price), tostring(storeItem.xmlFilename), tostring(storeItem.imageFilename))
            local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
            local data = PlaceableLoadingData.new()
            data:setStoreItem(storeItem)
            data:setOwnerFarmId(farm)
            local landOwner = g_farmlandManager ~= nil and g_farmlandManager:getOwnerIdAtWorldPosition(x, z) or "?"
            ServerRules.log("Test: Platz %.0f/%.0f, Land gehoert Hof %s, Gebaeude fuer Hof %d", x, z, tostring(landOwner), farm)
            data:setPosition(x, y, z)
            data:setRotation(0, 0, 0)
            if data.setIsSaved ~= nil then
                data:setIsSaved(false)
            end
            local ok, err = pcall(data.load, data, ServerRulesBuild.onTestLoaded, ServerRulesBuild, {name = tostring(storeItem.name)})
            if not ok then
                ServerRules.log("Test: Laden fehlgeschlagen: %s", tostring(err))
            end
        end
        i = i + 1
    end
    delete(xml)
end

function ServerRulesBuild.onTestLoaded(target, placeable, loadingState, args)
    local name = type(args) == "table" and args.name or "?"
    if type(placeable) == "table" and placeable[1] ~= nil and placeable.rootNode == nil then
        placeable = placeable[1]
    end
    local okState = PlaceableLoadingState ~= nil and loadingState == PlaceableLoadingState.OK
    if type(placeable) == "table" and placeable.rootNode ~= nil then
        ServerRules.log("Test: '%s' geladen (Status %s, ok=%s), i3d %s, Besitzer %s", name, tostring(loadingState), tostring(okState),
            tostring(placeable.i3dFilename), tostring(placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or "?"))
        table.insert(ServerRulesBuild.testPlaceables, placeable)
        ServerRulesBuild.testDeleteTimer = 5000
    else
        ServerRules.log("Test: '%s' NICHT geladen (Status %s)", name, tostring(loadingState))
    end
end

function ServerRulesBuild.update(dt)
    if ServerRulesBuild.testDeleteTimer ~= nil then
        ServerRulesBuild.testDeleteTimer = ServerRulesBuild.testDeleteTimer - dt
        if ServerRulesBuild.testDeleteTimer <= 0 then
            ServerRulesBuild.testDeleteTimer = nil
            for _, p in ipairs(ServerRulesBuild.testPlaceables) do
                local ok, err = pcall(p.delete, p)
                ServerRules.log("Test: Gebaeude wieder entfernt (ok=%s %s)", tostring(ok), ok and "" or tostring(err))
            end
            ServerRulesBuild.testPlaceables = {}
        end
    end
end
