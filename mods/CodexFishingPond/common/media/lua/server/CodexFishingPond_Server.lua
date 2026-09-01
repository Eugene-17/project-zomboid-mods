require "CodexFishingPond_Shared"
require "Fishing/FishingZones"
require "Fishing/Fish"

local M = CodexFishingPond
M.Build = M.Build or {}

local function notify(playerObj, message, ok)
    if not playerObj then return end
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "result", { message = message, ok = ok })
    else
        playerObj:setHaloNote(message, 255, ok and 255 or 80, 80, 300)
    end
end

local function tileData()
    local data = ModData.getOrCreate(M.DATA_KEY)
    data.tiles = data.tiles or {}
    data.schools = data.schools or {}
    data.nextId = tonumber(data.nextId) or 0
    data.nextSchoolId = tonumber(data.nextSchoolId) or 0
    return data
end

local function transmitData()
    if isServer() then ModData.transmit(M.DATA_KEY) end
end

local function refreshSquare(square)
    square:disableErosion()
    square:RecalcAllWithNeighbours(true)
end

local function mayRemoveObject(object, floor)
    if object == floor then return true end
    if object:getContainer() then return false end

    local properties = object:getProperties()
    if not properties then return false end
    if properties:has(IsoFlagType.canBeRemoved) then return true end
    if properties:has(IsoFlagType.vegitation) and object:getType() ~= IsoObjectType.tree then
        return true
    end

    local textureName = object:getTextureName()
    return textureName ~= nil
        and string.find(textureName, "blends_grassoverlays", 1, true) ~= nil
end

local function hasBlockingMovingObject(square, ignoredCharacter)
    for index = 0, square:getMovingObjects():size() - 1 do
        if square:getMovingObjects():get(index) ~= ignoredCharacter then return true end
    end
    return false
end

local function validateTile(square, ignoredCharacter, allowShoreReplacement)
    if not square or square:getZ() ~= 0 then
        return nil, "Pond tiles can only be built at ground level."
    end
    if not square:getFloor() or not square:isSolidFloor() then
        return nil, "This pond tile needs existing solid ground."
    end
    if square:isWaterSquare() then return nil, "This square is already water." end
    local existingTileId = M.getMarkedTileId(square)
    if existingTileId then
        local existingRecord = tileData().tiles[existingTileId]
        if not (allowShoreReplacement and existingRecord
                and existingRecord.variant ~= "center") then
            return nil, "A constructed pond tile is already here."
        end
    end
    if Fishing and Fishing.isNoFishZone
        and Fishing.isNoFishZone(square:getX(), square:getY()) then
        return nil, "This map area is designated as non-fishable."
    end
    if hasBlockingMovingObject(square, ignoredCharacter) or square:isVehicleIntersecting() then
        return nil, "A character, animal, or vehicle occupies this square."
    end
    if square:HasStairs() then return nil, "A pond tile cannot overlap stairs." end

    local floor = square:getFloor()
    local removable = {}
    for i = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(i)
        if object ~= floor then
            if not mayRemoveObject(object, floor) then
                return nil, "This square overlaps a structure or stored object."
            end
            removable[#removable + 1] = object
        end
    end
    return removable, nil
end

local function removeObjects(square, objects)
    for _, object in ipairs(objects) do
        square:transmitRemoveItemFromSquare(object)
        square:RemoveTileObject(object)
    end
end

local function removeDummy(thumpable)
    if not thumpable then return nil end
    local square = thumpable:getSquare()
    if not square then return nil end
    square:transmitRemoveItemFromSquare(thumpable)
    square:RemoveTileObject(thumpable)
    return square
end

local function nextTileId(data, square)
    data.nextId = data.nextId + 1
    return tostring(data.nextId) .. "@" .. square:getX() .. "," .. square:getY()
end

local FOUR_NEIGHBOURS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
}

-- A shoreline square is selected from its position relative to a center.
-- Cardinal matches beat diagonal matches so a row of centers produces a
-- continuous straight bank. The A/B straight-edge sprites alternate by map
-- coordinate, matching the varied look of vanilla shoreline painting.
local AUTO_SHORE_RULES = {
    { dx = 0, dy = -1, primary = "edgeN", alternate = "edgeN2", priority = 2 },
    { dx = -1, dy = 0, primary = "edgeW", alternate = "edgeW2", priority = 2 },
    { dx = 1, dy = 0, primary = "edgeE", alternate = "edgeE2", priority = 2 },
    { dx = 0, dy = 1, primary = "edgeS", alternate = "edgeS2", priority = 2 },
    { dx = -1, dy = -1, primary = "cornerNW", priority = 1 },
    { dx = 1, dy = -1, primary = "cornerNE", priority = 1 },
    { dx = -1, dy = 1, primary = "cornerSW", priority = 1 },
    { dx = 1, dy = 1, primary = "cornerSE", priority = 1 },
}

