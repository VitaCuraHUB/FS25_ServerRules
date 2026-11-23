-- FS25_ServerRules - roles per farm (stage 3)
--
-- Settings (serverRules.xml):
-- <roles mode="block">                        block = forbid, warn = only message + log
--   <role id="contractor" name="Lohnbetrieb" description="Transport, Abfahren, Auftraege">
--     <buy default="allow">                   allow|deny, then rules (most specific wins)
--       <rule action="deny" category="harvesters"/>
--       <rule action="deny" species="placeable" category="productionPoints"/>
--       <rule action="allow" item="data/vehicles/.../x.xml"/>
--     </buy>
--     <missions default="allow">
--       <rule action="deny" type="harvest"/>  type = part of the mission type name (case-insensitive)
--     </missions>
--     <loan max="0"/>                          maximum loan in EUR (nothing = no limit)
--     <sell default="allow">                  selling/unloading at selling points not owned by the farm
--       <rule action="deny" fillType="WHEAT"/>
--     </sell>
--   </role>
-- </roles>
-- Which farm has which role is set in game (admin, menu) and saved in the savegame
-- (savegameX/serverRules-roles.xml).

ServerRulesRoles = {}
ServerRulesRoles.assignment = {}    -- farmId -> roleId (server: authoritative, client: copy)
ServerRulesRoles.dirty = false
ServerRulesRoles.ROLES_FILENAME = "serverRules-roles.xml"

---------------------------------------------------------------------------------------------------
-- Texts (sent as key + arguments; each player sees his own language)

ServerRulesRoles.TEXTS = {
    de = {
        buyDenied = "Als %s darfst du das nicht kaufen: %s",
        buyWarn = "Hinweis (Rolle %s): %s waere gesperrt",
        missionDenied = "Als %s darfst du diesen Auftrag nicht annehmen.",
        loanLimited = "Als %s ist dein Kredit auf %s begrenzt - der Rest wurde zurueckgezahlt.",
        loanWarn = "Hinweis: Als %s waere dein Kredit auf %s begrenzt.",
        sellDenied = "Als %s darfst du hier %s nicht abladen oder verkaufen.",
        freeDenied = "Kostenlos kaufen darf nur der Admin.",
        roleSet = "Hof %s hat jetzt die Rolle %s.",
        notAdmin = "Nur der Admin (im Spiel als Admin angemeldet) kann Rollen vergeben.",
        reloaded = "Einstellungen neu geladen (Stand %s).",
        menuTitle = "Server-Regeln",
        noRole = "keine Rolle",
        yourFarm = "Dein Hof: %s - Rolle: %s",
        farmsHeader = "Alle Hoefe:",
        rulesHeader = "Deine Regeln:",
        adminChooseFarm = "Hof waehlen, dann die Rolle:",
        adminReload = "Einstellungen neu laden",
        adminShowOnly = "Nur anzeigen",
        chooseRole = "Rolle fuer %s:",
        buyAllAllowed = "Kaufen: alles erlaubt",
        buyAllDenied = "Kaufen: alles gesperrt",
        buyExcept = "ausser",
        missionsAll = "Auftraege: alle erlaubt",
        missionsNone = "Auftraege: keine",
        loanText = "Kredit: hoechstens %s",
        sellText = "Verkaufen an fremden Stellen: %s",
        allowed = "erlaubt",
        denied = "gesperrt",
        notSynced = "Die Regeln werden noch vom Server geladen - bitte kurz warten."
    },
    en = {
        buyDenied = "As %s you may not buy this: %s",
        buyWarn = "Note (role %s): %s would be blocked",
        missionDenied = "As %s you may not accept this contract.",
        loanLimited = "As %s your loan is limited to %s - the rest was paid back.",
        loanWarn = "Note: as %s your loan would be limited to %s.",
        sellDenied = "As %s you may not unload or sell %s here.",
        freeDenied = "Only the admin may buy for free.",
        roleSet = "Farm %s now has the role %s.",
        notAdmin = "Only the admin (logged in as admin in game) can assign roles.",
        reloaded = "Settings reloaded (revision %s).",
        menuTitle = "Server Rules",
        noRole = "no role",
        yourFarm = "Your farm: %s - role: %s",
        farmsHeader = "All farms:",
        rulesHeader = "Your rules:",
        adminChooseFarm = "Choose a farm, then the role:",
        adminReload = "Reload settings",
        adminShowOnly = "Only show",
        chooseRole = "Role for %s:",
        buyAllAllowed = "Buying: everything allowed",
        buyAllDenied = "Buying: everything blocked",
        buyExcept = "except",
        missionsAll = "Contracts: all allowed",
        missionsNone = "Contracts: none",
        loanText = "Loan: at most %s",
        sellText = "Selling at other selling points: %s",
        allowed = "allowed",
        denied = "blocked",
        notSynced = "The rules are still loading from the server - please wait a moment."
    }
}

