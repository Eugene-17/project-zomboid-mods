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

local function validateTile(square, ignoredCharacter)
    if not square or square:getZ() ~= 0 then
        return nil, "Pond tiles can only be built at ground level."
    end
    if not square:getFloor() or not square:isSolidFloor() then
        return nil, "This pond tile needs existing solid ground."
    end
    if square:isWaterSquare() then return nil, "This square is already water." end
    if M.getMarkedTileId(square) then
        return nil, "A constructed pond tile is already here."
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
                if (dx ~= 0 or dy ~= 0) and not allByCoord[coordKey(x + dx, y + dy)] then
                    return false
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

local function createTile(playerObj, square, variant)
    local removable, reason = validateTile(square, playerObj)
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

    removeObjects(square, removable)

    local data = tileData()
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
    local createdSchools = rebuildSchools(data)
    transmitData()

    print("[CodexFishingPond] Created " .. variant .. " tile " .. tileId)
    notify(playerObj,
        createdSchools > 0 and "Pond complete: a fish school has formed."
            or (variant == "center" and "Fishable pond center built." or "Pond shoreline built."),
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
    rebuildSchools(data)
    transmitData()
    refreshSquare(square)
    notify(playerObj, "One pond tile has been filled in.", true)
    return true
end

local function isValidBuild(params)
    if not params or not params.square then return false end
    params.testCollisions = false
    local playerObj = getPlayer and getPlayer() or nil
    return validateTile(params.square, playerObj) ~= nil
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

function M.Build.OnIsValidCenter(params) return isValidBuild(params) end
function M.Build.OnIsValidShore(params) return isValidBuild(params) end
function M.Build.OnCreateCenter(params) return createFromParams(params, "center") end
function M.Build.OnCreateCornerNW(params) return createFromParams(params, "cornerNW") end
function M.Build.OnCreateCornerNE(params) return createFromParams(params, "cornerNE") end
function M.Build.OnCreateCornerSW(params) return createFromParams(params, "cornerSW") end
function M.Build.OnCreateCornerSE(params) return createFromParams(params, "cornerSE") end
function M.Build.OnCreateEdgeN(params) return createFromParams(params, "edgeN") end
function M.Build.OnCreateEdgeW(params) return createFromParams(params, "edgeW") end
function M.Build.OnCreateEdgeE(params) return createFromParams(params, "edgeE") end
function M.Build.OnCreateEdgeS(params) return createFromParams(params, "edgeS") end
function M.Build.OnCreateEdgeN2(params) return createFromParams(params, "edgeN2") end
function M.Build.OnCreateEdgeW2(params) return createFromParams(params, "edgeW2") end
function M.Build.OnCreateEdgeE2(params) return createFromParams(params, "edgeE2") end
function M.Build.OnCreateEdgeS2(params) return createFromParams(params, "edgeS2") end

function M.Build.OnIsValidFill(params)
    if not params or not params.square then return false end
    params.testCollisions = false
    params.canBuildOverWater = true
    return M.getMarkedTileId(params.square) ~= nil
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
    rebuildSchools(data)
    transmitData()
    installFishingHooks()
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= M.MODULE or command ~= "checkFishSchool" then return end

    local glasses = playerObj and playerObj:getWornItem(ItemBodyLocation.EYES) or nil
    if not glasses or glasses:getFullType() ~= M.CHECK_GLASSES_TYPE then
        notify(playerObj, "Wear Fish Check Glasses to inspect the water.", false)
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
