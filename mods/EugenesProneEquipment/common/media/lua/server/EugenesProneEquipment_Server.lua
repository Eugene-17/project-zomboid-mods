require "EugenesProneEquipment_Shared"

local M = EugenesProneEquipment

local function colorSnapshot(color)
    if not color then return nil end
    return {
        r = color:getRedFloat(),
        g = color:getGreenFloat(),
        b = color:getBlueFloat(),
        a = color:getAlphaFloat(),
    }
end

local function colorFromSnapshot(color)
    if not color then return nil end
    return ImmutableColor.new(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
end

local function notify(playerObj, message, ok)
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "result", { message = message, ok = ok })
    else
        playerObj:setHaloNote(message, 255, ok and 255 or 80, ok and 255 or 80, 300)
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

local function resolveTarget(args)
    local onlineId = tonumber(args.targetId)
    if not onlineId then return nil end
    if args.targetKind == "player" then
        return getPlayerByOnlineID(onlineId)
    end
    if args.targetKind == "zombie" then
        return findZombieByOnlineId(onlineId)
    end
    return nil
end

local function ensureZombieInventory(zombie)
    local data = zombie:getModData()
    if not data.EugenesProneEquipmentInitialized then
        zombie:DoZombieInventory()
        data.EugenesProneEquipmentInitialized = true
    end
end

local function rebuildZombieVisuals(zombie)
    local visuals = zombie:getItemVisuals()
    visuals:clear()
    zombie:getWornItems():getItemVisuals(visuals)
    zombie:resetModelNextFrame()
end