function ServerRulesRoles.text(key, ...)
    -- German unless the game clearly runs in English (our players are German)
    local lang = (g_languageShortName == "en") and "en" or "de"
    local t = ServerRulesRoles.TEXTS[lang][key] or ServerRulesRoles.TEXTS.de[key] or key
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, t, ...)
        if ok then
            return s
        end
    end
    return t
end

---------------------------------------------------------------------------------------------------
-- Settings

local function readStr(xml, key)
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

local function readRuleList(xml, key, fields)
    local list = {}
    local i = 0
    while true do
        local k = string.format("%s.rule(%d)", key, i)
        if not hasXMLProperty(xml, k) then
            break
        end
        local r = {order = i, action = string.lower(readStr(xml, k .. "#action") or "deny")}
        local score = 0
        for field, weight in pairs(fields) do
            local v = readStr(xml, k .. "#" .. field)
            if v ~= nil then
                if field == "item" then
                    v = ServerRules.normalizeKey(v)
                elseif field == "fillType" then
                    v = string.upper(v)
                else
                    v = string.lower(v)
                end
                r[field] = v
                score = score + weight
            end
        end
        r.score = score
        table.insert(list, r)
        i = i + 1
    end
    return list
end

ServerRulesRoles.BUY_FIELDS = {item = 1000, mod = 100, category = 10, brand = 10, species = 3, source = 1}
ServerRulesRoles.MISSION_FIELDS = {type = 1}
ServerRulesRoles.SELL_FIELDS = {fillType = 1}

