EugenesProneEquipment = EugenesProneEquipment or {}

local M = EugenesProneEquipment

M.MODULE = "EugenesProneEquipment"
M.MAX_DISTANCE_SQUARED = 6.25
M.CARRIER_FULL_TYPE = "EugenesProneEquipment.PacifiedZombieCarrier"
M.RECORD_FULL_TYPE = "EugenesProneEquipment.ZombieDescription"
M.RECORD_SCHEMA_VERSION = 1

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

local function itemVisualSnapshot(visual, fullType, displayName, location)
    if not visual and not fullType then return nil end
    local row = {
        fullType = fullType or visual:getItemType(),
        displayName = displayName,
        location = location and tostring(location) or nil,
        banditLocation = location and location:getTranslationName() or nil,
    }
    if visual then
        row.hue = visual:getHue()
        row.baseTexture = visual:getBaseTexture()
        row.textureChoice = visual:getTextureChoice()
        row.tint = colorSnapshot(visual:getTint())
    end
    return row
end

local function applyItemVisualSnapshot(visual, row)
    if not visual or not row then return end
    if row.hue then visual:setHue(row.hue) end
    if row.baseTexture then visual:setBaseTexture(row.baseTexture) end
    if row.textureChoice then visual:setTextureChoice(row.textureChoice) end
    local tint = colorFromSnapshot(row.tint)
    if not tint and row.tintR and row.tintG and row.tintB then
        tint = ImmutableColor.new(row.tintR, row.tintG, row.tintB, row.tintA or 1)
    end
    if tint then visual:setTint(tint) end
end

function M.getWearLocation(item)
    if not item then return nil end
    local location = item:canBeEquipped()
    if location and tostring(location) ~= "" then return location end
    location = item:getBodyLocation()
    if location and tostring(location) ~= "" then return location end
    return nil
end

function M.resolveWearLocation(locationText, item)
    if locationText and ItemBodyLocation and ResourceLocation then
        local ok, location = pcall(function()
            return ItemBodyLocation.get(ResourceLocation.of(tostring(locationText)))
        end)
        if ok and location then return location end
    end
    return M.getWearLocation(item)
end

function M.isLooseWearable(playerObj, item)
    if not playerObj or not item or item:isBroken() then return false end
    if not playerObj:getInventory():containsRecursive(item) then return false end
    if playerObj:getPrimaryHandItem() == item then return false end
    if playerObj:getSecondaryHandItem() == item then return false end
    if playerObj:getWornItems():contains(item) then return false end
    if playerObj:isAttachedItem(item) then return false end
    return M.getWearLocation(item) ~= nil
end

function M.isProneLivingTarget(playerObj, target)
    if not playerObj or not target or playerObj == target then return false end
    if not (instanceof(target, "IsoZombie") or instanceof(target, "IsoPlayer")) then return false end
    if target:isDead() then return false end
    if target:isKnockedDown() then return true end
    if target:isOnFloor() then return true end
    return target:isProne()
end

function M.isCloseEnough(playerObj, target)
    if not playerObj or not target then return false end
    if math.floor(playerObj:getZ()) ~= math.floor(target:getZ()) then return false end
    local dx = playerObj:getX() - target:getX()
    local dy = playerObj:getY() - target:getY()
    return dx * dx + dy * dy <= M.MAX_DISTANCE_SQUARED
end

function M.canInteract(playerObj, target)
    return M.isProneLivingTarget(playerObj, target) and M.isCloseEnough(playerObj, target)
end

function M.isPacifiedZombie(target)
    local cureApi = EugenesZombieCure
    return cureApi
        and cureApi.isPacifiedZombie
        and cureApi.isPacifiedZombie(target)
end

function M.canCarryZombie(playerObj, target)
    return M.isPacifiedZombie(target) and M.isCloseEnough(playerObj, target)
end

