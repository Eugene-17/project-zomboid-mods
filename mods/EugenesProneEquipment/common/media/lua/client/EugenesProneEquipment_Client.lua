require "ISUI/ISContextMenu"
require "ISUI/ISInventoryPane"
require "Util/AdjacentFreeTileFinder"
require "TimedActions/ISEugenesChangeEquipmentAction"
require "TimedActions/ISEugenesCarryZombieAction"
require "EugenesProneEquipment_Shared"

local M = EugenesProneEquipment
local pendingZombieVisuals = {}

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

local function addTimedAction(playerObj, target, operation, item, location, fullType, targetItemId)
    if not playerObj or not target then return end
    ISTimedActionQueue.add(ISEugenesChangeEquipmentAction:new(
        playerObj,
        target,
        operation,
        item,
        location,
        fullType,
        targetItemId
    ))
end

local function collectLooseItems(playerObj)
    local matches = playerObj:getInventory():getAllEvalRecurse(function(item)
        return M.isLooseTransferable(playerObj, item)
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

local function collectTargetItems(target)
    local result = {}
    local seen = {}
    local representedVisuals = {}
    local wornItems = target:getWornItems()

    local function addActualItem(item)
        if not item or seen[item] or M.isZombieRecord(item) then return end
        seen[item] = true
        local isWorn = wornItems:contains(item)
        local location = isWorn and wornItems:getLocation(item) or nil
        local name = item:getDisplayName()
        if isWorn then name = getText("ContextMenu_EPE_WornItem", name) end
        result[#result + 1] = {
            item = item,
            name = name,
            fullType = item:getFullType(),
            location = location and tostring(location) or nil,
            itemId = item:getID(),
        }
        if isWorn then
            representedVisuals[item:getFullType() .. "|" .. tostring(location)] = true
        end
    end

    local inventoryItems = target:getInventory():getAllEvalRecurse(function(item)
        return item ~= nil and not M.isZombieRecord(item)
    end)
    for index = 0, inventoryItems:size() - 1 do
        addActualItem(inventoryItems:get(index))
    end
    for index = 0, wornItems:size() - 1 do
        addActualItem(wornItems:getItemByIndex(index))
    end
    addActualItem(target:getPrimaryHandItem())
    addActualItem(target:getSecondaryHandItem())
    local attachedItems = target:getAttachedItems()
    for index = 0, attachedItems:size() - 1 do
        local entry = attachedItems:get(index)
        addActualItem(entry and entry:getItem() or nil)
    end

    if instanceof(target, "IsoZombie") then
        local visuals = target:getItemVisuals()
        for index = 0, visuals:size() - 1 do
            local visual = visuals:get(index)
            local fullType = visual:getItemType()
            if fullType and fullType ~= "" then
                local item = instanceItem(fullType)
                local location = M.getWearLocation(item)
                local visualKey = fullType .. "|" .. tostring(location)
                if item and location and not representedVisuals[visualKey] then
                    representedVisuals[visualKey] = true
                    result[#result + 1] = {
                        item = item,
                        name = getText("ContextMenu_EPE_WornItem", item:getDisplayName()),
                        fullType = fullType,
                        location = tostring(location),
                    }
                end
            end
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
    local looseItems = collectLooseItems(playerObj)
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
                nil,
                nil
            )
            option.iconTexture = item:getTexture()
        end
    end

    local takeOption = targetMenu:addOption(getText("ContextMenu_EPE_TakeOffTarget"))
    local takeMenu = ISContextMenu:getNew(targetMenu)
    targetMenu:addSubMenu(takeOption, takeMenu)
    local targetItems = collectTargetItems(target)
    if #targetItems == 0 then
        local empty = takeMenu:addOption(getText("ContextMenu_EPE_NoWornEquipment"))
        empty.notAvailable = true
    else
        for _, entry in ipairs(targetItems) do
            local option = takeMenu:addOption(
                entry.name,
                playerObj,
                addTimedAction,
                target,
                "take",
                nil,
                entry.location,
                entry.fullType,
                entry.itemId
            )
            option.iconTexture = entry.item:getTexture()
        end
    end
end

local function collectTargets(playerObj, worldObjects)
    local targets = {}
    local seen = {}
    local seenSquares = {}

    local function collectSquare(square)
        if not square or seenSquares[square] then return end
        seenSquares[square] = true
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

    for _, worldObject in ipairs(worldObjects) do
        collectSquare(worldObject and worldObject:getSquare())
    end
    if BanditCompatibility and BanditCompatibility.GetClickedSquare then
        local clicked = BanditCompatibility.GetClickedSquare()
        collectSquare(clicked)
        if clicked then
            collectSquare(clicked:getN())
            collectSquare(clicked:getS())
            collectSquare(clicked:getE())
            collectSquare(clicked:getW())
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
    if not targetId then return false end
    local zombie = findZombieByOnlineId(targetId)
    if not zombie then
        pendingZombieVisuals[targetId] = args
        return false
    end

    pendingZombieVisuals[targetId] = nil
    local companion = M.isCompanionTarget(zombie)
    if args.appearance then
        M.applyZombieAppearanceSnapshot(zombie, args.appearance, false)
    end

    if companion then
        local walkType = zombie:getVariableString("BanditWalkType")
        if not walkType or walkType == "" then walkType = "Walk" end
        zombie:setVariable("BanditWalkType", walkType)
        zombie:setWalkType(walkType)
        return true
    end

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
    return true
end

local function applyPendingZombieVisuals(zombie)
    if not zombie then return end
    local args = pendingZombieVisuals[zombie:getOnlineID()]
    if args then applyZombieVisuals(args) end
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
Events.OnZombieUpdate.Add(applyPendingZombieVisuals)