function ServerRulesRoles.loadFromXML(xml, settings, warnings)
    settings.roles = {}
    settings.rolesById = {}
    settings.rolesMode = string.lower(readStr(xml, "serverRules.roles#mode") or "block")
    if settings.rolesMode ~= "block" and settings.rolesMode ~= "warn" then
        table.insert(warnings, "roles#mode muss block oder warn sein - nehme block")
        settings.rolesMode = "block"
    end
    local i = 0
    while true do
        local key = string.format("serverRules.roles.role(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local id = readStr(xml, key .. "#id")
        if id == nil or settings.rolesById[string.lower(id)] ~= nil then
            table.insert(warnings, string.format("Rolle %d: id fehlt oder doppelt - ignoriert", i + 1))
        else
            id = string.lower(id)
            local role = {
                id = id,
                name = readStr(xml, key .. "#name") or id,
                description = readStr(xml, key .. "#description") or "",
                buyDefault = string.lower(readStr(xml, key .. ".buy#default") or "allow"),
                buyRules = readRuleList(xml, key .. ".buy", ServerRulesRoles.BUY_FIELDS),
                missionsDefault = string.lower(readStr(xml, key .. ".missions#default") or "allow"),
                missionRules = readRuleList(xml, key .. ".missions", ServerRulesRoles.MISSION_FIELDS),
                loanMax = tonumber(readStr(xml, key .. ".loan#max") or ""),
                sellDefault = string.lower(readStr(xml, key .. ".sell#default") or "allow"),
                sellRules = readRuleList(xml, key .. ".sell", ServerRulesRoles.SELL_FIELDS)
            }
            table.insert(settings.roles, role)
            settings.rolesById[id] = role
        end
        i = i + 1
    end
end

-- text form for clients (appended to the rules text, see ServerRulesSettings.serializeRules)
local SEP = "\t"
local function enc(v)
    if v == nil then
        return ""
    end
    return (string.gsub(tostring(v), "[\t\n]", " "))
end
local function dec(s)
    if s == nil or s == "" then
        return nil
    end
    return s
end

function ServerRulesRoles.serialize(settings, lines)
    table.insert(lines, table.concat({"RMODE", enc(settings.rolesMode)}, SEP))
    for _, role in ipairs(settings.roles or {}) do
        table.insert(lines, table.concat({"R", enc(role.id), enc(role.name), enc(role.description), enc(role.buyDefault),
            enc(role.missionsDefault), enc(role.loanMax), enc(role.sellDefault)}, SEP))
        for _, r in ipairs(role.buyRules) do
            table.insert(lines, table.concat({"RB", enc(role.id), enc(r.order), enc(r.action), enc(r.item), enc(r.mod), enc(r.category),
                enc(r.brand), enc(r.species), enc(r.source), enc(r.score)}, SEP))
        end
        for _, r in ipairs(role.missionRules) do
            table.insert(lines, table.concat({"RM", enc(role.id), enc(r.order), enc(r.action), enc(r.type), enc(r.score)}, SEP))
        end
        for _, r in ipairs(role.sellRules) do
            table.insert(lines, table.concat({"RS", enc(role.id), enc(r.order), enc(r.action), enc(r.fillType), enc(r.score)}, SEP))
        end
    end
end

function ServerRulesRoles.deserializeLine(rules, f)
    rules.roles = rules.roles or {}
    rules.rolesById = rules.rolesById or {}
    local kind = f[1]
    if kind == "RMODE" then
        rules.rolesMode = dec(f[2]) or "block"
    elseif kind == "R" then
        local role = {id = dec(f[2]), name = dec(f[3]) or dec(f[2]), description = dec(f[4]) or "", buyDefault = dec(f[5]) or "allow",
            missionsDefault = dec(f[6]) or "allow", loanMax = tonumber(f[7] or ""), sellDefault = dec(f[8]) or "allow",
            buyRules = {}, missionRules = {}, sellRules = {}}
        if role.id ~= nil then
            table.insert(rules.roles, role)
            rules.rolesById[role.id] = role
        end
    elseif kind == "RB" or kind == "RM" or kind == "RS" then
        local role = rules.rolesById[dec(f[2]) or ""]
        if role ~= nil then
            if kind == "RB" then
                table.insert(role.buyRules, {order = tonumber(f[3]) or 0, action = dec(f[4]) or "deny", item = dec(f[5]), mod = dec(f[6]),
                    category = dec(f[7]), brand = dec(f[8]), species = dec(f[9]), source = dec(f[10]), score = tonumber(f[11]) or 0})
            elseif kind == "RM" then
                table.insert(role.missionRules, {order = tonumber(f[3]) or 0, action = dec(f[4]) or "deny", type = dec(f[5]), score = tonumber(f[6]) or 0})
            else
                table.insert(role.sellRules, {order = tonumber(f[3]) or 0, action = dec(f[4]) or "deny", fillType = dec(f[5]), score = tonumber(f[6]) or 0})
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Rule checks

local function better(rule, best)
    if best == nil then
        return true
    end
    if rule.score ~= best.score then
        return rule.score > best.score
    end
    return rule.order > best.order
end

function ServerRulesRoles.getRules()
    return ServerRules.getActiveRules()
end

function ServerRulesRoles.getRoleOfFarm(farmId)
    local rules = ServerRulesRoles.getRules()
    if rules == nil or rules.rolesById == nil or farmId == nil then
        return nil
    end
    local id = ServerRulesRoles.assignment[farmId]
    if id == nil then
        return nil
    end
    return rules.rolesById[id]
end

function ServerRulesRoles.getMode()
    local rules = ServerRulesRoles.getRules()
    return (rules ~= nil and rules.rolesMode) or "block"
end

---@return boolean allowed
function ServerRulesRoles.canBuy(role, storeItem)
    if role == nil or storeItem == nil then
        return true
    end
    local info = ServerRulesPrices.getItemInfo(storeItem)
    local best = nil
    for _, r in ipairs(role.buyRules) do
        if ServerRulesPrices.matchesItem(r, storeItem, info) and better(r, best) then
            best = r
        end
    end
    local action = best ~= nil and best.action or role.buyDefault
    return action ~= "deny"
end

function ServerRulesRoles.getMissionTypeName(mission)
    local name = nil
    if mission ~= nil then
        if mission.getMissionTypeName ~= nil then
            local ok, n = pcall(mission.getMissionTypeName, mission)
            if ok then
                name = n
            end
        end
        if name == nil and mission.type ~= nil then
            name = mission.type.name
        end
    end
    return string.lower(tostring(name or "unknown"))
end

function ServerRulesRoles.canTakeMission(role, mission)
    if role == nil then
        return true
    end
    local typeName = ServerRulesRoles.getMissionTypeName(mission)
    local best = nil
    for _, r in ipairs(role.missionRules) do
        if (r.type == nil or string.find(typeName, r.type, 1, true) ~= nil) and better(r, best) then
            best = r
        end
    end
    local action = best ~= nil and best.action or role.missionsDefault
    return action ~= "deny"
end

function ServerRulesRoles.canSell(role, fillTypeIndex)
    if role == nil then
        return true
    end
    local name = nil
    if g_fillTypeManager ~= nil and fillTypeIndex ~= nil then
        name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    end
    name = string.upper(tostring(name or ""))
    local best = nil
    for _, r in ipairs(role.sellRules) do
        if (r.fillType == nil or r.fillType == name) and better(r, best) then
            best = r
        end
    end
    local action = best ~= nil and best.action or role.sellDefault
    return action ~= "deny"
end

---------------------------------------------------------------------------------------------------
-- Users and farms (server)

function ServerRulesRoles.getUserOfConnection(connection)
    if connection == nil or g_currentMission == nil or g_currentMission.userManager == nil then
        return nil
    end
    return g_currentMission.userManager:getUserByConnection(connection)
end

function ServerRulesRoles.getFarmIdOfConnection(connection)
    local user = ServerRulesRoles.getUserOfConnection(connection)
    if user == nil or g_farmManager == nil then
        return nil
    end
    local farm = g_farmManager:getFarmByUserId(user:getId())
    if farm ~= nil then
        return farm.farmId
    end
    return nil
end

function ServerRulesRoles.isAdminConnection(connection)
    if connection == nil then
        return false
    end
    if not connection:getIsServer() then
        local user = ServerRulesRoles.getUserOfConnection(connection)
        return user ~= nil and user:getIsMasterUser() == true
    end
    return false
end

function ServerRulesRoles.getFarmName(farmId)
    if g_farmManager ~= nil then
        local farm = g_farmManager:getFarmById(farmId)
        if farm ~= nil and farm.name ~= nil then
            return farm.name
        end
    end
    return tostring(farmId)
end

function ServerRulesRoles.formatMoney(v)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, 0, true, true)
        if ok and s ~= nil then
            return s
        end
    end
    return string.format("%d EUR", math.floor(v + 0.5))
