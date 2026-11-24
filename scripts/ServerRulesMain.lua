-- FS25_ServerRules - start, sync and hooks

---------------------------------------------------------------------------------------------------
-- Server side
---------------------------------------------------------------------------------------------------

---Reads the settings file and applies it. Broadcasts to all clients if anything changed.
-- @param boolean isStart true at server start (always logs a summary)
function ServerRules.reloadSettings(isStart)
    local path = ServerRules.getSettingsPath()
    if isStart and not fileExists(path) then
        if ServerRulesSettings.createDefault(path) then
            ServerRules.log("Leere Einstellungsdatei angelegt: %s", path)
        end
    end
    local settings, warnings = ServerRulesSettings.loadAll(ServerRules.getSettingsDirectory())
    if settings == nil then
        local errorText = table.concat(warnings, " | ")
        if isStart or errorText ~= ServerRules.lastLoadError then
            for _, w in ipairs(warnings) do
                ServerRules.log("FEHLER: %s", w)
            end
            ServerRules.log("Es bleiben die bisherigen Werte (%s).", ServerRules.settings ~= nil and "letzte gueltige Datei" or "Spielstandard")
        end
        ServerRules.lastLoadError = errorText
        return
    end
    ServerRules.lastLoadError = nil

    local overrides, unused = ServerRulesPrices.computeOverrides(settings)
    local rulesText = ServerRulesSettings.serializeRules(settings)
    local fingerprint = ServerRulesPrices.getFingerprint(overrides) .. "#" .. rulesText
    ServerRules.settings = settings
    if fingerprint == ServerRules.fingerprint and not isStart then
        return
    end

    for _, w in ipairs(warnings) do
        ServerRules.log("Warnung: %s", w)
    end
    ServerRules.overrides = overrides
    ServerRules.rulesText = rulesText
    ServerRules.fingerprint = fingerprint
    ServerRules.revision = ServerRules.revision + 1
    local applied, unknown = ServerRulesPrices.applyOverrides(overrides)
    ServerRules.log("Werte geladen (Stand %d): %d Preisregeln, %d Artikel geaendert, %d Regeln ohne Treffer, %d unbekannt",
        ServerRules.revision, #settings.priceRules, applied, unused, unknown)
    local points, productions, storage = ServerRulesProductions.applyAll(settings)
    local unknownFillTypes = ServerRulesProductions.setFillTypeFactors(settings)
    ServerRules.log("Produktionen: %d Regeln, %d Lagerregeln -> %d Gebaeude, %d Rezepte, %d Lagerplaetze geaendert (von %d Produktionsstaetten); Warenpreise: %d Regeln, %d unbekannt",
        #settings.productionRules, #settings.storageRules, points, productions, storage, #ServerRulesProductions.points, #settings.fillTypeRules, unknownFillTypes)

    if settings.writeCheckFile then
        ServerRules.writeCheckFile()
    end
    if not isStart then
        ServerRules.broadcastSnapshot()
    end
end

-- ages (months) at which the animal curves are sampled for the balance report
local ANIMAL_AGES = {0, 3, 6, 12, 18, 24, 36, 60, 120}

local function writeCurve(xml, key, curve)
    if type(curve) ~= "table" or curve.get == nil then
        return
    end
    for j, age in ipairs(ANIMAL_AGES) do
        local ok, v = pcall(curve.get, curve, age)
        if ok and type(v) == "number" then
            setXMLFloat(xml, string.format("%s.value(%d)#age", key, j - 1), age)
            setXMLFloat(xml, string.format("%s.value(%d)#v", key, j - 1), v)
        end
    end
end

local function fillTypeName(index)
    if index == nil or g_fillTypeManager == nil then
        return ""
    end
    return tostring(g_fillTypeManager:getFillTypeNameByIndex(index))
end

---Balance data: per animal sub type the input/output curves per age (read only, for the report)
function ServerRules.writeAnimalData(xml, baseKey)
    local as = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if as == nil or as.getSubTypeByIndex == nil then
        return 0
    end
    local n = 0
    local index = 1
    while index < 1000 do
        local st = as:getSubTypeByIndex(index)
        if st == nil then
            break
        end
        local key = string.format("%s.subType(%d)", baseKey, n)
        setXMLString(xml, key .. "#name", tostring(st.name))
        local t = st.typeIndex ~= nil and as.getTypeByIndex ~= nil and as:getTypeByIndex(st.typeIndex) or nil
        setXMLString(xml, key .. "#type", t ~= nil and tostring(t.name) or "")
        if st.fillTypeIndex ~= nil then
            setXMLString(xml, key .. "#fillType", fillTypeName(st.fillTypeIndex))
        end
        writeCurve(xml, key .. ".buyPrice", st.buyPrice)
        writeCurve(xml, key .. ".sellPrice", st.sellPrice)
        if type(st.input) == "table" then
            for name, curve in pairs(st.input) do
                writeCurve(xml, string.format("%s.input.%s", key, tostring(name)), curve)
            end
        end
        if type(st.output) == "table" then
            for name, out in pairs(st.output) do
                local okey = string.format("%s.output.%s", key, tostring(name))
                if type(out) == "table" and out.curve ~= nil then
                    setXMLString(xml, okey .. "#fillType", fillTypeName(out.fillType))
                    writeCurve(xml, okey, out.curve)
                else
                    writeCurve(xml, okey, out)
                end
            end
        end
        if n == 0 then
            -- once: field names, so unknown structures can be found in the log
            local names = {}
            for k2, _ in pairs(st) do
                table.insert(names, tostring(k2))
            end
            table.sort(names)
            ServerRules.log("Tier-Untertyp Felder: %s", table.concat(names, ","))
        end
        n = n + 1
        index = index + 1
    end
    setXMLInt(xml, baseKey .. "#count", n)
    ServerRules.log("Tierdaten geschrieben: %d Untertypen", n)
    return n
end

---Writes the values that are really in effect now (read back from the store items) to
-- modSettings/FS25_ServerRules/serverRules-check.xml, so the admin can verify them without a client.
function ServerRules.writeCheckFile()
    local path = ServerRules.getSettingsDirectory() .. "serverRules-check.xml"
    local xml = createXMLFile("ServerRulesCheck", path, "serverRulesCheck")
    if xml == nil or xml == 0 then
        ServerRules.log("Warnung: Kontrolldatei nicht schreibbar: %s", path)
        return
    end
    setXMLInt(xml, "serverRulesCheck#revision", ServerRules.revision)
    setXMLString(xml, "serverRulesCheck#version", ServerRules.VERSION)
    local i = 0
    for _, storeItem in ipairs(ServerRulesPrices.applied) do
        local o = ServerRulesPrices.originals[storeItem] or {}
        local key = string.format("serverRulesCheck.item(%d)", i)
        setXMLString(xml, key .. "#key", ServerRules.getItemKey(storeItem))
        setXMLString(xml, key .. "#name", tostring(storeItem.name))
        setXMLFloat(xml, key .. "#price", storeItem.price or 0)
        setXMLFloat(xml, key .. "#originalPrice", o.price or 0)
        setXMLFloat(xml, key .. "#dailyUpkeep", storeItem.dailyUpkeep or 0)
        setXMLFloat(xml, key .. "#originalDailyUpkeep", o.dailyUpkeep or 0)
        if StoreItemUtil ~= nil and StoreItemUtil.getDefaultPrice ~= nil and storeItem.defaultConfigurationIds ~= nil then
            local ok, p = pcall(StoreItemUtil.getDefaultPrice, storeItem, storeItem.defaultConfigurationIds)
            if ok and p ~= nil then
                setXMLFloat(xml, key .. "#defaultConfigPrice", p)
            end
        end
        i = i + 1
    end
    local n = ServerRulesProductions.writeCheck(xml, "serverRulesCheck.productions")
    -- selling prices: effective price (per 1000 l) at the first selling point that buys the good
    local stations = {}
    local em = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if em ~= nil and em.sellingStations ~= nil then
        for _, entry in pairs(em.sellingStations) do
            local st = entry
            if type(entry) == "table" and entry.getEffectiveFillTypePrice == nil and entry.station ~= nil then
                st = entry.station
            end
            if type(st) == "table" and st.getEffectiveFillTypePrice ~= nil then
                table.insert(stations, st)
            end
        end
    end
    local k = 0
    for index, factor in pairs(ServerRulesProductions.fillTypeFactors) do
        local key = string.format("serverRulesCheck.sellPrices.fillType(%d)", k)
        setXMLString(xml, key .. "#name", tostring(g_fillTypeManager:getFillTypeNameByIndex(index)))
        setXMLFloat(xml, key .. "#factor", factor)
        for _, st in ipairs(stations) do
            local ok, price = pcall(st.getEffectiveFillTypePrice, st, index)
            if ok and price ~= nil and price > 0 then
                setXMLFloat(xml, key .. "#pricePer1000", price * 1000)
                setXMLFloat(xml, key .. "#pricePer1000WithoutFactor", price * 1000 / factor)
                break
            end
        end
        k = k + 1
    end
    setXMLInt(xml, "serverRulesCheck.sellPrices#stations", #stations)
    local okA, nA = pcall(ServerRules.writeAnimalData, xml, "serverRulesCheck.animals")
    if not okA then
        ServerRules.log("Warnung: Tierdaten nicht lesbar: %s", tostring(nA))
    end
    saveXMLFile(xml)
    delete(xml)
    ServerRules.log("Kontrolldatei geschrieben: %s (%d Artikel, %d Produktionsgebaeude)", path, i, n)
end

---Server: rules in effect (loads the file early if production points load before the mission is ready).
-- Client: rules received from the server (nil until then).
function ServerRules.getActiveRules()
    if g_server ~= nil then
        if ServerRules.settings == nil and not ServerRules.triedEarlyLoad then
            ServerRules.triedEarlyLoad = true
            local settings = ServerRulesSettings.loadAll(ServerRules.getSettingsDirectory())
            if settings ~= nil then
                ServerRules.settings = settings
                ServerRules.log("Einstellungen frueh geladen (fuer Produktionen beim Laden des Spielstands)")
            end
        end
        return ServerRules.settings
    end
    return ServerRules.client.rules
end

local RULES_CHUNK_SIZE = 8000

local function buildRuleChunks()
    local text = ServerRules.rulesText or ""
    local chunks = {}
    local pos = 1
    repeat
        table.insert(chunks, string.sub(text, pos, pos + RULES_CHUNK_SIZE - 1))
        pos = pos + RULES_CHUNK_SIZE
    until pos > string.len(text)
    return chunks
end

local function buildChunks()
    local list = ServerRules.overrides or {}
    local size = ServerRules.SYNC_CHUNK_SIZE
    local count = math.max(1, math.ceil(#list / size))
    local chunks = {}
    for c = 1, count do
        local entries = {}
        for i = (c - 1) * size + 1, math.min(c * size, #list) do
            table.insert(entries, list[i])
        end
        table.insert(chunks, entries)
    end
    return chunks, count
end

function ServerRules.sendSnapshot(connection)
    local chunks, count = buildChunks()
    for i, entries in ipairs(chunks) do
        connection:sendEvent(ServerRulesSyncEvent.new(ServerRules.revision, i, count, entries))
    end
    local ruleChunks = buildRuleChunks()
    for i, text in ipairs(ruleChunks) do
        connection:sendEvent(ServerRulesRulesEvent.new(ServerRules.revision, i, #ruleChunks, text))
    end
    ServerRulesRoles.sendState(connection)
end

function ServerRules.broadcastSnapshot()
    if g_server == nil then
        return
    end
    local chunks, count = buildChunks()
    for i, entries in ipairs(chunks) do
        g_server:broadcastEvent(ServerRulesSyncEvent.new(ServerRules.revision, i, count, entries), false)
    end
    local ruleChunks = buildRuleChunks()
    for i, text in ipairs(ruleChunks) do
        g_server:broadcastEvent(ServerRulesRulesEvent.new(ServerRules.revision, i, #ruleChunks, text), false)
    end
end

---Client: one chunk of the production/storage/fillType rules arrived
function ServerRules.onRulesChunk(revision, chunkIndex, chunkCount, text)
    if g_server ~= nil then
        return
    end
    local c = ServerRules.client
    if c.rulesPending == nil or c.rulesPending.revision ~= revision then
        if c.rulesPending ~= nil and revision < c.rulesPending.revision then
            return
        end
        c.rulesPending = {revision = revision, count = chunkCount, chunks = {}, received = 0}
    end
    if c.rulesPending.chunks[chunkIndex] == nil then
        c.rulesPending.chunks[chunkIndex] = text
        c.rulesPending.received = c.rulesPending.received + 1
    end
    if c.rulesPending.received >= c.rulesPending.count then
        local parts = {}
        for i = 1, c.rulesPending.count do
            table.insert(parts, c.rulesPending.chunks[i] or "")
        end
        c.rules = ServerRulesSettings.deserializeRules(table.concat(parts))
        c.rulesRevision = revision
        c.rulesPending = nil
        local points, productions, storage = ServerRulesProductions.applyAll(c.rules)
        ServerRules.log("Produktionsregeln vom Server uebernommen (Stand %d): %d Gebaeude, %d Rezepte, %d Lagerplaetze geaendert",
            revision, points, productions, storage)
        local names = {}
        for _, role in ipairs(c.rules.roles or {}) do
            table.insert(names, tostring(role.name))
        end
        ServerRules.log("Rollen vom Server: %d (%s), Sprache %s", #names, table.concat(names, ", "), tostring(g_languageShortName))
    end
end

---------------------------------------------------------------------------------------------------
-- Client side
---------------------------------------------------------------------------------------------------

function ServerRules.onSyncChunk(revision, chunkIndex, chunkCount, entries)
    if g_server ~= nil then
        return -- the server (also a hosting player) already has the values
    end
    local c = ServerRules.client
    if c.pending == nil or c.pending.revision ~= revision then
        if c.pending ~= nil and revision < c.pending.revision then
            return -- outdated chunk
        end
        c.pending = {revision = revision, count = chunkCount, chunks = {}, received = 0}
    end
    if c.pending.chunks[chunkIndex] == nil then
        c.pending.chunks[chunkIndex] = entries
        c.pending.received = c.pending.received + 1
    end
    if c.pending.received >= c.pending.count then
        local list = {}
        for i = 1, c.pending.count do
            for _, e in ipairs(c.pending.chunks[i] or {}) do
                table.insert(list, e)
            end
        end
        local applied, unknown = ServerRulesPrices.applyOverrides(list)
        c.revision = revision
        c.synced = true
        c.pending = nil
        ServerRules.log("Werte vom Server uebernommen (Stand %d): %d Artikel geaendert, %d unbekannt", revision, applied, unknown)
    end
end

function ServerRules.requestSync()
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local con = g_client:getServerConnection()
        if con ~= nil then
            con:sendEvent(ServerRulesRequestSyncEvent.new())
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Mod event listener
---------------------------------------------------------------------------------------------------

local listener = {}

function listener:loadMap(filename)
    ServerRules.log("Version %s geladen (%s)", ServerRules.VERSION, g_server ~= nil and "Server" or "Client")
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.CURRENT_MISSION_LOADED ~= nil then
        g_messageCenter:subscribeOneshot(MessageType.CURRENT_MISSION_LOADED, ServerRules.onAllLoaded, ServerRules)
    end
end

---Everything incl. the savegame placeables is loaded (production points load after loadMission00Finished)
function ServerRules.onAllLoaded()
    if g_server == nil then
        return
    end
    -- roles first: even with a broken settings file the assignment must not get lost
    local n = ServerRulesRoles.load()
    if ServerRules.settings == nil then
        ServerRules.log("Rollen: %d Hoefe mit Rolle (Einstellungen fehlen oder sind fehlerhaft)", n)
        return
    end
    local s = ServerRules.settings
    local points, productions, storage = ServerRulesProductions.applyAll(s)
    ServerRules.log("Spielstand geladen: %d Produktionsstaetten, davon %d Gebaeude angepasst (%d Rezepte, %d Lagerplaetze)",
        #ServerRulesProductions.points, points, productions, storage)
    ServerRules.log("Rollen: %d definiert (Modus %s), %d Hoefe mit Rolle", #(s.roles or {}), tostring(s.rolesMode), n)
    ServerRulesRoles.logDiagnostics()
    local okB, errB = pcall(ServerRulesBuild.logDiagnostics)
    if not okB then
        ServerRules.log("Warnung: Diagnose Bauen: %s", tostring(errB))
    end
    local okT, errT = pcall(ServerRulesBuild.runPlacementTest)
    if not okT then
        ServerRules.log("Warnung: Test-Platzierung: %s", tostring(errT))
    end
    -- run the production check once now (an empty dedicated server is paused and does not update)
    ServerRulesProductions.checkTimer = 10000
    ServerRulesProductions.update(0)
    if s.writeCheckFile then
        ServerRules.writeCheckFile()
    end
end

function listener:deleteMap()
    ServerRulesRoles.assignment = {}
    ServerRulesRoles.loaded = false
    ServerRulesPrices.resetAll()
    ServerRulesProductions.applyAll(nil)
    ServerRulesProductions.points = {}
    ServerRulesProductions.originals = {}
    ServerRulesProductions.fillTypeFactors = {}
    ServerRules.triedEarlyLoad = false
    ServerRules.rulesText = nil
    ServerRules.client.rules = nil
    ServerRules.client.rulesRevision = -1
    ServerRules.client.rulesPending = nil
    ServerRules.isInitialized = false
    ServerRules.settings = nil
    ServerRules.overrides = {}
    ServerRules.fingerprint = ""
    ServerRules.client.synced = false
    ServerRules.client.pending = nil
    ServerRules.client.revision = -1
end

function listener:update(dt)
    if not ServerRules.isInitialized then
        return
    end
    if g_client ~= nil then
        ServerRulesRoles.updateClient()
    end
    if g_server ~= nil then
        ServerRulesRoles.update(dt)
        ServerRulesProductions.update(dt)
        ServerRulesBuild.update(dt)
        local interval = ServerRules.settings ~= nil and ServerRules.settings.reloadInterval or 60
        if interval > 0 then
            ServerRules.reloadTimer = ServerRules.reloadTimer + dt
            if ServerRules.reloadTimer >= interval * 1000 then
                ServerRules.reloadTimer = 0
                ServerRules.reloadSettings(false)
            end
        end
    elseif g_client ~= nil and (not ServerRules.client.synced or ServerRules.client.rulesRevision ~= ServerRules.client.revision) then
        local now = g_time or 0
        if now - ServerRules.client.lastRequestTime > ServerRules.CLIENT_RESYNC_INTERVAL then
            ServerRules.client.lastRequestTime = now
            ServerRules.requestSync()
        end
    end
end

addModEventListener(listener)

---------------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------------

local function onMissionLoaded()
    if ServerRules.isInitialized then
        return
    end
    ServerRules.isInitialized = true
    if g_server ~= nil then
        ServerRules.reloadSettings(true)
    else
        -- the server sends the values when we finished loading; ask once more after a short while
        ServerRules.client.lastRequestTime = g_time or 0
    end
end

if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function(mission, ...)
        onMissionLoaded()
    end)
else
    ServerRules.log("FEHLER: Mission00.loadMission00Finished fehlt - Mod inaktiv")
end

if FSBaseMission ~= nil and FSBaseMission.onConnectionFinishedLoading ~= nil then
    FSBaseMission.onConnectionFinishedLoading = Utils.appendedFunction(FSBaseMission.onConnectionFinishedLoading, function(mission, connection, ...)
        if g_server ~= nil and connection ~= nil and ServerRules.isInitialized then
            -- a dedicated server pauses while empty (no update), so check the file now
            ServerRules.reloadSettings(false)
            ServerRules.sendSnapshot(connection)
        end
    end)
else
    ServerRules.log("Warnung: FSBaseMission.onConnectionFinishedLoading fehlt - Clients fragen die Werte selbst an")
end

-- roles: purchase/contract/selling checks, saving the assignment with the savegame
ServerRulesRoles.installHooks()
-- building outside the own land (I-34)
ServerRulesBuild.installHooks()

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function(missionInfo, ...)
        if g_server ~= nil and ServerRules.isInitialized then
            local ok, err = pcall(ServerRulesRoles.save)
            if not ok then
                ServerRules.log("FEHLER beim Speichern der Rollen: %s", tostring(err))
            end
        end
    end)
else
    ServerRules.log("Warnung: FSCareerMissionInfo.saveToXMLFile fehlt - Rollen werden nur bei Aenderung gespeichert")
end