local function makeZombieVisualSnapshot(zombie)
    local result = {}
    local visuals = zombie:getItemVisuals()
    for index = 0, visuals:size() - 1 do
        local visual = visuals:get(index)
        local fullType = visual:getItemType()
        if fullType and fullType ~= "" then
            local row = {
                fullType = fullType,
                hue = visual:getHue(),
                baseTexture = visual:getBaseTexture(),
                textureChoice = visual:getTextureChoice(),
            }
            local tint = visual:getTint()
            if tint then
                row.tintR = tint:getRedFloat()
                row.tintG = tint:getGreenFloat()
                row.tintB = tint:getBlueFloat()
                row.tintA = tint:getAlphaFloat()
            end
            result[#result + 1] = row
        end
    end
    return result
end

local function syncZombieVisuals(zombie)
    rebuildZombieVisuals(zombie)
    if isServer() then
        sendServerCommand(M.MODULE, "zombieVisuals", {
            targetId = zombie:getOnlineID(),
            targetX = math.floor(zombie:getX()),
            targetY = math.floor(zombie:getY()),
            targetZ = math.floor(zombie:getZ()),
            visuals = makeZombieVisualSnapshot(zombie),
        })
    end
end

local function makeAppearanceSnapshot(zombie)
    local visual = zombie:getHumanVisual()
    return {
        female = zombie:isFemale(),
        skinTextureName = visual:getSkinTexture(),
        bodyHairIndex = visual:getBodyHairIndex(),
        hairModel = visual:getHairModel(),
        beardModel = visual:getBeardModel(),
        nonAttachedHair = visual:getNonAttachedHair(),
        skinColor = colorSnapshot(visual:getSkinColor()),
        hairColor = colorSnapshot(visual:getHairColor()),
        beardColor = colorSnapshot(visual:getBeardColor()),
        naturalHairColor = colorSnapshot(visual:getNaturalHairColor()),
        naturalBeardColor = colorSnapshot(visual:getNaturalBeardColor()),
        health = zombie:getHealth(),
    }
end

local function applyAppearanceSnapshot(zombie, snapshot)
    snapshot = snapshot or {}
    local visual = zombie:getHumanVisual()
    visual:clear()
    local skinColor = colorFromSnapshot(snapshot.skinColor)
    local hairColor = colorFromSnapshot(snapshot.hairColor)
    local beardColor = colorFromSnapshot(snapshot.beardColor)
    local naturalHairColor = colorFromSnapshot(snapshot.naturalHairColor)
    local naturalBeardColor = colorFromSnapshot(snapshot.naturalBeardColor)
    if skinColor then visual:setSkinColor(skinColor) end
    if snapshot.bodyHairIndex and snapshot.bodyHairIndex >= 0 then
        visual:setBodyHairIndex(snapshot.bodyHairIndex)
    end
    if snapshot.hairModel then visual:setHairModel(snapshot.hairModel) end
    if snapshot.beardModel then visual:setBeardModel(snapshot.beardModel) end
    if snapshot.nonAttachedHair then visual:setNonAttachedHair(snapshot.nonAttachedHair) end
    if hairColor then visual:setHairColor(hairColor) end
    if beardColor then visual:setBeardColor(beardColor) end
    if naturalHairColor then visual:setNaturalHairColor(naturalHairColor) end
    if naturalBeardColor then visual:setNaturalBeardColor(naturalBeardColor) end
    if snapshot.skinTextureName then visual:setSkinTextureName(snapshot.skinTextureName) end
    visual:removeBlood()
    visual:removeDirt()
    visual:getBodyVisuals():clear()
    if snapshot.health then zombie:setHealth(math.max(0.1, snapshot.health)) end
end

local function moveItem(item, destination)
    local source = item and item:getContainer()
    if not source or not destination then return false end
    if isServer() then sendRemoveItemFromContainer(source, item) end
    source:Remove(item)
    destination:AddItem(item)
    if isServer() then sendAddItemToContainer(destination, item) end
    return true
end

local function moveAllItemsWithoutSync(source, destination)
    if not source or not destination then return end
    local items = source:getItems()
    for index = items:size() - 1, 0, -1 do
        local item = items:get(index)
        source:Remove(item)
        destination:AddItem(item)
    end
end

local function makeWornSnapshot(zombie)
    local rows = {}
    local wornItems = zombie:getWornItems()
    for index = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(index)
        local location = wornItems:getLocation(item)
        if item and location then
            rows[#rows + 1] = {
                itemId = item:getID(),
                location = tostring(location),
            }
        end
    end
    return rows
end

local function removeZombieFromWorld(zombie)
    zombie:getModData().EugenesZombieCurePacified = nil
    zombie:removeFromWorld()
    zombie:removeFromSquare()
    zombie:setSquare(nil)
end

local function equipCarrier(playerObj, carrier)
    forceDropHeavyItems(playerObj)
    playerObj:setPrimaryHandItem(nil)
    playerObj:setSecondaryHandItem(nil)
    playerObj:setPrimaryHandItem(carrier)
    playerObj:setSecondaryHandItem(carrier)
    if isServer() then
        sendEquip(playerObj)
        sendServerCommand(playerObj, M.MODULE, "equipCarrier", { itemId = carrier:getID() })
    end
end

local function pickupPacifiedZombie(playerObj, zombie)
    if not M.canCarryZombie(playerObj, zombie) then
        notify(playerObj, "Only a living pacified zombie within reach can be carried.", false)
        return
    end

    ensureZombieInventory(zombie)
    local carrier = instanceItem(M.CARRIER_FULL_TYPE)
    if not carrier or not instanceof(carrier, "InventoryContainer") then
        notify(playerObj, "The pacified-zombie carrier item could not be created.", false)
        return
    end

    local data = carrier:getModData()
    data.EugenesProneEquipmentHasZombie = true
    data.EugenesProneEquipmentAppearance = makeAppearanceSnapshot(zombie)
    data.EugenesProneEquipmentWorn = makeWornSnapshot(zombie)
    data.EugenesZombieCureSkinName = zombie:getModData().EugenesZombieCureSkinName

    carrier:setName(getText("ItemName_EugenesProneEquipment.PacifiedZombieCarrier"))
    carrier:setCustomName(true)
    moveAllItemsWithoutSync(zombie:getInventory(), carrier:getInventory())
    playerObj:getInventory():AddItem(carrier)
    if isServer() then sendAddItemToContainer(playerObj:getInventory(), carrier) end

    removeZombieFromWorld(zombie)
    equipCarrier(playerObj, carrier)
    notify(playerObj, "The pacified zombie is secured in both hands.", true)
end

local function validDropSquare(playerObj, args)
    local x = tonumber(args.targetX)
    local y = tonumber(args.targetY)
    local z = tonumber(args.targetZ)
    if not x or not y or not z then return nil end
    if math.floor(playerObj:getZ()) ~= math.floor(z) then return nil end
    local dx = playerObj:getX() - x
    local dy = playerObj:getY() - y
    if dx * dx + dy * dy > M.MAX_DISTANCE_SQUARED then return nil end
    local square = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    if not square or square:isSolid() or square:isSolidTrans() then return nil end
    return square
end

local function findItemById(container, itemId)
    if not container or not itemId then return nil end
    return container:getItemWithIDRecursiv(tonumber(itemId))
end

local function spawnStoredZombie(playerObj, carrier, square)
    local data = carrier:getModData()
    local appearance = data.EugenesProneEquipmentAppearance or {}
    local femaleChance = appearance.female and 100 or 0
    local spawned = addZombiesInOutfit(
        square:getX(), square:getY(), square:getZ(), 1, nil, femaleChance,
        false, false, false, true
    )
    local zombie = spawned and spawned:size() > 0 and spawned:get(0) or nil
    if not zombie then return nil end

    zombie:clearWornItems()
    zombie:getInventory():removeAllItems()
    applyAppearanceSnapshot(zombie, appearance)
    moveAllItemsWithoutSync(carrier:getInventory(), zombie:getInventory())

    for _, row in ipairs(data.EugenesProneEquipmentWorn or {}) do
        local item = findItemById(zombie:getInventory(), row.itemId)
        local location = M.getWearLocation(item)
        if item and location then zombie:setWornItem(location, item, false) end
    end

    local skinName = data.EugenesZombieCureSkinName or appearance.skinTextureName
    local zombieData = zombie:getModData()
    zombieData.EugenesZombieCurePacified = true
    zombieData.EugenesZombieCureSkinName = skinName
    zombieData.EugenesProneEquipmentInitialized = true
    if zombie:getTarget() then zombie:setTarget(nil) end
    zombie:clearAggroList()
    zombie:setTargetSeenTime(0)
    zombie:setUseless(true)
    syncZombieVisuals(zombie)
    return zombie
end

local function setDownPacifiedZombie(playerObj, carrier, args)
    if not M.hasZombieCarrier(playerObj, carrier) then
        notify(playerObj, "The carried pacified zombie must be in your inventory.", false)
        return
    end
    local square = validDropSquare(playerObj, args)
    if not square then
        notify(playerObj, "There is no safe nearby square on which to set it down.", false)
        return
    end

    local zombie = spawnStoredZombie(playerObj, carrier, square)
    if not zombie then
        notify(playerObj, "The pacified zombie could not be restored here.", false)
        return
    end

    local itemId = carrier:getID()
    if playerObj:getPrimaryHandItem() == carrier then playerObj:setPrimaryHandItem(nil) end
    if playerObj:getSecondaryHandItem() == carrier then playerObj:setSecondaryHandItem(nil) end
    local source = carrier:getContainer()
    if source then
        if isServer() then sendRemoveItemFromContainer(source, carrier) end
        source:Remove(carrier)
    end
    if isServer() then
        sendEquip(playerObj)
        sendServerCommand(playerObj, M.MODULE, "clearCarrier", { itemId = itemId })
    end
    notify(playerObj, "The pacified zombie was set down safely.", true)
end

local function wearOnTarget(playerObj, target, args)
    local itemId = tonumber(args.itemId)
    local item = itemId and playerObj:getInventory():getItemWithIDRecursiv(itemId) or nil
    if not M.isLooseWearable(playerObj, item) then
        notify(playerObj, "That item must be loose in your inventory, not worn, held, or attached.", false)
        return
    end

    local location = M.getWearLocation(item)
    if not location then
        notify(playerObj, "That item cannot be worn.", false)
        return
    end

    if instanceof(target, "IsoZombie") then ensureZombieInventory(target) end
    if not moveItem(item, target:getInventory()) then
        notify(playerObj, "The item could not be moved to the target.", false)
        return
    end

    target:setWornItem(location, item, false)
    if instanceof(target, "IsoZombie") then syncZombieVisuals(target) end
    notify(playerObj, item:getDisplayName() .. " was put on " .. M.getTargetName(target) .. ".", true)
end

local function takeFromTarget(playerObj, target, args)
    if instanceof(target, "IsoZombie") then ensureZombieInventory(target) end
    local item = M.findWornItem(target, args.location, args.fullType)
    if not item then
        notify(playerObj, "That equipment is no longer worn by the target.", false)
        return
    end

    target:removeWornItem(item, false)
    if not moveItem(item, playerObj:getInventory()) then
        local location = M.getWearLocation(item)
        if location then target:setWornItem(location, item, false) end
        notify(playerObj, "The equipment could not be transferred.", false)
        return
    end

    if instanceof(target, "IsoZombie") then syncZombieVisuals(target) end
    notify(playerObj, item:getDisplayName() .. " was moved into your inventory.", true)
end

function M.handleRequest(playerObj, args, directTarget)
    if not playerObj or not args then return end
    local target = directTarget or resolveTarget(args)
    if not M.canInteract(playerObj, target) then
        notify(playerObj, "The target must still be alive, prone, and within reach.", false)
        return
    end

    if args.operation == "wear" then
        wearOnTarget(playerObj, target, args)
    elseif args.operation == "take" then
        takeFromTarget(playerObj, target, args)
    end
end

function M.handleCarryRequest(playerObj, args, directTarget)
    if not playerObj or not args then return end
    if args.operation == "pickup" then
        local zombie = directTarget or resolveTarget(args)
        pickupPacifiedZombie(playerObj, zombie)
    elseif args.operation == "setdown" then
        local carrier = findItemById(playerObj:getInventory(), args.itemId)
        setDownPacifiedZombie(playerObj, carrier, args)
    end
end

local function onClientCommand(module, command, playerObj, args)
    if module == M.MODULE and command == "changeEquipment" then
        M.handleRequest(playerObj, args or {})
    elseif module == M.MODULE and command == "carryZombie" then
        M.handleCarryRequest(playerObj, args or {})
    end
end

Events.OnClientCommand.Add(onClientCommand)