end

---Server: tell one connection (or all players of a farm) something
function ServerRulesRoles.notify(connection, key, ...)
    local args = {...}
    for i, a in ipairs(args) do
        args[i] = tostring(a)
    end
    if connection ~= nil and not connection:getIsServer() then
        connection:sendEvent(ServerRulesNotifyEvent.new(key, args))
    elseif g_client ~= nil then
        -- hosting player / local
        ServerRulesRoles.showNotification(key, args)
    end
end

function ServerRulesRoles.notifyFarm(farmId, key, ...)
    if g_server == nil or g_currentMission == nil or g_currentMission.userManager == nil then
        return
    end
    local args = {...}
    for i, a in ipairs(args) do
        args[i] = tostring(a)
    end
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm == nil or farm.userIdToPlayer == nil then
        return
    end
    for userId, _ in pairs(farm.userIdToPlayer) do
        local user = g_currentMission.userManager:getUserByUserId(userId)
        if user ~= nil and user.getConnection ~= nil then
            local con = user:getConnection()
            if con ~= nil and not con:getIsServer() then
                con:sendEvent(ServerRulesNotifyEvent.new(key, args))
            end
        end
    end
end

ServerRulesRoles.DIALOG_KEYS = {buyDenied = true, missionDenied = true, sellDenied = true, freeDenied = true, notAdmin = true}
ServerRulesRoles.dialogQueue = {}

function ServerRulesRoles.showNotification(key, args)
    if g_currentMission == nil then
        return
    end
    local text = ServerRulesRoles.text(key, unpack(args or {}))
    if g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL or 1, text)
    end
    if ServerRulesRoles.DIALOG_KEYS[key] and InfoDialog ~= nil then
        -- shown a moment later, so it replaces the game's own (more general) message
        table.insert(ServerRulesRoles.dialogQueue, {text = text, at = (g_time or 0) + 700})
    end
end

function ServerRulesRoles.updateClient()
    local q = ServerRulesRoles.dialogQueue
    if #q == 0 or g_time == nil then
        return
    end
    if g_time >= q[1].at then
        local entry = table.remove(q, 1)
        pcall(InfoDialog.show, entry.text)
    end
end

---------------------------------------------------------------------------------------------------
-- Assignment: set, save, load, sync

function ServerRulesRoles.setRole(farmId, roleId)
    if roleId == "" then
        roleId = nil
    end
    ServerRulesRoles.assignment[farmId] = roleId
    ServerRulesRoles.dirty = true
    ServerRulesRoles.save()
    ServerRulesRoles.broadcastState()
    ServerRules.log("Rolle gesetzt: Hof %s -> %s", tostring(farmId), tostring(roleId))
end

function ServerRulesRoles.getSavePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil or info.savegameDirectory == nil then
        return nil
    end
    return info.savegameDirectory .. "/" .. ServerRulesRoles.ROLES_FILENAME
end

function ServerRulesRoles.save()
    if g_server == nil or not ServerRulesRoles.loaded then
        return
    end
    local path = ServerRulesRoles.getSavePath()
    if path == nil then
        return
    end
    local xml = createXMLFile("ServerRulesRoles", path, "serverRulesRoles")
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    for farmId, roleId in pairs(ServerRulesRoles.assignment) do
        local key = string.format("serverRulesRoles.farm(%d)", i)
        setXMLInt(xml, key .. "#id", farmId)
        setXMLString(xml, key .. "#role", roleId)
        i = i + 1
    end
    saveXMLFile(xml)
    delete(xml)
    ServerRulesRoles.dirty = false
end

function ServerRulesRoles.load()
    ServerRulesRoles.assignment = {}
    local path = ServerRulesRoles.getSavePath()
    if path == nil then
        return 0
    end
    if not fileExists(path) then
        ServerRulesRoles.loaded = true
        return 0
    end
    local xml = loadXMLFile("ServerRulesRoles", path)
    if xml == nil or xml == 0 then
        -- unreadable: do not overwrite it later with an empty assignment
        ServerRules.log("FEHLER: Rollen-Zuordnung nicht lesbar: %s (wird nicht ueberschrieben)", path)
        return 0
    end
    ServerRulesRoles.loaded = true
    local i, n = 0, 0
    while true do
        local key = string.format("serverRulesRoles.farm(%d)", i)
        if not hasXMLProperty(xml, key) then
            break
        end
        local farmId = getXMLInt(xml, key .. "#id")
        local roleId = getXMLString(xml, key .. "#role")
        if farmId ~= nil and roleId ~= nil then
            ServerRulesRoles.assignment[farmId] = string.lower(roleId)
            n = n + 1
        end
        i = i + 1
    end
    delete(xml)
    return n
