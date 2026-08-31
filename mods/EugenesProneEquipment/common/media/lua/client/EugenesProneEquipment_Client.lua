require "ISUI/ISContextMenu"
require "ISUI/ISInventoryPane"
require "Util/AdjacentFreeTileFinder"
require "TimedActions/ISEugenesChangeEquipmentAction"
require "TimedActions/ISEugenesCarryZombieAction"
require "EugenesProneEquipment_Shared"

local M = EugenesProneEquipment

local function beginCarryZombie(playerObj, zombie)
    if not M.canCarryZombie(playerObj, zombie) then return end
    ISTimedActionQueue.add(ISEugenesCarryZombieAction:new(
        playerObj,
        "pickup",
        zombie,
        nil,
        nil
    ))
end

local function beginSetDownZombie(playerObj, carrier)
    if not M.hasZombieCarrier(playerObj, carrier) then return end
    local square = AdjacentFreeTileFinder.Find(playerObj:getSquare(), playerObj)
    if not square then square = playerObj:getSquare() end
    ISTimedActionQueue.add(ISEugenesCarryZombieAction:new(
        playerObj,
        "setdown",
        nil,
        carrier,
        square
    ))
end

local function addTimedAction(playerObj, target, operation, item, location, fullType)
    if not playerObj or not target then return end
    ISTimedActionQueue.add(ISEugenesChangeEquipmentAction:new(
        playerObj,
        target,
        operation,
        item,
        location,
        fullType
    ))
end

