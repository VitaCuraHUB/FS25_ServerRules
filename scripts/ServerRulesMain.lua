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
    local settings, warnings = ServerRulesSettings.load(path)
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
    local fingerprint = ServerRulesPrices.getFingerprint(overrides)
    ServerRules.settings = settings
    if fingerprint == ServerRules.fingerprint and not isStart then
        return
    end

    for _, w in ipairs(warnings) do
        ServerRules.log("Warnung: %s", w)
    end
    ServerRules.overrides = overrides
    ServerRules.fingerprint = fingerprint
    ServerRules.revision = ServerRules.revision + 1
    local applied, unknown = ServerRulesPrices.applyOverrides(overrides)
    ServerRules.log("Werte geladen (Stand %d): %d Preisregeln, %d Artikel geaendert, %d Regeln ohne Treffer, %d unbekannt",
        ServerRules.revision, #settings.priceRules, applied, unused, unknown)

    if settings.writeCheckFile then
        ServerRules.writeCheckFile()
    end
    if not isStart then
        ServerRules.broadcastSnapshot()
    end
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
    saveXMLFile(xml)
    delete(xml)
    ServerRules.log("Kontrolldatei geschrieben: %s (%d Artikel)", path, i)
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
end

function ServerRules.broadcastSnapshot()
    if g_server == nil then
        return
    end
    local chunks, count = buildChunks()
    for i, entries in ipairs(chunks) do
        g_server:broadcastEvent(ServerRulesSyncEvent.new(ServerRules.revision, i, count, entries), false)
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
end

function listener:deleteMap()
    ServerRulesPrices.resetAll()
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
    if g_server ~= nil then
        local interval = ServerRules.settings ~= nil and ServerRules.settings.reloadInterval or 60
        if interval > 0 then
            ServerRules.reloadTimer = ServerRules.reloadTimer + dt
            if ServerRules.reloadTimer >= interval * 1000 then
                ServerRules.reloadTimer = 0
                ServerRules.reloadSettings(false)
            end
        end
    elseif g_client ~= nil and not ServerRules.client.synced then
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