end

function ServerRulesRoles.getStateList()
    local list = {}
    for farmId, roleId in pairs(ServerRulesRoles.assignment) do
        table.insert(list, {farmId = farmId, roleId = roleId})
    end
    return list
end

function ServerRulesRoles.sendState(connection)
    connection:sendEvent(ServerRulesRoleStateEvent.new(ServerRulesRoles.getStateList()))
end

function ServerRulesRoles.broadcastState()
    if g_server ~= nil then
        g_server:broadcastEvent(ServerRulesRoleStateEvent.new(ServerRulesRoles.getStateList()), false)
    end
end

---------------------------------------------------------------------------------------------------
-- Loan limit (server, checked every few seconds)

ServerRulesRoles.loanTimer = 0

function ServerRulesRoles.update(dt)
    if g_server == nil or g_farmManager == nil then
        return
    end
    ServerRulesRoles.loanTimer = ServerRulesRoles.loanTimer + dt
    if ServerRulesRoles.loanTimer < 5000 then
        return
    end
    ServerRulesRoles.loanTimer = 0
    for farmId, _ in pairs(ServerRulesRoles.assignment) do
        local role = ServerRulesRoles.getRoleOfFarm(farmId)
        if role ~= nil and role.loanMax ~= nil then
            local farm = g_farmManager:getFarmById(farmId)
            if farm ~= nil and farm.loan ~= nil and farm.loan > role.loanMax + 0.5 then
                local excess = farm.loan - role.loanMax
                ServerRulesRoles.loanNotified = ServerRulesRoles.loanNotified or {}
                if ServerRulesRoles.getMode() == "block" then
                    -- pay back the part above the limit from the farm account (only lower the loan if paying worked)
                    local mt = MoneyType ~= nil and (MoneyType.LOAN or MoneyType.OTHER) or nil
                    local ok, err = false, "addMoney fehlt"
                    if g_currentMission.addMoney ~= nil and mt ~= nil then
                        ok, err = pcall(g_currentMission.addMoney, g_currentMission, -excess, farmId, mt, true, true)
                    end
                    if ok then
                        farm.loan = role.loanMax
                        ServerRules.log("Kredit begrenzt: Hof %d auf %d (zurueckgezahlt %d)", farmId, role.loanMax, excess)
                        ServerRulesRoles.notifyFarm(farmId, "loanLimited", role.name, ServerRulesRoles.formatMoney(role.loanMax))
                    elseif ServerRulesRoles.loanNotified[farmId] ~= farm.loan then
                        ServerRulesRoles.loanNotified[farmId] = farm.loan
                        ServerRules.log("FEHLER Kreditbegrenzung Hof %d: %s", farmId, tostring(err))
                    end
                elseif ServerRulesRoles.loanNotified[farmId] ~= farm.loan then
                    ServerRulesRoles.loanNotified[farmId] = farm.loan
                    ServerRules.log("Kredit ueber dem Limit (warn): Hof %d %d > %d", farmId, farm.loan, role.loanMax)
                    ServerRulesRoles.notifyFarm(farmId, "loanWarn", role.name, ServerRulesRoles.formatMoney(role.loanMax))
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Diagnostics: write which game functions/constants exist (helps after game patches)

function ServerRulesRoles.logDiagnostics()
    local function has(t, f)
        return t ~= nil and t[f] ~= nil
    end
    ServerRules.log("Diagnose: BuyVehicleEvent.run=%s BuyPlaceableEvent.run=%s BuyHandToolEvent.run=%s",
        tostring(has(BuyVehicleEvent, "run")), tostring(has(BuyPlaceableEvent, "run")), tostring(has(BuyHandToolEvent, "run")))
    if BuyVehicleEvent ~= nil then
        local s = {}
        for k, v in pairs(BuyVehicleEvent) do
            if type(k) == "string" and string.sub(k, 1, 6) == "STATE_" then
                table.insert(s, k .. "=" .. tostring(v))
            end
        end
        table.sort(s)
        ServerRules.log("Diagnose: BuyVehicleEvent %s", table.concat(s, " "))
    end
    if BuyPlaceableEvent ~= nil then
        local s = {}
        for k, v in pairs(BuyPlaceableEvent) do
            if type(k) == "string" and string.sub(k, 1, 6) == "STATE_" then
                table.insert(s, k .. "=" .. tostring(v))
            end
        end
        table.sort(s)
        ServerRules.log("Diagnose: BuyPlaceableEvent %s", table.concat(s, " "))
    end
    if MissionStartState ~= nil then
        local s = {}
        for k, v in pairs(MissionStartState) do
            table.insert(s, tostring(k) .. "=" .. tostring(v))
        end
        table.sort(s)
        ServerRules.log("Diagnose: MissionStartState %s", table.concat(s, " "))
    end
    ServerRules.log("Diagnose: MissionManager.startMission=%s UnloadTrigger.getIsFillAllowedFromFarm=%s UnloadTrigger.addFillUnitFillLevel=%s Farm.MAX_LOAN=%s MoneyType.LOAN=%s",
        tostring(has(MissionManager, "startMission")), tostring(has(UnloadTrigger, "getIsFillAllowedFromFarm")),
        tostring(has(UnloadTrigger, "addFillUnitFillLevel")), tostring(Farm ~= nil and Farm.MAX_LOAN or nil),
        tostring(MoneyType ~= nil and MoneyType.LOAN ~= nil))
