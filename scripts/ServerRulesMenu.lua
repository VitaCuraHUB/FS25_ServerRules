-- FS25_ServerRules - in-game window (key, default Ctrl+R): own role and rules, all farms;
-- for the admin (logged in as admin in game): assign roles per farm, reload settings.
-- Uses only the game's own dialogs (InfoDialog, OptionDialog), no own GUI files.

ServerRulesMenu = {}

local function T(key, ...)
    return ServerRulesRoles.text(key, ...)
end

local function getFarms()
    local list = {}
    if g_farmManager ~= nil and g_farmManager.getFarms ~= nil then
        for _, farm in pairs(g_farmManager:getFarms()) do
            if farm.farmId ~= nil and farm.farmId ~= 0 and (FarmManager == nil or farm.farmId ~= FarmManager.SPECTATOR_FARM_ID) then
                table.insert(list, farm)
            end
        end
    end
    table.sort(list, function(a, b) return a.farmId < b.farmId end)
    return list
end

local function roleName(farmId)
    local role = ServerRulesRoles.getRoleOfFarm(farmId)
    return role ~= nil and role.name or T("noRole")
end

local function describeRole(role)
    local lines = {}
    if role == nil then
        return T("buyAllAllowed")
    end
    if role.description ~= nil and role.description ~= "" then
        table.insert(lines, role.description)
    end
    local exceptions = {}
    for _, r in ipairs(role.buyRules) do
        local what = r.item or r.mod or r.category or r.brand or r.species or r.source or "?"
        table.insert(exceptions, what)
    end
    local buy = role.buyDefault == "deny" and T("buyAllDenied") or T("buyAllAllowed")
    if #exceptions > 0 then
        buy = buy .. " " .. T("buyExcept") .. ": " .. table.concat(exceptions, ", ")
    end
    table.insert(lines, buy)
    if #role.missionRules == 0 then
        table.insert(lines, role.missionsDefault == "deny" and T("missionsNone") or T("missionsAll"))
    else
        local m = {}
        for _, r in ipairs(role.missionRules) do
            table.insert(m, (r.action == "deny" and "-" or "+") .. tostring(r.type))
        end
        table.insert(lines, (role.missionsDefault == "deny" and T("missionsNone") or T("missionsAll")) .. " (" .. table.concat(m, ", ") .. ")")
    end
    if role.loanMax ~= nil then
        table.insert(lines, T("loanText", ServerRulesRoles.formatMoney(role.loanMax)))
    end
    local sell = role.sellDefault == "deny" and T("denied") or T("allowed")
    if #role.sellRules > 0 then
        local s = {}
        for _, r in ipairs(role.sellRules) do
            table.insert(s, (r.action == "deny" and "-" or "+") .. tostring(r.fillType))
        end
        sell = sell .. " (" .. table.concat(s, ", ") .. ")"
    end
    table.insert(lines, T("sellText", sell))
    return table.concat(lines, "\n")
end

function ServerRulesMenu.getOverviewText()
    local myFarm = g_currentMission ~= nil and g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId() or nil
    local lines = {}
    if myFarm ~= nil and myFarm ~= 0 then
        table.insert(lines, T("yourFarm", ServerRulesRoles.getFarmName(myFarm), roleName(myFarm)))
        table.insert(lines, "")
        table.insert(lines, T("rulesHeader"))
        table.insert(lines, describeRole(ServerRulesRoles.getRoleOfFarm(myFarm)))
        table.insert(lines, "")
    end
    table.insert(lines, T("farmsHeader"))
    for _, farm in ipairs(getFarms()) do
        table.insert(lines, string.format("- %s: %s", tostring(farm.name), roleName(farm.farmId)))
    end
    return table.concat(lines, "\n")
end

local function sendAdmin(action, farmId, roleId)
    if g_server ~= nil then
        ServerRulesRoles.runAdminAction(action, farmId, roleId, nil)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(ServerRulesAdminEvent.new(action, farmId, roleId))
    end
end

function ServerRulesMenu.chooseRole(farm)
    local rules = ServerRulesRoles.getRules()
    local roles = (rules ~= nil and rules.roles) or {}
    local options = {T("noRole")}
    for _, role in ipairs(roles) do
        table.insert(options, role.name)
    end
    OptionDialog.show(function(index)
        if index == nil or index < 1 then
            return
        end
        local roleId = ""
        if index > 1 and roles[index - 1] ~= nil then
            roleId = roles[index - 1].id
        end
        sendAdmin("setRole", farm.farmId, roleId)
    end, T("menuTitle"), T("chooseRole", tostring(farm.name)), options)
end

function ServerRulesMenu.open()
    if g_gui == nil or g_currentMission == nil then
        return
    end
    if g_server == nil and not (ServerRules.client.synced and ServerRules.client.rules ~= nil) then
        InfoDialog.show(T("notSynced"))
        return
    end
    local text = ServerRulesMenu.getOverviewText()
    if not g_currentMission.isMasterUser then
        InfoDialog.show(text)
        return
    end
    local farms = getFarms()
    local options = {T("adminShowOnly"), T("adminReload")}
    for _, farm in ipairs(farms) do
        table.insert(options, string.format("%s (%s)", tostring(farm.name), roleName(farm.farmId)))
    end
    OptionDialog.show(function(index)
        if index == nil or index < 1 then
            return
        end
        if index == 1 then
            InfoDialog.show(text)
        elseif index == 2 then
            sendAdmin("reload", 0, "")
        elseif farms[index - 2] ~= nil then
            ServerRulesMenu.chooseRole(farms[index - 2])
        end
    end, T("menuTitle"), T("adminChooseFarm"), options)
end

function ServerRulesMenu.onOpenAction()
    local ok, err = pcall(ServerRulesMenu.open)
    if not ok then
        ServerRules.log("FEHLER im Fenster: %s", tostring(err))
    end
end

if PlayerInputComponent ~= nil and PlayerInputComponent.registerActionEvents ~= nil then
    PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, function(component)
        if component.player == nil or not component.player.isOwner or InputAction == nil or InputAction.SERVERRULES_MENU == nil then
            return
        end
        g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
        local ok, id = g_inputBinding:registerActionEvent(InputAction.SERVERRULES_MENU, component, function()
            ServerRulesMenu.onOpenAction()
        end, false, true, false, true)
        if ok and id ~= nil then
            g_inputBinding:setActionEventTextVisibility(id, false)
        end
        g_inputBinding:endActionEventsModification()
    end)
else
    ServerRules.log("Warnung: PlayerInputComponent.registerActionEvents fehlt - Fenster nur ohne Taste")
end