local function collectLooseWearables(playerObj)
    local matches = playerObj:getInventory():getAllEvalRecurse(function(item)
        return M.isLooseWearable(playerObj, item)
    end)
    local result = {}
    for index = 0, matches:size() - 1 do
        result[#result + 1] = matches:get(index)
    end
    table.sort(result, function(left, right)
        return left:getDisplayName() < right:getDisplayName()
    end)
    return result
end

local function collectTargetEquipment(target)
    local result = {}
    if instanceof(target, "IsoZombie") then
        local visuals = target:getItemVisuals()
        for index = 0, visuals:size() - 1 do
            local visual = visuals:get(index)
            local fullType = visual:getItemType()
            if fullType and fullType ~= "" then
                local item = instanceItem(fullType)
                local location = M.getWearLocation(item)
                if item and location then
                    result[#result + 1] = {
                        item = item,
                        name = item:getDisplayName(),
                        fullType = fullType,
                        location = tostring(location),
                    }
                end
            end
        end
    else
        local wornItems = target:getWornItems()
        for index = 0, wornItems:size() - 1 do
            local item = wornItems:getItemByIndex(index)
            local location = wornItems:getLocation(item)
            result[#result + 1] = {
                item = item,
                name = item:getDisplayName(),
                fullType = item:getFullType(),
                location = tostring(location),
            }
        end
    end
    table.sort(result, function(left, right) return left.name < right.name end)
    return result
end

local function addEquipmentMenus(context, playerObj, target)
    local targetOption = context:addOption(
        getText("ContextMenu_EPE_ManageEquipment", M.getTargetName(target))
    )
    local targetMenu = ISContextMenu:getNew(context)
    context:addSubMenu(targetOption, targetMenu)

    local wearOption = targetMenu:addOption(getText("ContextMenu_EPE_PutOnTarget"))
    local wearMenu = ISContextMenu:getNew(targetMenu)
    targetMenu:addSubMenu(wearOption, wearMenu)
    local looseItems = collectLooseWearables(playerObj)
    if #looseItems == 0 then
        local empty = wearMenu:addOption(getText("ContextMenu_EPE_NoWearableItems"))
        empty.notAvailable = true
    else
        for _, item in ipairs(looseItems) do
            local option = wearMenu:addOption(
                item:getDisplayName(),
                playerObj,
                addTimedAction,
                target,
                "wear",
                item,
                nil,
                nil
            )
            option.iconTexture = item:getTexture()
        end
    end

    local takeOption = targetMenu:addOption(getText("ContextMenu_EPE_TakeOffTarget"))
    local takeMenu = ISContextMenu:getNew(targetMenu)
    targetMenu:addSubMenu(takeOption, takeMenu)
    local targetEquipment = collectTargetEquipment(target)
    if #targetEquipment == 0 then
        local empty = takeMenu:addOption(getText("ContextMenu_EPE_NoWornEquipment"))
        empty.notAvailable = true
    else
        for _, entry in ipairs(targetEquipment) do
            local option = takeMenu:addOption(
                entry.name,
                playerObj,
                addTimedAction,
                target,
                "take",
                nil,
                entry.location,
                entry.fullType
            )
            option.iconTexture = entry.item:getTexture()
        end
    end
end

local function collectTargets(playerObj, worldObjects)
    local targets = {}
    local seen = {}
    for _, worldObject in ipairs(worldObjects) do
        local square = worldObject and worldObject:getSquare()
        local movingObjects = square and square:getMovingObjects()
        if movingObjects then
            for index = 0, movingObjects:size() - 1 do
                local target = movingObjects:get(index)
                local relevant = M.canInteract(playerObj, target)
                    or M.canCarryZombie(playerObj, target)
                if not seen[target] and relevant then
                    seen[target] = true
                    targets[#targets + 1] = target
                end
            end
        end
    end
    return targets
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    local targets = collectTargets(playerObj, worldObjects)
    if #targets == 0 then return end
    if test then return ISWorldObjectContextMenu.setTest() end
    for _, target in ipairs(targets) do
        if M.canInteract(playerObj, target) then
            addEquipmentMenus(context, playerObj, target)
        end
        if M.canCarryZombie(playerObj, target) then
            context:addOption(
                getText("ContextMenu_EPE_PickUpZombie"),
                playerObj,
                beginCarryZombie,
                target
            )
        end
    end
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    local actualItems = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(actualItems) do
        if M.hasZombieCarrier(playerObj, item) then
            local option = context:addOption(
                getText("ContextMenu_EPE_SetDownZombie"),
                playerObj,
                beginSetDownZombie,
                item
            )
            option.iconTexture = item:getTexture()
            return
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

local function applyZombieVisuals(args)
    local targetId = tonumber(args.targetId)
    if not targetId then return end
    local zombie = findZombieByOnlineId(targetId)
    if not zombie then return end

    local visuals = zombie:getItemVisuals()
    visuals:clear()
    for _, row in ipairs(args.visuals or {}) do
        local item = instanceItem(row.fullType)
        local visual = item and item:getVisual()
        if visual then
            if row.hue then visual:setHue(row.hue) end
            if row.baseTexture then visual:setBaseTexture(row.baseTexture) end
            if row.textureChoice then visual:setTextureChoice(row.textureChoice) end
            if row.tintR and row.tintG and row.tintB then
                visual:setTint(ImmutableColor.new(
                    row.tintR,
                    row.tintG,
                    row.tintB,
                    row.tintA or 1
                ))
            end
            visuals:add(visual)
        end
    end
    zombie:resetModelNextFrame()
end

local function findOwnedCarrier(itemId)
    local playerObj = getPlayer()
    if not playerObj then return nil end
    return playerObj:getInventory():getItemWithIDRecursiv(tonumber(itemId))
end

local function equipCarrier(itemId)
    local playerObj = getPlayer()
    local item = findOwnedCarrier(itemId)
    if not playerObj or not M.isZombieCarrier(item) then return end
    forceDropHeavyItems(playerObj)
    playerObj:setPrimaryHandItem(nil)
    playerObj:setSecondaryHandItem(nil)
    playerObj:setPrimaryHandItem(item)
    playerObj:setSecondaryHandItem(item)
    if ISInventoryPage then ISInventoryPage.renderDirty = true end
end

local function clearCarrierFromHands(itemId)
    local playerObj = getPlayer()
    if not playerObj then return end
    local id = tonumber(itemId)
    local primary = playerObj:getPrimaryHandItem()
    local secondary = playerObj:getSecondaryHandItem()
    if primary and primary:getID() == id then playerObj:setPrimaryHandItem(nil) end
    if secondary and secondary:getID() == id then playerObj:setSecondaryHandItem(nil) end
    if ISInventoryPage then ISInventoryPage.renderDirty = true end
end

local function onServerCommand(module, command, args)
    if module ~= M.MODULE or not args then return end
    if command == "zombieVisuals" then
        applyZombieVisuals(args)
    elseif command == "equipCarrier" then
        equipCarrier(args.itemId)
    elseif command == "clearCarrier" then
        clearCarrierFromHands(args.itemId)
    elseif command == "result" and args.message then
        local playerObj = getPlayer()
        if playerObj then
            playerObj:setHaloNote(args.message, 255, args.ok and 255 or 80, args.ok and 255 or 80, 300)
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
Events.OnServerCommand.Add(onServerCommand)