end

---------------------------------------------------------------------------------------------------
-- Hooks (server side enforcement)

local function checkPurchase(self, connection, storeItem, isFreeOfCharge, ownerFarmId)
    -- @return boolean allowed, string reasonKey
    if g_server == nil or connection == nil or connection:getIsServer() then
        return true
    end
    local isAdmin = ServerRulesRoles.isAdminConnection(connection)
    if isFreeOfCharge and not isAdmin then
        ServerRules.log("Kauf ohne Kosten abgelehnt (kein Admin)")
        ServerRulesRoles.notify(connection, "freeDenied")
        return false
    end
    -- role rules apply to everybody, also to the admin (the admin plays too)
    local farmId = ServerRulesRoles.getFarmIdOfConnection(connection)
    local farms = {farmId}
    if ownerFarmId ~= nil and ownerFarmId ~= farmId then
        table.insert(farms, ownerFarmId)
    end
    for _, fid in ipairs(farms) do
        local role = ServerRulesRoles.getRoleOfFarm(fid)
        if role ~= nil and storeItem ~= nil and not ServerRulesRoles.canBuy(role, storeItem) then
            local name = tostring(storeItem.name)
            if ServerRulesRoles.getMode() == "block" then
                ServerRules.log("Kauf gesperrt: Hof %s (%s) %s", tostring(fid), role.id, ServerRules.getItemKey(storeItem))
                ServerRulesRoles.notify(connection, "buyDenied", role.name, name)
                return false
            else
                ServerRules.log("Kauf waere gesperrt (warn): Hof %s (%s) %s", tostring(fid), role.id, ServerRules.getItemKey(storeItem))
                ServerRulesRoles.notify(connection, "buyWarn", role.name, name)
            end
        end
    end
    return true
end

local function denyState(eventClass)
    if eventClass ~= nil then
        return eventClass.STATE_NO_PERMISSION or eventClass.STATE_FAILED or eventClass.STATE_NOT_ENOUGH_MONEY or 1
    end
    return 1
end

local function hookBuyEvent(eventClass, dataField, className)
    if eventClass == nil or eventClass.run == nil then
        ServerRules.log("Warnung: %s.run fehlt - Kaufsperre dafuer inaktiv", className)
        return
    end
    eventClass.run = Utils.overwrittenFunction(eventClass.run, function(self, superFunc, connection, ...)
        local data = self[dataField]
        if data == nil and connection ~= nil and not connection:getIsServer() and not eventClass.__serverRulesWarned then
            eventClass.__serverRulesWarned = true
            ServerRules.log("Warnung: %s.%s fehlt - Kaufsperre dafuer wirkungslos", className, dataField)
        end
        if data ~= nil and connection ~= nil and not connection:getIsServer() then
            local ok, allowed = pcall(checkPurchase, self, connection, data.storeItem, data.isFreeOfCharge, data.ownerFarmId)
            if ok and not allowed then
                if eventClass.newServerToClient ~= nil then
                    local okSend, errSend = pcall(function()
                        connection:sendEvent(eventClass.newServerToClient(denyState(eventClass), data))
                    end)
                    if not okSend then
                        ServerRules.log("Warnung: Ablehnung an Mitspieler nicht sendbar (%s): %s", className, tostring(errSend))
                    end
                end
                return
            elseif not ok then
                ServerRules.log("FEHLER Kaufpruefung: %s", tostring(allowed))
            end
        end
        return superFunc(self, connection, ...)
    end)
end