local function coordKey(x, y)
    return tostring(x) .. "," .. tostring(y)
end

local function collectTileMaps(data)
    local allByCoord = {}
    local centersByCoord = {}

    for tileId, record in pairs(data.tiles) do
        if type(record) == "table" and tonumber(record.z) == 0 then
            local entry = { tileId = tileId, record = record }
            local key = coordKey(record.x, record.y)
            allByCoord[key] = entry
            if record.variant == "center" then
                centersByCoord[key] = entry
            end
        end
    end

    return allByCoord, centersByCoord
end

local function collectCenterComponents(centersByCoord)
    local components = {}
    local visited = {}

    for startKey, startEntry in pairs(centersByCoord) do
        if not visited[startKey] then
            local component = {}
            local queue = { startEntry }
            local queueIndex = 1
            visited[startKey] = true

            while queueIndex <= #queue do
                local entry = queue[queueIndex]
                queueIndex = queueIndex + 1
                component[#component + 1] = entry

                for _, offset in ipairs(FOUR_NEIGHBOURS) do
                    local key = coordKey(entry.record.x + offset[1], entry.record.y + offset[2])
                    local neighbour = centersByCoord[key]
                    if neighbour and not visited[key] then
                        visited[key] = true
                        queue[#queue + 1] = neighbour
                    end
                end
            end

            components[#components + 1] = component
        end
    end

    return components
end

local function isClosedPond(component, allByCoord)
    if #component == 0 then return false end

    -- Every water tile must be surrounded in all eight directions by another
    -- constructed water or shoreline tile.  One center plus its complete ring
    -- is the minimum legitimate 3x3 pond.
    for _, entry in ipairs(component) do
        local x = entry.record.x
        local y = entry.record.y
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local neighbourX = x + dx
                    local neighbourY = y + dy
                    if not allByCoord[coordKey(neighbourX, neighbourY)] then
                        -- Natural or other already-existing water replaces the
                        -- automatic bank on that square and still closes the pond.
                        local square = getCell():getGridSquare(neighbourX, neighbourY, 0)
                        if not square or not square:isWaterSquare() then return false end
                    end
                end
            end
        end
    end

    return true
end

local function schoolHasTile(school, tileId)
    return school and type(school.tileIds) == "table" and school.tileIds[tileId] == true
end

local function schoolCenterRecords(data, school)
    local centers = {}
    if not school or type(school.tileIds) ~= "table" then return centers end

    for tileId in pairs(school.tileIds) do
        local record = data.tiles[tileId]
        if record and record.variant == "center" then
            centers[#centers + 1] = record
        end
    end

    table.sort(centers, function(a, b)
        if a.y == b.y then return a.x < b.x end
        return a.y < b.y
    end)
    return centers
end

local function schoolSupportPoints(data, school)
    local points = {}
    for _, center in ipairs(schoolCenterRecords(data, school)) do
        local covered = false
        for _, point in ipairs(points) do
            local dx = center.x - point.x
            local dy = center.y - point.y
            if dx * dx + dy * dy <= 9 then
                covered = true
                break
            end
        end
        if not covered then
            points[#points + 1] = { x = center.x, y = center.y }
        end
    end
    return points
end

local function refreshSchoolSupport(data, school)
    if not school or (tonumber(school.stock) or 0) <= 0 then return end
    local manager = FishSchoolManager and FishSchoolManager.getInstance()
    if not manager then return end

    for _, point in ipairs(schoolSupportPoints(data, school)) do
        manager:addChum(point.x, point.y, M.SCHOOL_CHUM_FORCE_MINUTES)
    end
end

local function refreshAllSchoolSupport()
    local data = tileData()
    for _, school in pairs(data.schools) do
        refreshSchoolSupport(data, school)
    end
end

local function rebuildSchools(data)
    local allByCoord, centersByCoord = collectTileMaps(data)
    local components = collectCenterComponents(centersByCoord)
    local oldSchools = data.schools or {}
    local newSchools = {}
    local usedSchools = {}
    local createdCount = 0

    for _, component in ipairs(components) do
        if isClosedPond(component, allByCoord) then
            local bestSchoolId = nil
            local bestOverlap = 0

            for schoolId, school in pairs(oldSchools) do
                if not usedSchools[schoolId] then
                    local overlap = 0
                    for _, entry in ipairs(component) do
                        if schoolHasTile(school, entry.tileId) then overlap = overlap + 1 end
                    end
                    if overlap > bestOverlap then
                        bestOverlap = overlap
                        bestSchoolId = schoolId
                    end
                end
            end

            local school
            if bestSchoolId then
                school = oldSchools[bestSchoolId]
                usedSchools[bestSchoolId] = true
            else
                data.nextSchoolId = data.nextSchoolId + 1
                bestSchoolId = tostring(data.nextSchoolId)
                school = { stock = 0 }
                createdCount = createdCount + 1
            end

            local tileIds = {}
            for _, entry in ipairs(component) do tileIds[entry.tileId] = true end

            local capacity = M.SCHOOL_BASE_CAPACITY + M.SCHOOL_FISH_PER_CENTER * #component
            school.tileIds = tileIds
            school.capacity = capacity
            if createdCount > 0 and school.stock == 0 and not oldSchools[bestSchoolId] then
                school.stock = capacity
            else
                school.stock = math.max(0, math.min(tonumber(school.stock) or capacity, capacity))
            end
            newSchools[bestSchoolId] = school
        end
    end

    data.schools = newSchools
    for _, school in pairs(data.schools) do refreshSchoolSupport(data, school) end
    return createdCount
end

local function findSchoolAt(x, y)
    local square = getCell():getGridSquare(math.floor(x), math.floor(y), 0)
    local tileId = square and M.getMarkedTileId(square) or nil
    if not tileId then return nil, nil end

    local data = tileData()
    for schoolId, school in pairs(data.schools) do
        if schoolHasTile(school, tileId) then return school, schoolId end
    end
    return nil, nil
end

local function installFishingHooks()
    local Fish = Fishing and Fishing.Fish or nil
    if not Fish or Fish.CodexFishingPondHooksInstalled then return end
    Fish.CodexFishingPondHooksInstalled = true

    local originalGetFishByLure = Fish.getFishByLure
    Fish.getFishByLure = function(self, ...)
        local school = findSchoolAt(self.x, self.y)
        if school and (tonumber(school.stock) or 0) <= 0 then
            return Fishing.trashItems[ZombRand(#Fishing.trashItems) + 1], true
        end
        return originalGetFishByLure(self, ...)
    end

    local originalGetFish = Fish.getFish
    Fish.getFish = function(self, ...)
        local school, schoolId = findSchoolAt(self.x, self.y)
        local result = originalGetFish(self, ...)

        if school and self.fishItem and not self.isTrash and (tonumber(school.stock) or 0) > 0 then
            school.stock = math.max(0, (tonumber(school.stock) or 0) - 1)
            transmitData()
            print("[CodexFishingPond] Fish caught from school " .. tostring(schoolId)
                .. "; " .. tostring(school.stock) .. "/" .. tostring(school.capacity) .. " remain")
        end

        return result
    end
end

local function repopulateSchools()
    local data = tileData()
    local changed = false

    for _, school in pairs(data.schools) do
        local stock = tonumber(school.stock) or 0
        local capacity = tonumber(school.capacity) or 0
        if stock < capacity then
            school.stock = math.min(capacity, stock + M.SCHOOL_REPOPULATE_PER_DAY)
            changed = true
        end
        refreshSchoolSupport(data, school)
    end

    if changed then transmitData() end
end

local function findAttachedSpriteIndex(floor, spriteName)
    if not floor or not spriteName then return nil end
    local attached = floor:getAttachedAnimSprite()
    if not attached then return nil end
    for i = 0, attached:size() - 1 do
        local instance = attached:get(i)
        local sprite = instance and instance:getParentSprite() or nil
        if sprite and sprite:getName() == spriteName then return i end
    end
    return nil
end

local function attachShoreToFloor(floor, tileId, variant)
    local spriteName = M.SHORE_SPRITES[variant]
    if not spriteName then return false end
    if findAttachedSpriteIndex(floor, spriteName) == nil then
        floor:addAttachedAnimSpriteByName(spriteName)
    end
    floor:getModData()[M.MARKER_KEY] = tileId
    floor:getModData()[M.VARIANT_KEY] = variant
    floor:transmitModData()
    floor:transmitUpdatedSpriteToClients()
    return true
end

local function chooseAutomaticShoreVariant(rule, x, y)
    if not rule.alternate then return rule.primary end
    local varied = math.abs(x * 31 + y * 17) % 2
    return varied == 0 and rule.primary or rule.alternate
end

local function desiredAutomaticShoreVariant(centersByCoord, x, y)
    local selected = nil
    local selectedPriority = -1

    for _, rule in ipairs(AUTO_SHORE_RULES) do
        local centerKey = coordKey(x - rule.dx, y - rule.dy)
        if centersByCoord[centerKey] and rule.priority > selectedPriority then
            selected = chooseAutomaticShoreVariant(rule, x, y)
            selectedPriority = rule.priority
        end
    end

    return selected
end


local function removeShoreRecord(data, square, tileId, record)
    local floor = square and square:getFloor() or nil
    if floor then
        local spriteName = record and M.SHORE_SPRITES[record.variant] or nil
        local index = findAttachedSpriteIndex(floor, spriteName)
        if index ~= nil then floor:RemoveAttachedAnim(index) end

        if floor:getModData()[M.MARKER_KEY] == tileId then
            floor:getModData()[M.MARKER_KEY] = nil
            floor:getModData()[M.VARIANT_KEY] = nil
            floor:transmitModData()
        end
        floor:transmitUpdatedSpriteToClients()
    end
    data.tiles[tileId] = nil
    if square then refreshSquare(square) end
end

local function reconcileAutomaticShoreAt(data, centersByCoord, square, ignoredCharacter)
    if not square or square:getZ() ~= 0 or not square:getFloor() then return false end

    local tileId = M.getMarkedTileId(square)
    local record = tileId and data.tiles[tileId] or nil
    if record and record.variant == "center" then return false end

    local desired = desiredAutomaticShoreVariant(
        centersByCoord, square:getX(), square:getY())

    -- Never paint a bank over natural water or another constructed water tile.
    if square:isWaterSquare() then desired = nil end

    if record and not record.autoShore then
        -- Preserve shore pieces from older saves. They remain removable with
        -- Fill In Pond Tile and continue to satisfy the closed-pond check.
        return false
    end

    if record then
        if not desired then
            removeShoreRecord(data, square, tileId, record)
            return true
        end
        if record.variant ~= desired then
            local floor = square:getFloor()
            local oldIndex = findAttachedSpriteIndex(floor, M.SHORE_SPRITES[record.variant])
            if oldIndex ~= nil then floor:RemoveAttachedAnim(oldIndex) end
            record.variant = desired
            attachShoreToFloor(floor, tileId, desired)
            refreshSquare(square)
            return true
        end
        return false
    end

    if not desired then return false end

    local removable = validateTile(square, ignoredCharacter, false)
    if not removable then return false end

    local originalFloor = square:getFloor():getSprite()
    local originalSprite = originalFloor and originalFloor:getName() or nil
    if not originalSprite then return false end

    removeObjects(square, removable)
    tileId = nextTileId(data, square)
    attachShoreToFloor(square:getFloor(), tileId, desired)
    data.tiles[tileId] = {
        x = square:getX(), y = square:getY(), z = square:getZ(),
        variant = desired, originalSprite = originalSprite, autoShore = true,
    }
    refreshSquare(square)
    return true
end

local function reconcileAutomaticShoreRegion(data, x, y, ignoredCharacter)
    local _, centersByCoord = collectTileMaps(data)
    local changed = false

    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = getCell():getGridSquare(x + dx, y + dy, 0)
            if reconcileAutomaticShoreAt(
                    data, centersByCoord, square, ignoredCharacter) then
                changed = true
            end
        end
    end

    return changed
end

local function createTile(playerObj, square, variant)
    local removable, reason = validateTile(square, playerObj, variant == "center")
    if not removable then
        print("[CodexFishingPond] " .. variant .. " rejected at "
            .. square:getX() .. "," .. square:getY() .. ": " .. tostring(reason))
        notify(playerObj, reason, false)
        return false
    end

    local originalFloor = square:getFloor():getSprite()
    local originalSprite = originalFloor and originalFloor:getName() or nil
    if not originalSprite then
        notify(playerObj, "The original ground cannot be restored safely.", false)
        return false
    end

    local data = tileData()
    local existingTileId = M.getMarkedTileId(square)
    local existingRecord = existingTileId and data.tiles[existingTileId] or nil
    if variant == "center" and existingRecord and existingRecord.variant ~= "center" then
        removeShoreRecord(data, square, existingTileId, existingRecord)
    end

    removeObjects(square, removable)

    local tileId = nextTileId(data, square)
    local placedObject
    if variant == "center" then
        local spriteIndex = ((square:getX() * 3 + square:getY() * 5) % #M.WATER_SPRITES) + 1
        placedObject = square:addFloor(M.WATER_SPRITES[spriteIndex])
        placedObject:getModData()[M.MARKER_KEY] = tileId
        placedObject:getModData()[M.VARIANT_KEY] = variant
        placedObject:transmitCompleteItemToClients()
    else
        local spriteName = M.SHORE_SPRITES[variant]
        if not spriteName then
            notify(playerObj, "Unknown pond shoreline variant: " .. tostring(variant), false)
            return false
        end
        placedObject = square:getFloor()
        attachShoreToFloor(placedObject, tileId, variant)
    end
    refreshSquare(square)

    data.tiles[tileId] = {
        x = square:getX(), y = square:getY(), z = square:getZ(),
        variant = variant, originalSprite = originalSprite,
    }
    if variant == "center" then
        reconcileAutomaticShoreRegion(
            data, square:getX(), square:getY(), playerObj)
    end
    local createdSchools = rebuildSchools(data)
    transmitData()

    print("[CodexFishingPond] Created " .. variant .. " tile " .. tileId)
    notify(playerObj,
        createdSchools > 0 and "Pond complete: a fish school has formed."
            or (variant == "center"
                and "Fishable pond center and automatic shoreline built."
                or "Pond shoreline built."),
        true)
    return true
end

local function fillTile(playerObj, square, tileId)
    local data = tileData()
    local record = data.tiles[tileId]
    if not record then
        notify(playerObj, "This pond tile is not registered by the mod.", false)
        return false
    end
    if hasBlockingMovingObject(square, playerObj) or square:isVehicleIntersecting() then
        notify(playerObj, "A character, animal, or vehicle occupies this pond tile.", false)
        return false
    end

    local markedObject = M.findMarkedObject(square)
    if not markedObject then
        notify(playerObj, "The constructed pond tile has changed; filling was cancelled.", false)
        return false
    end

    if record.variant == "center" then
        local floor = square:addFloor(record.originalSprite)
        floor:transmitCompleteItemToClients()
    else
        local floor = square:getFloor()
        local spriteName = M.SHORE_SPRITES[record.variant]
        local index = findAttachedSpriteIndex(floor, spriteName)
        if index ~= nil then floor:RemoveAttachedAnim(index) end
        floor:getModData()[M.MARKER_KEY] = nil
        floor:getModData()[M.VARIANT_KEY] = nil
        floor:transmitModData()
        floor:transmitUpdatedSpriteToClients()
    end

    data.tiles[tileId] = nil
    reconcileAutomaticShoreRegion(data, record.x, record.y, playerObj)
    rebuildSchools(data)
    transmitData()
    refreshSquare(square)
    notify(playerObj, "Pond tile filled in; the automatic shoreline was updated.", true)
    return true
end

local function isValidBuild(params, allowShoreReplacement)
    if not params or not params.square then return false end
    params.testCollisions = false
    local playerObj = getPlayer and getPlayer() or nil
    return validateTile(params.square, playerObj, allowShoreReplacement) ~= nil
end

local function createFromParams(params, variant)
    if not params or not params.thumpable or not params.character then
        print("[CodexFishingPond] " .. variant .. " received incomplete build parameters")
        return { objectAlreadyTransmitted = true }
    end
    local square = removeDummy(params.thumpable)
    if square then createTile(params.character, square, variant) end
    return { objectAlreadyTransmitted = true }
end

function M.Build.OnIsValidCenter(params) return isValidBuild(params, true) end
function M.Build.OnCreateCenter(params) return createFromParams(params, "center") end

function M.Build.OnIsValidFill(params)
    if not params or not params.square then return false end
    params.testCollisions = false
    params.canBuildOverWater = true
    local tileId = M.getMarkedTileId(params.square)
    local record = tileId and tileData().tiles[tileId] or nil
    return record ~= nil and (record.variant == "center" or not record.autoShore)
end

function M.Build.OnCreateFill(params)
    if not params or not params.thumpable or not params.character then
        return { objectAlreadyTransmitted = true }
    end
    local square = removeDummy(params.thumpable)
    local tileId = square and M.getMarkedTileId(square) or nil
    if tileId then
        fillTile(params.character, square, tileId)
    else
        notify(params.character, "This is not a pond tile made by this mod.", false)
    end
    return { objectAlreadyTransmitted = true }
end

-- Version 2 originally stored shoreline sprites as independent IsoObjects.
-- Convert those objects to real floor attachments as their squares load.
local function migrateLegacyShoreSquare(square)
    if not square or not square:getFloor() then return end
    local markedObject, tileId = M.findMarkedObject(square)
    if not markedObject or not tileId or markedObject == square:getFloor() then return end

    local data = tileData()
    local record = data.tiles[tileId]
    if not record or record.variant == "center" or not M.SHORE_SPRITES[record.variant] then return end

    square:transmitRemoveItemFromSquare(markedObject)
    square:RemoveTileObject(markedObject)
    attachShoreToFloor(square:getFloor(), tileId, record.variant)
    refreshSquare(square)
    print("[CodexFishingPond] Migrated shoreline tile " .. tileId .. " to a floor attachment")
end

Events.LoadGridsquare.Add(migrateLegacyShoreSquare)

local function reconcileLoadedAutomaticShore(square)
    if not square or square:getZ() ~= 0 then return end
    local data = tileData()
    local tileId = M.getMarkedTileId(square)
    local record = tileId and data.tiles[tileId] or nil

    -- LoadGridsquare fires for the whole streamed world. Avoid rebuilding the
    -- pond index unless this square is a pond tile or borders a loaded center.
    local nearCenter = record and record.variant == "center"
    if not nearCenter then
        for _, rule in ipairs(AUTO_SHORE_RULES) do
            local neighbour = getCell():getGridSquare(
                square:getX() - rule.dx, square:getY() - rule.dy, 0)
            local neighbourId = neighbour and M.getMarkedTileId(neighbour) or nil
            local neighbourRecord = neighbourId and data.tiles[neighbourId] or nil
            if neighbourRecord and neighbourRecord.variant == "center" then
                nearCenter = true
                break
            end
        end
    end
    if not nearCenter and not (record and record.autoShore) then return end

    local _, centersByCoord = collectTileMaps(data)
    if reconcileAutomaticShoreAt(data, centersByCoord, square, nil) then
        rebuildSchools(data)
        transmitData()
    end
end

Events.LoadGridsquare.Add(reconcileLoadedAutomaticShore)

local function migrateLoadedShoreRecords()
    local data = tileData()
    for _, record in pairs(data.tiles) do
        if record.variant ~= "center" then
            local square = getCell():getGridSquare(record.x, record.y, record.z)
            if square then migrateLegacyShoreSquare(square) end
        end
    end
end

Events.OnLoad.Add(migrateLoadedShoreRecords)

local function initializeSchools()
    local data = tileData()
    local centers = {}
    for _, record in pairs(data.tiles) do
        if record.variant == "center" then centers[#centers + 1] = record end
    end
    for _, center in ipairs(centers) do
        reconcileAutomaticShoreRegion(data, center.x, center.y, nil)
    end
    rebuildSchools(data)
    transmitData()
    installFishingHooks()
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= M.MODULE or command ~= "checkFishSchool" then return end

    if not playerObj or playerObj:getPerkLevel(Perks.Fishing) < 4 then
        notify(playerObj, "Fishing 4 is required to inspect fish stocks.", false)
        return
    end

    local x = args and tonumber(args.x) or nil
    local y = args and tonumber(args.y) or nil
    local z = args and tonumber(args.z) or nil
    if not x or not y or z ~= 0
        or IsoUtils.DistanceTo(playerObj:getX(), playerObj:getY(), x, y) > 16 then
        notify(playerObj, "That water tile is too far away.", false)
        return
    end

    local square = getCell():getGridSquare(math.floor(x), math.floor(y), 0)
    local info = M.getSchoolInfoAt(square)
    notify(playerObj, M.describeSchoolInfo(info), info ~= nil)
end

installFishingHooks()
Events.OnLoad.Add(initializeSchools)
Events.OnServerStarted.Add(initializeSchools)
Events.EveryHours.Add(refreshAllSchoolSupport)
Events.EveryDays.Add(repopulateSchools)
Events.OnClientCommand.Add(onClientCommand)