function M.isZombieRecord(item)
    if not item or item:getFullType() ~= M.RECORD_FULL_TYPE then return false end
    local data = item:getModData()
    return data.EugenesZombieRecordKind == "pacified-zombie"
        and tonumber(data.EugenesZombieRecordVersion) == M.RECORD_SCHEMA_VERSION
        and type(data.EugenesZombieRecordSnapshot) == "table"
end

function M.findZombieRecord(container)
    if not container then return nil end
    local items = container:getItems()
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if M.isZombieRecord(item) then return item end
    end
    return nil
end

function M.getZombieRecordSnapshot(record)
    if not M.isZombieRecord(record) then return nil end
    return record:getModData().EugenesZombieRecordSnapshot
end

function M.isZombieCarrier(item)
    if not item or item:getFullType() ~= M.CARRIER_FULL_TYPE then return false end
    if not instanceof(item, "InventoryContainer") then return false end
    if M.findZombieRecord(item:getInventory()) then return true end
    return item:getModData().EugenesProneEquipmentHasZombie == true
end

function M.hasZombieCarrier(playerObj, item)
    return playerObj
        and M.isZombieCarrier(item)
        and playerObj:getInventory():containsRecursive(item)
end

function M.getTargetKind(target)
    if instanceof(target, "IsoZombie") then return "zombie" end
    if instanceof(target, "IsoPlayer") then return "player" end
    return nil
end

function M.getTargetName(target)
    if instanceof(target, "IsoZombie") then return getText("IGUI_EPE_TargetZombie") end
    local name = target:getDisplayName()
    if not name or name == "" then name = target:getUsername() end
    return name or getText("IGUI_EPE_TargetPlayer")
end

function M.makeTargetArgs(target)
    return {
        targetKind = M.getTargetKind(target),
        targetId = target:getOnlineID(),
        targetX = math.floor(target:getX()),
        targetY = math.floor(target:getY()),
        targetZ = math.floor(target:getZ()),
    }
end

function M.findWornItem(target, locationText, fullType)
    if not target or not locationText then return nil end
    local wornItems = target:getWornItems()
    for index = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(index)
        local location = wornItems:getLocation(item)
        if location and tostring(location) == tostring(locationText)
            and (not fullType or item:getFullType() == fullType) then
            return item
        end
    end
    return nil
end

function M.clearRecordWearMarker(item)
    if not item then return end
    local data = item:getModData()
    data.EugenesZombieRecordWorn = nil
    data.EugenesZombieRecordWearLocation = nil
end

local function clearInventoryWearMarkers(container)
    if not container then return end
    local items = container:getItems()
    for index = 0, items:size() - 1 do
        M.clearRecordWearMarker(items:get(index))
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

local function materializeVisibleEquipment(zombie)
    local inventory = zombie:getInventory()
    local wornItems = zombie:getWornItems()
    local represented = {}
    for index = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(index)
        if item then
            local source = item:getContainer()
            if source and source ~= inventory then source:Remove(item) end
            if item:getContainer() ~= inventory then inventory:AddItem(item) end
            local fullType = item:getFullType()
            represented[fullType] = (represented[fullType] or 0) + 1
        end
    end

    local visuals = zombie:getItemVisuals()
    for index = 0, visuals:size() - 1 do
        local visual = visuals:get(index)
        local fullType = visual:getItemType()
        local count = fullType and (represented[fullType] or 0) or 0
        if count > 0 then
            represented[fullType] = count - 1
        elseif fullType and fullType ~= "" then
            local item
            local items = inventory:getItems()
            for itemIndex = 0, items:size() - 1 do
                local candidate = items:get(itemIndex)
                if candidate:getFullType() == fullType
                    and not wornItems:contains(candidate) then
                    item = candidate
                    break
                end
            end
            if not item then
                item = instanceItem(fullType)
                if item then inventory:AddItem(item) end
            end
            local location = M.getWearLocation(item)
            if item and location then
                applyItemVisualSnapshot(item:getVisual(), itemVisualSnapshot(visual, fullType))
                zombie:setWornItem(location, item, false)
            end
        end
    end
