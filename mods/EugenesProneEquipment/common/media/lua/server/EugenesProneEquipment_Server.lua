require "EugenesProneEquipment_Shared"

local M = EugenesProneEquipment

local function getZombieCureApi()
    if not EugenesZombieCure or not EugenesZombieCure.applyZombieCureState then
        pcall(require, "EugenesZombieCure_Shared")
    end
    return EugenesZombieCure
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
    if args.targetKind == "player" then return getPlayerByOnlineID(onlineId) end
    if args.targetKind == "zombie" then return findZombieByOnlineId(onlineId) end
    return nil
end

local function ensureZombieInventory(zombie)
    local data = zombie:getModData()
    if data.EugenesProneEquipmentInitialized then return end
    local cureApi = getZombieCureApi()
    local brain = data.brain
    if not (cureApi and cureApi.isRestoredCompanionBrain
        and cureApi.isRestoredCompanionBrain(brain)) then
        zombie:DoZombieInventory()
    end
    data.EugenesProneEquipmentInitialized = true
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

local function refreshPhysicalRecord(zombie)
    local inventory = zombie:getInventory()
    local record = M.findZombieRecord(inventory)
    local cureApi = getZombieCureApi()
    local id = zombie:getPersistentOutfitID()
    local cluster = GetBanditClusterData and GetBanditClusterData(id) or nil
    local brain = zombie:getModData().brain or (cluster and cluster[id])
    local restored = cureApi and cureApi.isRestoredCompanionBrain
        and cureApi.isRestoredCompanionBrain(brain)

    if record or restored then
        record = M.createOrUpdateZombieRecord(zombie)
        if not record then return end
    end
    if restored and brain then
        brain.EugenesZombieCureRestored = true
        brain.EugenesZombieCureSnapshot = nil
        if type(brain.key) == "string" and string.sub(brain.key, 1, 12) == "ezc-restore-" then
            brain.key = nil
        end
        zombie:getModData().brain = brain
        if cluster then
            cluster[id] = brain
            if TransmitBanditCluster then TransmitBanditCluster(id) end
        end
        if Bandit and Bandit.UpdateItemsToSpawnAtDeath then
            Bandit.UpdateItemsToSpawnAtDeath(zombie, brain)
        end
        if cureApi.clearRestoredRecordCache then cureApi.clearRestoredRecordCache(zombie) end
    end
end

local function syncZombieVisuals(zombie)
    local visuals = zombie:getItemVisuals()
    visuals:clear()
    zombie:getWornItems():getItemVisuals(visuals)
    zombie:resetModelNextFrame()
    refreshPhysicalRecord(zombie)
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

local function removeZombieFromWorld(zombie)
    local cureApi = getZombieCureApi()
    if cureApi and cureApi.clearPacifiedZombieState then
        cureApi.clearPacifiedZombieState(zombie)
    end
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
        notify(playerObj, getText("IGUI_EPE_CarryInvalid"), false)
        return
    end
    ensureZombieInventory(zombie)

    local record = M.createOrUpdateZombieRecord(zombie)
    if not record then
        notify(playerObj, getText("IGUI_EPE_RecordCreateFailed"), false)
        return
    end
    local carrier = instanceItem(M.CARRIER_FULL_TYPE)
    if not carrier or not instanceof(carrier, "InventoryContainer") then
        notify(playerObj, getText("IGUI_EPE_CarrierCreateFailed"), false)
        return
    end

    moveAllItemsWithoutSync(zombie:getInventory(), carrier:getInventory())
    playerObj:getInventory():AddItem(carrier)
    if isServer() then sendAddItemToContainer(playerObj:getInventory(), carrier) end
    removeZombieFromWorld(zombie)
    equipCarrier(playerObj, carrier)
    notify(playerObj, getText("IGUI_EPE_CarrierSecured"), true)
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

