require "ISUI/ISInventoryPane"
require "ISUI/Animal/ISAnimalContextMenu"
require "TimedActions/ISInventoryTransferUtil"
require "CodexAnimalSpawnItems_Shared"

local M = CodexAnimalSpawnItems

local animalInventoryMenuExtended = false

local function putLiveAnimalInBag(playerObj, animalItem, bag)
    if not playerObj or not M.isLiveAnimalItem(animalItem) or not bag then return end

    local source = animalItem:getContainer()
    local destination = bag:getInventory()
    if not source or not destination or source == destination then return end
    if not M.isPortableBagContainer(destination) then return end
    if not destination:isItemAllowed(animalItem) then return end
    if not destination:hasRoomFor(playerObj, animalItem) then
        playerObj:setHaloNote(getText("ContextMenu_CASI_BagTooSmall"), 255, 80, 80, 300)
        return
    end

    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(
        playerObj,
        animalItem,
        source,
        destination
    ))
end

local function addPutInBagMenu(playerNum, context, animalItem)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or not M.isLiveAnimalItem(animalItem) then return end

    local bags = playerObj:getInventory():getAllEvalRecurse(function(item)
        return instanceof(item, "InventoryContainer")
            and item:getInventory() ~= animalItem:getContainer()
    end)
    if not bags or bags:isEmpty() then return end

    local option = context:addOption(getText("ContextMenu_CASI_PutInBag"))
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, submenu)

    for index = 0, bags:size() - 1 do
        local bag = bags:get(index)
        local destination = bag:getInventory()
        local label = string.format(
            "%s (%.1f/%d)",
            bag:getName(),
            destination:getCapacityWeight(),
            destination:getEffectiveCapacity(playerObj)
        )
        local bagOption = submenu:addOption(label, playerObj, putLiveAnimalInBag, animalItem, bag)
        if not destination:hasRoomFor(playerObj, animalItem) then
            bagOption.notAvailable = true
        end
    end
end

local function extendAnimalInventoryMenu()
    if animalInventoryMenuExtended then return end
    if not AnimalContextMenu or not AnimalContextMenu.doInventoryMenu then return end

    local originalDoInventoryMenu = AnimalContextMenu.doInventoryMenu
    AnimalContextMenu.doInventoryMenu = function(playerNum, context, animalItem, test)
        local result = originalDoInventoryMenu(playerNum, context, animalItem, test)
        addPutInBagMenu(playerNum, context, animalItem)
        return result
    end
    animalInventoryMenuExtended = true
end

extendAnimalInventoryMenu()
Events.OnGameStart.Add(extendAnimalInventoryMenu)

local function releaseCarrier(playerObj, species)
    if isClient() then
        sendClientCommand(playerObj, M.MODULE, "release", { species = species })
    else
        M.release(playerObj, { species = species })
    end
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local actualItems = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(actualItems) do
        local species = M.ITEM_TO_SPECIES[item:getFullType()]
        if species then
            context:addOption(getText("ContextMenu_CASI_Release"), playerObj, releaseCarrier, species)
            return
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= M.MODULE or command ~= "result" then return end

    local playerObj = getPlayer()
    if playerObj and args and args.message then
        playerObj:setHaloNote(args.message, 255, args.ok and 255 or 80, 80, 300)
    end
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
Events.OnServerCommand.Add(onServerCommand)