end

function M.makeZombieSnapshot(zombie)
    if not zombie then return nil end
    materializeVisibleEquipment(zombie)
    local snapshot = {
        schemaVersion = M.RECORD_SCHEMA_VERSION,
        appearance = makeAppearanceSnapshot(zombie),
        worn = {},
        visuals = {},
    }
    local inventory = zombie:getInventory()
    clearInventoryWearMarkers(inventory)

    local wornItems = zombie:getWornItems()
    for index = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(index)
        local location = item and wornItems:getLocation(item) or nil
        if item and location then
            local itemData = item:getModData()
            itemData.EugenesZombieRecordWorn = true
            itemData.EugenesZombieRecordWearLocation = tostring(location)
            itemData.preserve = true
            snapshot.worn[#snapshot.worn + 1] = itemVisualSnapshot(
                item:getVisual(),
                item:getFullType(),
                item:getDisplayName(),
                location
            )
        end
    end

    local visuals = zombie:getItemVisuals()
    for index = 0, visuals:size() - 1 do
        local visual = visuals:get(index)
        local fullType = visual:getItemType()
        if fullType and fullType ~= "" then
            local displayItem = instanceItem(fullType)
            snapshot.visuals[#snapshot.visuals + 1] = itemVisualSnapshot(
                visual,
                fullType,
                displayItem and displayItem:getDisplayName() or getText("IGUI_EPE_RecordUnknown"),
                M.getWearLocation(displayItem)
            )
        end
    end
    return snapshot
end

local function readableStyle(prefix, model)
    if not model or model == "" then return getText("IGUI_EPE_RecordNoneValue") end
    local styleId = tostring(model):gsub("^.-:", "")
    local key = prefix .. styleId
    local translated = getTextOrNull and getTextOrNull(key) or nil
    if translated then return translated end
    local readable = styleId
        :gsub("[_%-]+", " ")
        :gsub("(%l)(%u)", "%1 %2")
        :gsub("(%a)(%d)", "%1 %2")
        :gsub("(%d)(%a)", "%1 %2")
    return readable
end

local function collectPossessionNames(container, counts, wornCounts)
    counts = counts or {}
    wornCounts = wornCounts or {}
    local items = container and container:getItems() or nil
    if not items then return counts, wornCounts end
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if not M.isZombieRecord(item) then
            local data = item:getModData()
            local name = item:getDisplayName()
            if data.EugenesZombieRecordWorn then
                wornCounts[name] = (wornCounts[name] or 0) + 1
            else
                counts[name] = (counts[name] or 0) + 1
            end
            if instanceof(item, "InventoryContainer") then
                collectPossessionNames(item:getInventory(), counts, wornCounts)
            end
        end
    end
    return counts, wornCounts
end