function ServerRulesRoles.installHooks()
    hookBuyEvent(BuyVehicleEvent, "vehicleBuyData", "BuyVehicleEvent")
    hookBuyEvent(BuyPlaceableEvent, "placeableBuyData", "BuyPlaceableEvent")
    hookBuyEvent(BuyHandToolEvent, "handToolBuyData", "BuyHandToolEvent")

    -- buying an existing building of the map (e.g. a map production)
    if BuyExistingPlaceableEvent ~= nil and BuyExistingPlaceableEvent.run ~= nil then
        BuyExistingPlaceableEvent.run = Utils.overwrittenFunction(BuyExistingPlaceableEvent.run, function(self, superFunc, connection, ...)
            if connection ~= nil and not connection:getIsServer() and self.placeable ~= nil and self.placeable.configFileName ~= nil and g_storeManager ~= nil then
                local storeItem = g_storeManager:getItemByXMLFilename(self.placeable.configFileName)
                local ok, allowed = pcall(checkPurchase, self, connection, storeItem, false, self.farmId)
                if ok and not allowed then
                    return
                end
            end
            return superFunc(self, connection, ...)
        end)
    else
        ServerRules.log("Warnung: BuyExistingPlaceableEvent.run fehlt - Kaufsperre fuer Karten-Gebaeude inaktiv")
    end

    if MissionManager ~= nil and MissionManager.startMission ~= nil then
        MissionManager.startMission = Utils.overwrittenFunction(MissionManager.startMission, function(self, superFunc, mission, farmId, ...)
            if type(farmId) == "number" then
                local role = ServerRulesRoles.getRoleOfFarm(farmId)
                if role ~= nil and not ServerRulesRoles.canTakeMission(role, mission) then
                    local typeName = ServerRulesRoles.getMissionTypeName(mission)
                    if ServerRulesRoles.getMode() == "block" then
                        ServerRules.log("Auftrag gesperrt: Hof %d (%s) Typ %s", farmId, role.id, typeName)
                        ServerRulesRoles.notifyFarm(farmId, "missionDenied", role.name)
                        if MissionStartState ~= nil then
                            return MissionStartState.NO_PERMISSION or MissionStartState.NO_ACCESS or MissionStartState.CANNOT_BE_STARTED_NOW
                        end
                        return nil
                    end
                    ServerRules.log("Auftrag waere gesperrt (warn): Hof %d (%s) Typ %s", farmId, role.id, typeName)
                end
            end
            return superFunc(self, mission, farmId, ...)
        end)
    else
        ServerRules.log("Warnung: MissionManager.startMission fehlt - Auftragsregeln inaktiv")
    end

    -- selling / unloading at selling points that the farm does not own
    if UnloadTrigger ~= nil and UnloadTrigger.getFillUnitFreeCapacity ~= nil then
        UnloadTrigger.getFillUnitFreeCapacity = Utils.overwrittenFunction(UnloadTrigger.getFillUnitFreeCapacity, function(self, superFunc, fillUnitIndex, fillTypeIndex, farmId, ...)
            local cap = superFunc(self, fillUnitIndex, fillTypeIndex, farmId, ...)
            if cap ~= nil and cap > 0 and type(farmId) == "number" and ServerRulesRoles.isForeignSellingPoint(self, farmId) then
                local role = ServerRulesRoles.getRoleOfFarm(farmId)
                if role ~= nil and not ServerRulesRoles.canSell(role, fillTypeIndex) then
                    -- this is called every frame while unloading: message at most every 15 s per farm and good
                    if g_server ~= nil then
                        ServerRulesRoles.sellNotified = ServerRulesRoles.sellNotified or {}
                        local k = tostring(farmId) .. ":" .. tostring(fillTypeIndex)
                        local now = g_time or 0
                        if (ServerRulesRoles.sellNotified[k] or -100000) + 15000 < now then
                            ServerRulesRoles.sellNotified[k] = now
                            local title = tostring(fillTypeIndex)
                            if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeTitleByIndex ~= nil then
                                title = tostring(g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex))
                            end
                            ServerRules.log("Verkauf %s: Hof %d (%s) Ware %s", ServerRulesRoles.getMode() == "block" and "gesperrt" or "waere gesperrt (warn)", farmId, role.id, title)
                            ServerRulesRoles.notifyFarm(farmId, "sellDenied", role.name, title)
                        end
                    end
                    if ServerRulesRoles.getMode() == "block" then
                        return 0
                    end
                end
            end
            return cap
        end)
    else
        ServerRules.log("Warnung: UnloadTrigger.getFillUnitFreeCapacity fehlt - Verkaufsregeln inaktiv")
    end
end

---A selling point is "foreign" when it is not owned by the farm (map selling points, other farms)
function ServerRulesRoles.isForeignSellingPoint(trigger, farmId)
    local target = trigger.target
    if target == nil then
        return false
    end
    -- only selling stations count (not own silos, husbandries, productions of the farm)
    local isSelling = SellingStation ~= nil and target.isa ~= nil and target:isa(SellingStation)
    if not isSelling then
        return false
    end
    local owner = nil
    if target.getOwnerFarmId ~= nil then
        owner = target:getOwnerFarmId()
    end
    return owner ~= farmId
end

---------------------------------------------------------------------------------------------------
-- Events

ServerRulesNotifyEvent = {}
local ServerRulesNotifyEvent_mt = Class(ServerRulesNotifyEvent, Event)
InitEventClass(ServerRulesNotifyEvent, "ServerRulesNotifyEvent")

