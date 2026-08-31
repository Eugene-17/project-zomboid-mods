require "ISUI/ISInventoryPane"
require "TimedActions/ISEugenesZombieCureAction"
require "EugenesZombieCure_Shared"

local M = EugenesZombieCure
local pendingPacifiedZombies = {}

local function beginTreatment(playerObj, item, zombie)
    if not playerObj or not M.hasTreatmentItem(playerObj, item) then return end
    ISTimedActionQueue.add(ISEugenesZombieCureAction:new(playerObj, item, zombie))
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    local actualItems = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(actualItems) do
        if M.isCureItem(item) then
            local option = context:addOption(
                getText("ContextMenu_EZC_UseSelf"),
                playerObj,
                beginTreatment,
                item,
                nil
            )
            option.iconTexture = item:getTexture()
            return
        end
    end
end

local function collectZombies(playerObj, worldObjects)
    local result = {}
    local seen = {}
    for _, worldObject in ipairs(worldObjects) do
        local square = worldObject and worldObject:getSquare()
        local movingObjects = square and square:getMovingObjects()
        if movingObjects then
            for index = 0, movingObjects:size() - 1 do
                local zombie = movingObjects:get(index)
                if not seen[zombie]
                    and instanceof(zombie, "IsoZombie")
                    and not zombie:isDead()
                    and M.isCloseEnough(playerObj, zombie) then
                    seen[zombie] = true
                    result[#result + 1] = zombie
                end
            end
        end
    end
    return result
end

local function pickHumanCorpse(playerObj)
    local corpse = IsoObjectPicker.Instance:PickCorpse(getMouseX(), getMouseY())
    if M.canReviveCorpse(playerObj, corpse) then return corpse end
    return nil
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    local cure = playerObj:getInventory():getFirstTypeRecurse(M.ITEM_FULL_TYPE)
    local serum = playerObj:getInventory():getFirstTypeRecurse(M.RESTORATION_ITEM_FULL_TYPE)
    local stimulant = playerObj:getInventory():getFirstTypeRecurse(M.REANIMATION_ITEM_FULL_TYPE)
    if not cure and not serum and not stimulant then return end
    local zombies = collectZombies(playerObj, worldObjects)
    local corpse = stimulant and pickHumanCorpse(playerObj) or nil
    if #zombies == 0 and not corpse then return end
    if test then return ISWorldObjectContextMenu.setTest() end

    if corpse then
        local option = context:addOption(
            getText("ContextMenu_EZC_ReanimateCorpse"),
            playerObj,
            beginTreatment,
            stimulant,
            corpse
        )
        option.iconTexture = stimulant:getTexture()
    end

    for _, zombie in ipairs(zombies) do
        if serum and M.canRestoreZombie(playerObj, zombie) then
            local option = context:addOption(
                getText("ContextMenu_EZC_RestoreZombie"),
                playerObj,
                beginTreatment,
                serum,
                zombie
            )
            option.iconTexture = serum:getTexture()
        elseif cure and M.canTreatZombie(playerObj, zombie) then
            local option = context:addOption(
                getText("ContextMenu_EZC_UseZombie"),
                playerObj,
                beginTreatment,
                cure,
                zombie
            )
            option.iconTexture = cure:getTexture()
        end
    end
end

local function findZombieByOnlineId(onlineId)
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        if zombie:getOnlineID() == onlineId then return zombie end
    end
    return nil
end

local function onServerCommand(module, command, args)
    if module ~= M.MODULE or not args then return end
    if command == "zombieCured" then
        local targetId = tonumber(args.targetId)
        local zombie = findZombieByOnlineId(targetId)
        if zombie and args.skinName then
            M.applyZombieCureState(zombie, args.skinName)
        elseif targetId and args.skinName then
            pendingPacifiedZombies[targetId] = args.skinName
        end
    elseif command == "result" and args.message then
        local playerObj = getPlayer()
        if playerObj then
            playerObj:setHaloNote(args.message, 255, args.ok and 255 or 80, args.ok and 255 or 80, 300)
        end
    end
end

local function applyPendingPacification(zombie)
    if not zombie then return end
    local targetId = zombie:getOnlineID()
    local skinName = pendingPacifiedZombies[targetId]
    if not skinName then return end
    pendingPacifiedZombies[targetId] = nil
    M.applyZombieCureState(zombie, skinName)
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnServerCommand.Add(onServerCommand)
Events.OnZombieUpdate.Add(applyPendingPacification)