local function appendNamedCounts(lines, counts)
    local names = {}
    for name in pairs(counts) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        lines[#lines + 1] = getText("IGUI_EPE_RecordNone")
        return
    end
    for _, name in ipairs(names) do
        local count = counts[name]
        if count > 1 then
            lines[#lines + 1] = getText("IGUI_EPE_RecordItemCountLine", name, tostring(count))
        else
            lines[#lines + 1] = getText("IGUI_EPE_RecordItemLine", name)
        end
    end
end

function M.makeZombieRecordText(snapshot, sourceContainer)
    local appearance = snapshot and snapshot.appearance or {}
    local possessions, physicallyWorn = collectPossessionNames(sourceContainer)
    if next(physicallyWorn) == nil then
        for _, row in ipairs(snapshot and snapshot.worn or {}) do
            local name = row.displayName or getText("IGUI_EPE_RecordUnknown")
            physicallyWorn[name] = (physicallyWorn[name] or 0) + 1
        end
    end
    local sex = appearance.female
        and getText("IGUI_EPE_RecordFemale")
        or getText("IGUI_EPE_RecordMale")
    local status = snapshot and snapshot.restoredName
        and getText("IGUI_EPE_RecordRestoredStatus", snapshot.restoredName)
        or getText("IGUI_EPE_RecordStatus")
    local lines = {
        getText("IGUI_EPE_RecordHeader"),
        "",
        status,
        getText("IGUI_EPE_RecordSex", sex),
        getText("IGUI_EPE_RecordHair", readableStyle("IGUI_Hair_", appearance.hairModel)),
        getText("IGUI_EPE_RecordBeard", readableStyle("IGUI_Beard_", appearance.beardModel)),
        "",
        getText("IGUI_EPE_RecordWornHeader"),
    }
    appendNamedCounts(lines, physicallyWorn)
    lines[#lines + 1] = ""
    lines[#lines + 1] = getText("IGUI_EPE_RecordPossessionsHeader")
    appendNamedCounts(lines, possessions)
    lines[#lines + 1] = ""
    lines[#lines + 1] = getText("IGUI_EPE_RecordWarning")
    return table.concat(lines, "\n")
end

local function writeZombieRecord(record, snapshot, sourceContainer)
    if not record or not snapshot then return false end
    local data = record:getModData()
    data.EugenesZombieRecordKind = "pacified-zombie"
    data.EugenesZombieRecordVersion = M.RECORD_SCHEMA_VERSION
    data.EugenesZombieRecordSnapshot = snapshot
    data.preserve = true
    record:setCanBeWrite(true)
    record:setLockedBy("EugenesProneEquipment")
    record:setNumberOfPages(1)
    record:setPageToWrite(1)
    record:addPage(1, M.makeZombieRecordText(snapshot, sourceContainer))
    if record.syncItemFields then pcall(record.syncItemFields, record) end
    return true
end

function M.createZombieRecordFromSnapshot(snapshot, container)
    if not snapshot or not container then return nil end
    local record = M.findZombieRecord(container)
    if not record then
        record = instanceItem(M.RECORD_FULL_TYPE)
        if not record then return nil end
        container:AddItem(record)
    end
    if not writeZombieRecord(record, snapshot, container) then return nil end
    return record
end

function M.createOrUpdateZombieRecord(zombie)
    if not zombie then return nil end
    local existing = M.findZombieRecord(zombie:getInventory())
    local previous = M.getZombieRecordSnapshot(existing)
    local snapshot = M.makeZombieSnapshot(zombie)
    if not snapshot then return nil end
    if previous and previous.restoredName then
        snapshot.restoredName = previous.restoredName
    end
    return M.createZombieRecordFromSnapshot(snapshot, zombie:getInventory())
end

local function markItemsFromSnapshot(container, snapshot)
    if not container or not snapshot then return end
    local items = container:getItems()
    local candidates = {}
    local used = {}

    for index = 0, items:size() - 1 do
        local item = items:get(index)
        local data = item:getModData()
        candidates[#candidates + 1] = {
            item = item,
            wasWorn = data.EugenesZombieRecordWorn == true,
            location = data.EugenesZombieRecordWearLocation,
        }
        M.clearRecordWearMarker(item)
    end

    local function findCandidate(row, pass)
        for _, candidate in ipairs(candidates) do
            local item = candidate.item
            if not used[item] and item:getFullType() == row.fullType then
                local sameLocation = row.location and candidate.location
                    and tostring(row.location) == tostring(candidate.location)
                if (pass == 1 and candidate.wasWorn and sameLocation)
                    or (pass == 2 and candidate.wasWorn)
                    or pass == 3 then
                    return candidate
                end
            end
        end
        return nil
    end

    for _, row in ipairs(snapshot.worn or {}) do
        local candidate = findCandidate(row, 1)
            or findCandidate(row, 2)
            or findCandidate(row, 3)
        local item = candidate and candidate.item or nil
        local location = item and M.resolveWearLocation(
            row.location or candidate.location,
            item
        ) or nil
        if item and location then
            local data = item:getModData()
            data.EugenesZombieRecordWorn = true
            data.EugenesZombieRecordWearLocation = tostring(location)
            data.preserve = true
            used[item] = true
        end
    end
end

local function findVisualRow(snapshot, item, location)
    for _, row in ipairs(snapshot.worn or {}) do
        if row.fullType == item:getFullType()
            and (not row.location or tostring(row.location) == tostring(location)) then
            return row
        end
    end
    for _, row in ipairs(snapshot.visuals or {}) do
        if row.fullType == item:getFullType() then return row end
    end
    return nil
end

function M.applyZombieRecord(zombie, record, applyHealth)
    local snapshot = M.getZombieRecordSnapshot(record)
    if not zombie or not snapshot then return false end
    local appearance = snapshot.appearance or {}
    if appearance.female ~= nil and zombie.setFemaleEtc then
        zombie:setFemaleEtc(appearance.female)
    end
    local humanVisual = zombie:getHumanVisual()
    humanVisual:clear()
    local skinColor = colorFromSnapshot(appearance.skinColor)
    local hairColor = colorFromSnapshot(appearance.hairColor)
    local beardColor = colorFromSnapshot(appearance.beardColor)
    local naturalHairColor = colorFromSnapshot(appearance.naturalHairColor)
    local naturalBeardColor = colorFromSnapshot(appearance.naturalBeardColor)
    if skinColor then humanVisual:setSkinColor(skinColor) end
    if appearance.bodyHairIndex and appearance.bodyHairIndex >= 0 then
        humanVisual:setBodyHairIndex(appearance.bodyHairIndex)
    end
    if appearance.hairModel then humanVisual:setHairModel(appearance.hairModel) end
    if appearance.beardModel then humanVisual:setBeardModel(appearance.beardModel) end
    if appearance.nonAttachedHair then humanVisual:setNonAttachedHair(appearance.nonAttachedHair) end
    if hairColor then humanVisual:setHairColor(hairColor) end
    if beardColor then humanVisual:setBeardColor(beardColor) end
    if naturalHairColor then humanVisual:setNaturalHairColor(naturalHairColor) end
    if naturalBeardColor then humanVisual:setNaturalBeardColor(naturalBeardColor) end
    if appearance.skinTextureName then
        humanVisual:setSkinTextureName(appearance.skinTextureName)
    end
    humanVisual:removeBlood()
    humanVisual:removeDirt()
    humanVisual:getBodyVisuals():clear()
    if applyHealth and appearance.health then
        zombie:setHealth(math.max(0.1, appearance.health))
    end

    local inventory = zombie:getInventory()
    markItemsFromSnapshot(inventory, snapshot)
    zombie:clearWornItems()
    local items = inventory:getItems()
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        local data = item:getModData()
        if data.EugenesZombieRecordWorn then
            local recordedLocation = data.EugenesZombieRecordWearLocation
            local location = M.resolveWearLocation(recordedLocation, item)
            if location then
                applyItemVisualSnapshot(
                    item:getVisual(),
                    findVisualRow(snapshot, item, recordedLocation or location)
                )
                zombie:setWornItem(location, item, false)
            end
        end
    end

    local itemVisuals = zombie:getItemVisuals()
    itemVisuals:clear()
    zombie:getWornItems():getItemVisuals(itemVisuals)
    local maxIndex = BloodBodyPartType.MAX:index()
    for index = 0, itemVisuals:size() - 1 do
        local visual = itemVisuals:get(index)
        visual:removeBlood()
        visual:removeDirt()
        for bodyPartIndex = 0, maxIndex - 1 do visual:removeHole(bodyPartIndex) end
    end
    zombie:resetModelNextFrame()
    return true
end