function ServerRulesNotifyEvent.emptyNew()
    return Event.new(ServerRulesNotifyEvent_mt)
end

function ServerRulesNotifyEvent.new(key, args)
    local self = ServerRulesNotifyEvent.emptyNew()
    self.key = key
    self.args = args or {}
    return self
end

function ServerRulesNotifyEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.key)
    streamWriteUInt8(streamId, math.min(#self.args, 8))
    for i = 1, math.min(#self.args, 8) do
        streamWriteString(streamId, self.args[i])
    end
end

function ServerRulesNotifyEvent:readStream(streamId, connection)
    self.key = streamReadString(streamId)
    local n = streamReadUInt8(streamId)
    self.args = {}
    for i = 1, n do
        self.args[i] = streamReadString(streamId)
    end
    self:run(connection)
end

function ServerRulesNotifyEvent:run(connection)
    if connection ~= nil and connection:getIsServer() then
        ServerRulesRoles.showNotification(self.key, self.args)
    end
end

ServerRulesRoleStateEvent = {}
local ServerRulesRoleStateEvent_mt = Class(ServerRulesRoleStateEvent, Event)
InitEventClass(ServerRulesRoleStateEvent, "ServerRulesRoleStateEvent")

function ServerRulesRoleStateEvent.emptyNew()
    return Event.new(ServerRulesRoleStateEvent_mt)
end

function ServerRulesRoleStateEvent.new(list)
    local self = ServerRulesRoleStateEvent.emptyNew()
    self.list = list or {}
    return self
end

function ServerRulesRoleStateEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, math.min(#self.list, 255))
    for i = 1, math.min(#self.list, 255) do
        streamWriteUInt8(streamId, self.list[i].farmId)
        streamWriteString(streamId, self.list[i].roleId or "")
    end
end

function ServerRulesRoleStateEvent:readStream(streamId, connection)
    local n = streamReadUInt8(streamId)
    self.list = {}
    for i = 1, n do
        local farmId = streamReadUInt8(streamId)
        local roleId = streamReadString(streamId)
        table.insert(self.list, {farmId = farmId, roleId = roleId})
    end
    self:run(connection)
end

function ServerRulesRoleStateEvent:run(connection)
    if connection ~= nil and connection:getIsServer() and g_server == nil then
        ServerRulesRoles.assignment = {}
        for _, e in ipairs(self.list) do
            if e.roleId ~= "" then
                ServerRulesRoles.assignment[e.farmId] = e.roleId
            end
        end
    end
end

-- client -> server: admin actions ("setRole" farmId roleId, "reload")
ServerRulesAdminEvent = {}
local ServerRulesAdminEvent_mt = Class(ServerRulesAdminEvent, Event)
InitEventClass(ServerRulesAdminEvent, "ServerRulesAdminEvent")

function ServerRulesAdminEvent.emptyNew()
    return Event.new(ServerRulesAdminEvent_mt)
end

function ServerRulesAdminEvent.new(action, farmId, roleId)
    local self = ServerRulesAdminEvent.emptyNew()
    self.action = action
    self.farmId = farmId or 0
    self.roleId = roleId or ""
    return self
end

function ServerRulesAdminEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.action)
    streamWriteUInt8(streamId, self.farmId)
    streamWriteString(streamId, self.roleId)
end

function ServerRulesAdminEvent:readStream(streamId, connection)
    self.action = streamReadString(streamId)
    self.farmId = streamReadUInt8(streamId)
    self.roleId = streamReadString(streamId)
    self:run(connection)
end

function ServerRulesAdminEvent:run(connection)
    if g_server == nil or connection == nil or connection:getIsServer() then
        return
    end
    -- identity only from the connection, never from the client
    if not ServerRulesRoles.isAdminConnection(connection) then
        ServerRules.log("Admin-Aktion '%s' abgelehnt: kein Admin", tostring(self.action))
        ServerRulesRoles.notify(connection, "notAdmin")
        return
    end
    ServerRulesRoles.runAdminAction(self.action, self.farmId, self.roleId, connection)
end

---Server: executes an admin action (also used by a hosting player directly)
function ServerRulesRoles.runAdminAction(action, farmId, roleId, connection)
    if action == "setRole" then
        local rules = ServerRules.settings
        if roleId ~= "" and (rules == nil or rules.rolesById == nil or rules.rolesById[roleId] == nil) then
            return
        end
        if g_farmManager == nil or g_farmManager:getFarmById(farmId) == nil then
            return
        end
        ServerRulesRoles.setRole(farmId, roleId)
        local role = rules ~= nil and rules.rolesById ~= nil and rules.rolesById[roleId] or nil
        ServerRulesRoles.notify(connection, "roleSet", ServerRulesRoles.getFarmName(farmId), role ~= nil and role.name or ServerRulesRoles.text("noRole"))
    elseif action == "reload" then
        ServerRules.reloadSettings(false)
        ServerRulesRoles.notify(connection, "reloaded", tostring(ServerRules.revision))
    end
end
