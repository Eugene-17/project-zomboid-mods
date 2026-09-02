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
    zombie:DoZombieInventory()
    data.EugenesProneEquipmentInitialized = true
end

local function purgeZombieRecords(container)
    if not container then return 0 end
    if isServer() then
        local records = container:getAllEvalRecurse(function(item)
            return M.isZombieRecord(item)
        end)
        for index = records:size() - 1, 0, -1 do
            local item = records:get(index)
            local source = item and item:getContainer() or nil
            if source then sendRemoveItemFromContainer(source, item) end
        end
    end
    return M.removeZombieRecords(container)
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
    if record then M.createOrUpdateZombieRecord(zombie) end
end

local function syncZombieVisuals(zombie, refreshRecord, appearance)
    local visuals = zombie:getItemVisuals()
    visuals:clear()
    zombie:getWornItems():getItemVisuals(visuals)
    zombie:resetModelNextFrame()
    if refreshRecord ~= false then refreshPhysicalRecord(zombie) end
    if isServer() then
        sendServerCommand(M.MODULE, "zombieVisuals", {
            targetId = zombie:getOnlineID(),
            targetX = math.floor(zombie:getX()),
            targetY = math.floor(zombie:getY()),
            targetZ = math.floor(zombie:getZ()),
            visuals = makeZombieVisualSnapshot(zombie),
            appearance = appearance,
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

local function ensureCarrierPacificationMarker(carrier)
    local cureApi = getZombieCureApi()
    local inventory = carrier and carrier:getInventory() or nil
    if not cureApi or not inventory then return false end

    local data = carrier:getModData()
    local cure = inventory:getFirstTypeRecurse(cureApi.ITEM_FULL_TYPE)
    if data.EugenesZombieCureMarkerVersion
        == cureApi.PACIFICATION_SCHEMA_VERSION then
        return cure ~= nil
    end

    -- Carriers saved by the previous version contain a zombie record but no
    -- cure because the treatment used to be consumed. Migrate each once.
    if not cure then
        cure = inventory:AddItem(cureApi.ITEM_FULL_TYPE)
        if cure and isServer() then sendAddItemToContainer(inventory, cure) end
    end
    if not cure then return false end
    data.EugenesZombieCureMarkerVersion = cureApi.PACIFICATION_SCHEMA_VERSION
    return true
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
    local cureApi = getZombieCureApi()
    if cureApi then
        carrier:getModData().EugenesZombieCureMarkerVersion
            = cureApi.PACIFICATION_SCHEMA_VERSION
    end
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
    local data = carrier:getModData()
    if not record and data.EugenesProneEquipmentHasZombie ~= true then return nil end
    if not ensureCarrierPacificationMarker(carrier) then return nil end
    if record then return record end
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

local function getZombieIdentity(zombie)
    if not zombie then return nil end
    if BanditUtils and BanditUtils.GetZombieID then
        local ok, id = pcall(BanditUtils.GetZombieID, zombie)
        if ok and id ~= nil then return id end
    end
    return zombie:getPersistentOutfitID()
end

local function identityIsAvailable(zombie)
    local id = getZombieIdentity(zombie)
    if id == nil then return false end

    -- Bandits adopts any ordinary zombie whose persistent-outfit identity is
    -- already present in its cluster. That turns a set-down pacified zombie
    -- into somebody else's NPC shell, after which companion persistence may
    -- remove it. Reject the collision before moving any carrier contents.
    if GetBanditClusterData then
        local cluster = GetBanditClusterData(id)
        if cluster and cluster[id] ~= nil then return false end
    end

    -- Persistent outfit IDs are not unique. Avoid sharing one with another
    -- loaded zombie as well, since a later Bandits registration would be
    -- unable to distinguish the two bodies.
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local other = zombies:get(index)
        if other ~= zombie and getZombieIdentity(other) == id then return false end
    end
    return true
end

local function createCollisionFreeZombie(square, femaleChance)
    for attempt = 1, 12 do
        local zombie
        local ok = pcall(function()
            -- A nil outfit follows the same supported random-shell path used
            -- by True Companions. The previous empty outfit produced a narrow,
            -- collision-prone identity pool (logged as "Dressed in ,").
            zombie = createZombie(
                square:getX(), square:getY(), square:getZ(), nil,
                femaleChance, IsoDirections.S
            )
        end)
        if ok and zombie then
            if identityIsAvailable(zombie) then return zombie end
            removeSpawnedZombie(zombie)
        end
    end
    return nil
end

local function spawnStoredZombie(carrier, square)
    local record = migrateLegacyCarrier(carrier)
    if not record then return nil, "record" end
    local snapshot = M.getZombieRecordSnapshot(record)
    if not snapshot or not snapshot.appearance then return nil, "record" end

    local femaleChance = snapshot.appearance.female and 100 or 0
    local zombie = createCollisionFreeZombie(square, femaleChance)
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
    -- The record is the authoritative packed snapshot. Do not immediately
    -- overwrite it from a newly spawned zombie whose model is still settling.
    syncZombieVisuals(zombie, false, snapshot.appearance)
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
    if not M.isLooseTransferable(playerObj, item) then
        notify(playerObj, getText("IGUI_EPE_ItemMustBeLoose"), false)
        return
    end
    local location = not item:isBroken() and M.getWearLocation(item) or nil
    if instanceof(target, "IsoZombie") then ensureZombieInventory(target) end
    if not moveItem(item, target:getInventory()) then
        notify(playerObj, getText("IGUI_EPE_ItemMoveFailed"), false)
        return
    end
    if location then target:setWornItem(location, item, false) end
    if instanceof(target, "IsoZombie") then syncZombieVisuals(target) end
    notify(
        playerObj,
        getText(
            location and "IGUI_EPE_ItemPutOn" or "IGUI_EPE_ItemGiven",
            item:getDisplayName(),
            M.getTargetName(target)
        ),
        true
    )
end

local function findTargetItemById(target, itemId)
    if not target or not itemId then return nil end
    local item = target:getInventory():getItemWithIDRecursiv(itemId)
    if item then return item end
    local primary = target:getPrimaryHandItem()
    if primary and primary:getID() == itemId then return primary end
    local secondary = target:getSecondaryHandItem()
    if secondary and secondary:getID() == itemId then return secondary end
    local wornItems = target:getWornItems()
    for index = 0, wornItems:size() - 1 do
        item = wornItems:getItemByIndex(index)
        if item and item:getID() == itemId then return item end
    end
    local attachedItems = target:getAttachedItems()
    for index = 0, attachedItems:size() - 1 do
        local entry = attachedItems:get(index)
        item = entry and entry:getItem() or nil
        if item and item:getID() == itemId then return item end
    end
    return nil
end

local function takeFromTarget(playerObj, target, args)
    if instanceof(target, "IsoZombie") then ensureZombieInventory(target) end
    local targetItemId = tonumber(args.targetItemId)
    local item = targetItemId
        and findTargetItemById(target, targetItemId)
        or M.findWornItem(target, args.location, args.fullType)
    if not item then
        notify(playerObj, getText("IGUI_EPE_ItemNoLongerAvailable"), false)
        return
    end
    local wornItems = target:getWornItems()
    local wasWorn = wornItems:contains(item)
    local previousLocation = wasWorn and wornItems:getLocation(item) or nil
    local wasPrimary = target:getPrimaryHandItem() == item
    local wasSecondary = target:getSecondaryHandItem() == item
    if wasWorn then target:removeWornItem(item, false) end
    if wasPrimary then target:setPrimaryHandItem(nil) end
    if wasSecondary then target:setSecondaryHandItem(nil) end
    if target:isAttachedItem(item) then target:removeAttachedItem(item) end
    M.clearRecordWearMarker(item)
    local moved = moveItem(item, playerObj:getInventory())
    if not moved then
        if previousLocation then target:setWornItem(previousLocation, item, false) end
        if wasPrimary then target:setPrimaryHandItem(item) end
        if wasSecondary then target:setSecondaryHandItem(item) end
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
