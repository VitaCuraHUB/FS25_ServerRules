-- FS25_ServerRules - network events
--
-- ServerRulesSyncEvent        server -> client   one chunk of the current value snapshot
-- ServerRulesRequestSyncEvent client -> server   "please send me the snapshot" (no payload)
--
-- Values only ever travel from the server to the clients. Nothing a client sends changes any value.

---------------------------------------------------------------------------------------------------
ServerRulesSyncEvent = {}
local ServerRulesSyncEvent_mt = Class(ServerRulesSyncEvent, Event)
InitEventClass(ServerRulesSyncEvent, "ServerRulesSyncEvent")

function ServerRulesSyncEvent.emptyNew()
    return Event.new(ServerRulesSyncEvent_mt)
end

function ServerRulesSyncEvent.new(revision, chunkIndex, chunkCount, entries)
    local self = ServerRulesSyncEvent.emptyNew()
    self.revision = revision
    self.chunkIndex = chunkIndex
    self.chunkCount = chunkCount
    self.entries = entries
    return self
end

function ServerRulesSyncEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.revision)
    streamWriteUInt16(streamId, self.chunkIndex)
    streamWriteUInt16(streamId, self.chunkCount)
    streamWriteUInt16(streamId, #self.entries)
    for _, e in ipairs(self.entries) do
        streamWriteString(streamId, e.key)
        streamWriteFloat32(streamId, e.price)
        streamWriteFloat32(streamId, e.priceFactor)
        streamWriteFloat32(streamId, e.upkeep)
        streamWriteFloat32(streamId, e.upkeepFactor)
        streamWriteString(streamId, e.name or "")
        streamWriteString(streamId, e.nameSuffix or "")
    end
end

function ServerRulesSyncEvent:readStream(streamId, connection)
    self.revision = streamReadInt32(streamId)
    self.chunkIndex = streamReadUInt16(streamId)
    self.chunkCount = streamReadUInt16(streamId)
    local n = streamReadUInt16(streamId)
    self.entries = {}
    for _ = 1, n do
        local e = {}
        e.key = streamReadString(streamId)
        e.price = streamReadFloat32(streamId)
        e.priceFactor = streamReadFloat32(streamId)
        e.upkeep = streamReadFloat32(streamId)
        e.upkeepFactor = streamReadFloat32(streamId)
        e.name = streamReadString(streamId)
        e.nameSuffix = streamReadString(streamId)
        table.insert(self.entries, e)
    end
    self:run(connection)
end

function ServerRulesSyncEvent:run(connection)
    -- only accept values that come from the server
    if connection ~= nil and connection:getIsServer() then
        ServerRules.onSyncChunk(self.revision, self.chunkIndex, self.chunkCount, self.entries)
    end
end

---------------------------------------------------------------------------------------------------
-- ServerRulesRulesEvent  server -> client  one chunk of the production/storage/fillType rules (text)
ServerRulesRulesEvent = {}
local ServerRulesRulesEvent_mt = Class(ServerRulesRulesEvent, Event)
InitEventClass(ServerRulesRulesEvent, "ServerRulesRulesEvent")

function ServerRulesRulesEvent.emptyNew()
    return Event.new(ServerRulesRulesEvent_mt)
end

function ServerRulesRulesEvent.new(revision, chunkIndex, chunkCount, text)
    local self = ServerRulesRulesEvent.emptyNew()
    self.revision = revision
    self.chunkIndex = chunkIndex
    self.chunkCount = chunkCount
    self.text = text
    return self
end

function ServerRulesRulesEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.revision)
    streamWriteUInt16(streamId, self.chunkIndex)
    streamWriteUInt16(streamId, self.chunkCount)
    streamWriteString(streamId, self.text or "")
end

function ServerRulesRulesEvent:readStream(streamId, connection)
    self.revision = streamReadInt32(streamId)
    self.chunkIndex = streamReadUInt16(streamId)
    self.chunkCount = streamReadUInt16(streamId)
    self.text = streamReadString(streamId)
    self:run(connection)
end

function ServerRulesRulesEvent:run(connection)
    if connection ~= nil and connection:getIsServer() then
        ServerRules.onRulesChunk(self.revision, self.chunkIndex, self.chunkCount, self.text)
    end
end

---------------------------------------------------------------------------------------------------
ServerRulesRequestSyncEvent = {}
local ServerRulesRequestSyncEvent_mt = Class(ServerRulesRequestSyncEvent, Event)
InitEventClass(ServerRulesRequestSyncEvent, "ServerRulesRequestSyncEvent")

function ServerRulesRequestSyncEvent.emptyNew()
    return Event.new(ServerRulesRequestSyncEvent_mt)
end

function ServerRulesRequestSyncEvent.new()
    return ServerRulesRequestSyncEvent.emptyNew()
end

function ServerRulesRequestSyncEvent:writeStream(streamId, connection)
end

function ServerRulesRequestSyncEvent:readStream(streamId, connection)
    self:run(connection)
end

function ServerRulesRequestSyncEvent:run(connection)
    if connection ~= nil and not connection:getIsServer() and g_server ~= nil then
        -- at most one full snapshot per connection every 5 s
        ServerRules.lastRequest = ServerRules.lastRequest or setmetatable({}, {__mode = "k"})
        local now = g_time or 0
        if ServerRules.lastRequest[connection] ~= nil and now - ServerRules.lastRequest[connection] < 5000 then
            return
        end
        ServerRules.lastRequest[connection] = now
        ServerRules.sendSnapshot(connection)
    end
end
