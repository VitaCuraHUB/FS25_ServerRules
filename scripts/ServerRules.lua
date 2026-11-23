-- FS25_ServerRules - core namespace and helpers
-- All game values are decided by the server. Clients only receive and display them.

ServerRules = {}
ServerRules.MOD_NAME = g_currentModName
ServerRules.MOD_DIR = g_currentModDirectory
ServerRules.VERSION = "0.5.0"
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
    rules = nil,                  -- production/storage/fillType rules received from the server
    rulesRevision = -1,
    rulesPending = nil,
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
    return ServerRules.getFileKey(storeItem.xmlFilename, storeItem.customEnvironment, storeItem.baseDir)
end

---Same key for any xml file of the game or a mod (see getItemKey)
function ServerRules.getFileKey(filename, customEnvironment, baseDir)
    local fn = normalizePath(filename)
    local lower = string.lower(fn)
    if customEnvironment ~= nil and baseDir ~= nil and baseDir ~= "" then
        local base = string.lower(normalizePath(baseDir))
        if string.sub(lower, 1, string.len(base)) == base then
            local rel = string.sub(lower, string.len(base) + 1)
            rel = string.gsub(rel, "^/+", "")
            return string.lower(customEnvironment) .. "/" .. rel
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

---Round a price to a "smooth" value (Alex: no odd prices):
-- < 2.000 -> 100, < 10.000 -> 500, < 100.000 -> 1.000, < 1 Mio -> 5.000, else 50.000
function ServerRules.roundPrice(p)
    if p == nil or p <= 0 then
        return p
    end
    local step = 50000
    if p < 2000 then
        step = 100
    elseif p < 10000 then
        step = 500
    elseif p < 100000 then
        step = 1000
    elseif p < 1000000 then
        step = 5000
    end
    local r = math.floor(p / step + 0.5) * step
    if r <= 0 then
        r = step
    end
    return r
end

---Round a daily upkeep: < 100 -> 1, < 1.000 -> 5, else 10
function ServerRules.roundUpkeep(u)
    if u == nil or u <= 0 then
        return u
    end
    local step = 10
    if u < 100 then
        step = 1
    elseif u < 1000 then
        step = 5
    end
    return math.floor(u / step + 0.5) * step
end
