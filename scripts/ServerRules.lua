-- FS25_ServerRules - core namespace and helpers
-- All game values are decided by the server. Clients only receive and display them.

ServerRules = {}
ServerRules.MOD_NAME = g_currentModName
ServerRules.MOD_DIR = g_currentModDirectory
ServerRules.VERSION = "0.1.0"
ServerRules.SETTINGS_FILENAME = "serverRules.xml"
ServerRules.SYNC_CHUNK_SIZE = 100
ServerRules.CLIENT_RESYNC_INTERVAL = 10000 -- ms

ServerRules.isInitialized = false
ServerRules.revision = 0          -- server: current revision of synced values
ServerRules.overrides = {}        -- server: last computed list of price overrides
ServerRules.fingerprint = ""      -- server: to detect changes of the settings file
ServerRules.settings = nil        -- server: parsed settings
ServerRules.reloadTimer = 0

ServerRules.client = {
    synced = false,
    revision = -1,
    pending = nil,                -- {revision, count, chunks = {}, received}
    lastRequestTime = 0
}

function ServerRules.log(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then
        text = tostring(fmt)
    end
    print("[ServerRules] " .. text)
end

function ServerRules.getIsServer()
    return g_server ~= nil
end

function ServerRules.getIsPureClient()
    return g_client ~= nil and g_server == nil
end

local function normalizePath(path)
    if path == nil then
        return ""
    end
    local p = string.gsub(path, "\\", "/")
    return p
end

---Returns a key for a store item that is the same on server and all clients:
-- mods:      "<modname>/<path inside mod>"   e.g. "fs25_example/xml/bakery.xml"
-- base game: "data/<path>"                   e.g. "data/placeables/brandless/bakery/bakery.xml"
-- Always lower case.
function ServerRules.getItemKey(storeItem)
    local fn = normalizePath(storeItem.xmlFilename)
    local lower = string.lower(fn)
    if storeItem.customEnvironment ~= nil and storeItem.baseDir ~= nil and storeItem.baseDir ~= "" then
        local base = string.lower(normalizePath(storeItem.baseDir))
        if string.sub(lower, 1, string.len(base)) == base then
            local rel = string.sub(lower, string.len(base) + 1)
            rel = string.gsub(rel, "^/+", "")
            return string.lower(storeItem.customEnvironment) .. "/" .. rel
        end
    end
    if string.sub(lower, 1, 5) == "data/" then
        return lower
    end
    local i = string.find(lower, "/data/", 1, true)
    if i ~= nil then
        return string.sub(lower, i + 1)
    end
    return lower
end

---Normalizes a key written by a human in the settings file
function ServerRules.normalizeKey(key)
    if key == nil then
        return nil
    end
    local k = string.lower(normalizePath(key))
    k = string.gsub(k, "^%$moddir%$", "")
    k = string.gsub(k, "^/+", "")
    return k
end

function ServerRules.getSettingsDirectory()
    return getUserProfileAppPath() .. "modSettings/" .. ServerRules.MOD_NAME .. "/"
end

function ServerRules.getSettingsPath()
    return ServerRules.getSettingsDirectory() .. ServerRules.SETTINGS_FILENAME
end