local function markLegacyWornItems(container, rows)
    local items = container:getItems()
    local used = {}
    local normalized = {}
    for _, row in ipairs(rows or {}) do
        for index = 0, items:size() - 1 do
            local item = items:get(index)
            local location = M.getWearLocation(item)
            local typeMatches = not row.fullType or item:getFullType() == row.fullType
            local locationMatches = not row.location
                or (location and tostring(location) == tostring(row.location))
            if not used[item] and typeMatches and locationMatches then
                if location then
                    location = M.resolveWearLocation(row.location, item) or location
                    local data = item:getModData()
                    data.EugenesZombieRecordWorn = true
                    data.EugenesZombieRecordWearLocation = tostring(location)
                    data.preserve = true
                    local normalizedRow = {
                        fullType = item:getFullType(),
                        displayName = item:getDisplayName(),
                        location = tostring(location),
                        banditLocation = location:getTranslationName(),
                    }
                    local visual = item:getVisual()
                    if visual then
                        normalizedRow.hue = visual:getHue()
                        normalizedRow.baseTexture = visual:getBaseTexture()
                        normalizedRow.textureChoice = visual:getTextureChoice()
                        local tint = visual:getTint()
                        if tint then
                            normalizedRow.tint = {
                                r = tint:getRedFloat(),
                                g = tint:getGreenFloat(),
                                b = tint:getBlueFloat(),
                                a = tint:getAlphaFloat(),
                            }
                        end
                    end
                    normalized[#normalized + 1] = normalizedRow
                    used[item] = true
                    break
                end
            end
        end
    end
    return normalized
end

local function migrateLegacyCarrier(carrier)
    local inventory = carrier:getInventory()
    local record = M.findZombieRecord(inventory)
    if record then return record end
    local data = carrier:getModData()
    if data.EugenesProneEquipmentHasZombie ~= true then return nil end
    local snapshot = {
        schemaVersion = M.RECORD_SCHEMA_VERSION,
        appearance = data.EugenesProneEquipmentAppearance or {},
        worn = markLegacyWornItems(inventory, data.EugenesProneEquipmentWorn),
        visuals = data.EugenesProneEquipmentVisuals or {},
    }
    record = M.createZombieRecordFromSnapshot(snapshot, inventory)
    if record then
        data.EugenesProneEquipmentHasZombie = nil
        data.EugenesProneEquipmentAppearance = nil
        data.EugenesProneEquipmentWorn = nil
        data.EugenesProneEquipmentVisuals = nil
        data.EugenesZombieCurePacified = nil
        data.EugenesZombieCureSkinName = nil
    end
    return record
end

local function removeSpawnedZombie(zombie)
    if not zombie then return end
    zombie:removeFromWorld()
    zombie:removeFromSquare()
    zombie:setSquare(nil)
end

local function spawnStoredZombie(carrier, square)
    local record = migrateLegacyCarrier(carrier)
    if not record then return nil, "record" end
    local snapshot = M.getZombieRecordSnapshot(record)
    if not snapshot or not snapshot.appearance then return nil, "record" end

    local femaleChance = snapshot.appearance.female and 100 or 0
    local spawned = addZombiesInOutfit(
        square:getX(), square:getY(), square:getZ(), 1, nil, femaleChance
    )
    local zombie = spawned and spawned:size() > 0 and spawned:get(0) or nil
    if not zombie then return nil, "spawn" end

    zombie:clearWornItems()
    zombie:getInventory():removeAllItems()
    moveAllItemsWithoutSync(carrier:getInventory(), zombie:getInventory())
    local cureApi = getZombieCureApi()
    local skinName = snapshot.appearance.skinTextureName
    local ok, result = pcall(function()
        if cureApi and cureApi.applyZombieCureState then
            cureApi.applyZombieCureState(zombie, skinName)
        else
            error("Zombie Cure API unavailable")
        end
        if not M.applyZombieRecord(zombie, record, true) then
            error("Zombie record could not be applied")
        end
    end)
    if not ok then
        print("[EugenesProneEquipment] set-down failed: " .. tostring(result))
        moveAllItemsWithoutSync(zombie:getInventory(), carrier:getInventory())
        removeSpawnedZombie(zombie)
        return nil, "spawn"
    end

    zombie:getModData().EugenesProneEquipmentInitialized = true
    if zombie.transmitModData then pcall(zombie.transmitModData, zombie) end
    syncZombieVisuals(zombie)
    if isServer() then
        sendServerCommand(cureApi.MODULE, "zombieCured", {
            targetId = zombie:getOnlineID(),
            skinName = skinName,
        })
    end
    return zombie
end

local function setDownPacifiedZombie(playerObj, carrier, args)
    if not M.hasZombieCarrier(playerObj, carrier) then
        notify(playerObj, getText("IGUI_EPE_CarrierMissing"), false)
        return
    end
    local square = validDropSquare(playerObj, args)
    if not square then
        notify(playerObj, getText("IGUI_EPE_NoSafeDropSquare"), false)
        return
    end

    local zombie, failure = spawnStoredZombie(carrier, square)
    if not zombie then
        local key = failure == "record" and "IGUI_EPE_RecordInvalid" or "IGUI_EPE_SetDownFailed"
        notify(playerObj, getText(key), false)
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
    notify(playerObj, getText("IGUI_EPE_SetDownSuccess"), true)
end

local function wearOnTarget(playerObj, target, args)
    local itemId = tonumber(args.itemId)
    local item = itemId and playerObj:getInventory():getItemWithIDRecursiv(itemId) or nil
    if not M.isLooseWearable(playerObj, item) then
        notify(playerObj, getText("IGUI_EPE_ItemMustBeLoose"), false)
        return
    end
    local location = M.getWearLocation(item)
    if not location then
        notify(playerObj, getText("IGUI_EPE_ItemCannotBeWorn"), false)
        return
    end
    if instanceof(target, "IsoZombie") then ensureZombieInventory(target) end
    if not moveItem(item, target:getInventory()) then
        notify(playerObj, getText("IGUI_EPE_ItemMoveFailed"), false)
        return
    end
    target:setWornItem(location, item, false)
    if instanceof(target, "IsoZombie") then syncZombieVisuals(target) end
    notify(
        playerObj,
        getText("IGUI_EPE_ItemPutOn", item:getDisplayName(), M.getTargetName(target)),
        true
    )
end

local function takeFromTarget(playerObj, target, args)
    if instanceof(target, "IsoZombie") then ensureZombieInventory(target) end
    local item = M.findWornItem(target, args.location, args.fullType)
    if not item then
        notify(playerObj, getText("IGUI_EPE_ItemNoLongerWorn"), false)
        return
    end
    target:removeWornItem(item, false)
    M.clearRecordWearMarker(item)
    if not moveItem(item, playerObj:getInventory()) then
        local location = M.getWearLocation(item)
        if location then target:setWornItem(location, item, false) end
        notify(playerObj, getText("IGUI_EPE_ItemTransferFailed"), false)
        return
    end
    if instanceof(target, "IsoZombie") then syncZombieVisuals(target) end
    notify(playerObj, getText("IGUI_EPE_ItemMovedToInventory", item:getDisplayName()), true)
end

function M.handleRequest(playerObj, args, directTarget)
    if not playerObj or not args then return end
    local target = directTarget or resolveTarget(args)
    if not M.canInteract(playerObj, target) then
        notify(playerObj, getText("IGUI_EPE_TargetInvalid"), false)
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
        pickupPacifiedZombie(playerObj, directTarget or resolveTarget(args))
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
