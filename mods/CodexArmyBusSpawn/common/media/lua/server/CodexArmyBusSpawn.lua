local MOD_TAG = "[CodexArmyBusSpawn] "
local STATE_KEY = "CodexArmyBusSpawn_v1"
local CONFIG_VERSION = 5
local VEHICLE_SCRIPT = "Base.ATAArmyBus"

local SPAWN_X = 13705
local SPAWN_Y = 1793
local SPAWN_Z = 0
local CHECK_INTERVAL = 60

local RV_DATA_KEY = "modPROJECTRVInterior"
local RV_ASSIGNED_ROOMS_KEY = "AssignedRooms4x12colossal"
local RV_ROOM_WIDTH = 4
local RV_ROOM_HEIGHT = 12
local RV_EXTERIOR_MARGIN = 5
local RV_EXTERIOR_VERSION = 1

local REQUESTED_ITEMS = {
    "Base.Bag_Satchel_Military",
    "Base.Glasses_Normal",
    "Base.Trousers_CamoGreen",
    "MoreTraits.AntiqueJacket",
    "MoreTraits.Slugger",
    "MoreTraits.AntiqueBoots",
    "Base.BookCarpentry1",
    "Base.BookCarpentry2",
    "Base.BookCarpentry3",
    "ScavengingSkill.BookScavenging2",
    "ScavengingSkill.BookScavenging3",
    "ExtraBooks.EBBlunt1",
    "ExtraBooks.EBBlunt2",
    "ExtraBooks.EBBlunt3",
    "ExtraBooks.EBBlunt4",
    "ExtraBooks.EBBlunt5",
    "Base.Canteen",
    "Base.Hat_WinterHat",
    "Base.Scarf_White",
    "Base.Gloves_LeatherGlovesBlack",
    "Base.FlashLight_AngleHead_Army",
    "MoreTraits.Thumper",
    "Base.Belt2",
    "Base.Hat_GasMask_nofilter",
    "Base.GasmaskFilter",
    "MoreTraits.Bag_PackerBag",
    "Base.CarBatteryCharger",
}

local VERSION_2_ITEMS = {
    "Base.Hat_GasMask_nofilter",
    "Base.GasmaskFilter",
}

local VERSION_3_ITEMS = {
    "Base.BookCarpentry2",
    "Base.BookCarpentry3",
    "ExtraBooks.EBBlunt1",
    "ExtraBooks.EBBlunt2",
    "ExtraBooks.EBBlunt3",
    "ExtraBooks.EBBlunt4",
    "ExtraBooks.EBBlunt5",
}

local VERSION_4_ITEMS = {
    "MoreTraits.Bag_PackerBag",
    "Base.CarBatteryCharger",
}

local VERSION_5_REMOVED_ITEMS = {
    "Base.Bag_ALICEpack_Army",
}

local REQUESTED_MOVEABLES = {
    { sprite = "carpentry_01_16", count = 6 },
    { sprite = "location_trailer_02_22", count = 4 },
    { sprite = "location_community_school_01_12", count = 1 },
}

local ticks = 0
local loggedMissingItem = false
local loggedSpawnFailure = false

local function log(message)
    print(MOD_TAG .. message)
end

local function allRequestedItemsExist()
    for _, fullType in ipairs(REQUESTED_ITEMS) do
        if not ScriptManager.instance:FindItem(fullType) then
            if not loggedMissingItem then
                log("Missing item script " .. fullType .. "; the bus will not spawn.")
                loggedMissingItem = true
            end
            return false
        end
    end

    for _, definition in ipairs(REQUESTED_MOVEABLES) do
        local moveable = instanceItem("Moveables.Moveable")
        if not moveable or not moveable:ReadFromWorldSprite(definition.sprite) then
            if not loggedMissingItem then
                log("Missing moveable sprite " .. definition.sprite .. "; the bus will not spawn.")
                loggedMissingItem = true
            end
            return false
        end
    end

    return true
end

local function safetyAreaIsLoaded(cell)
    return cell:getGridSquare(SPAWN_X, SPAWN_Y, SPAWN_Z)
end

local function prepareStorageAndDoors(vehicle)
    local rearStorage = nil

    for index = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(index)
        local container = part:getItemContainer()
        if container then
            container:clear()
            container:setExplored(true)
            if part:getId() == "TruckBed" then
                rearStorage = container
            end
        end

        local door = part:getDoor()
        if door then
            door:setLocked(false)
            door:setLockBroken(false)
        end
    end

    return rearStorage
end

local function addFreshItem(container, fullType)
    local item = instanceItem(fullType)
    if item then
        item:setCondition(item:getConditionMax())

        if fullType == "Base.Hat_WinterHat" then
            -- Third texture is the black winter-hat variant.
            item:getVisual():setTextureChoice(2)
        elseif fullType == "Base.Scarf_White" then
            -- The plain scarf is tintable; make this one black.
            item:getVisual():setTint(ImmutableColor.new(0.08, 0.08, 0.08, 1.0))
        elseif fullType == "Base.FlashLight_AngleHead_Army" then
            item:setUsedDelta(1.0)
        elseif fullType == "Base.GasmaskFilter" then
            item:setUsedDelta(1.0)
        end

        container:AddItem(item)
    end
    return item
end

local function addMoveable(container, sprite)
    local item = instanceItem("Moveables.Moveable")
    if item and item:ReadFromWorldSprite(sprite) then
        item:setCondition(item:getConditionMax())
        container:AddItem(item)
        return item
    end
    return nil
end

local function findRearStorage(vehicle)
    local part = vehicle and vehicle:getPartById("TruckBed") or nil
    return part and part:getItemContainer() or nil
end

local function emptyEnergyStores(vehicle)
    local gasTank = vehicle:getPartById("GasTank")
    if gasTank then
        gasTank:setCondition(100)
        gasTank:setContainerContentAmount(0)
        vehicle:transmitPartCondition(gasTank)
        vehicle:transmitPartModData(gasTank)
    end

    local battery = vehicle:getPartById("Battery")
    if battery then
        battery:setCondition(100)
        local batteryItem = battery:getInventoryItem()
        if batteryItem then
            batteryItem:setCondition(batteryItem:getConditionMax())
            batteryItem:setUsedDelta(0.0)
        end
        vehicle:transmitPartCondition(battery)
        vehicle:transmitPartUsedDelta(battery)
    end
end

local function finishVehicle(vehicle)
    vehicle:repair()
    vehicle:setLocked(false)

    local rearStorage = prepareStorageAndDoors(vehicle)
    if not rearStorage then
        error("Army Bus has no TruckBed storage part")
    end

    emptyEnergyStores(vehicle)

    vehicle:setEngineFeature(100, 30, vehicle:getScript():getEngineForce())

    local key = vehicle:createVehicleKey()
    if not key then
        error("Could not create the Army Bus key")
    end
    rearStorage:AddItem(key)

    for _, fullType in ipairs(REQUESTED_ITEMS) do
        if not addFreshItem(rearStorage, fullType) then
            error("Could not create requested item " .. fullType)
        end
    end

    for _, definition in ipairs(REQUESTED_MOVEABLES) do
        for _ = 1, definition.count do
            if not addMoveable(rearStorage, definition.sprite) then
                error("Could not create requested moveable " .. definition.sprite)
            end
        end
    end

    vehicle:getModData().CodexArmyBusSpawn = true
end

local function rememberSpawn(vehicle)
    local state = ModData.getOrCreate(STATE_KEY)
    state.spawned = true
    state.vehicleId = vehicle:getId()
    state.x = SPAWN_X
    state.y = SPAWN_Y
    state.z = SPAWN_Z
    state.configVersion = CONFIG_VERSION
end

local function updateExistingBus(state)
    if not state.vehicleId then return false end

    local vehicle = getVehicleById(state.vehicleId)
    if not vehicle or not vehicle:getModData().CodexArmyBusSpawn then
        return false
    end

    local rearStorage = findRearStorage(vehicle)
    if not rearStorage then return false end

    local previousVersion = tonumber(state.configVersion) or 1
    emptyEnergyStores(vehicle)

    if previousVersion < 2 then
        for _, fullType in ipairs(VERSION_2_ITEMS) do
            if not addFreshItem(rearStorage, fullType) then
                error("Could not add version 2 item " .. fullType .. " to the existing Army Bus")
            end
        end
    end

    if previousVersion < 3 then
        for _, fullType in ipairs(VERSION_3_ITEMS) do
            if not addFreshItem(rearStorage, fullType) then
                error("Could not add version 3 item " .. fullType .. " to the existing Army Bus")
            end
        end
    end

    if previousVersion < 4 then
        for _, fullType in ipairs(VERSION_4_ITEMS) do
            if not addFreshItem(rearStorage, fullType) then
                error("Could not add version 4 item " .. fullType .. " to the existing Army Bus")
            end
        end
    end

    if previousVersion < 5 then
        local items = rearStorage:getItems()
        local removedSpawnedBag = false
        for index = items:size() - 1, 0, -1 do
            local item = items:get(index)
            for _, fullType in ipairs(VERSION_5_REMOVED_ITEMS) do
                if item:getFullType() == fullType then
                    rearStorage:Remove(item)
                    removedSpawnedBag = true
                    break
                end
            end
            if removedSpawnedBag then break end
        end
    end

    state.configVersion = CONFIG_VERSION
    log("Updated existing Army Bus " .. tostring(vehicle:getId())
        .. " from inventory version " .. tostring(previousVersion)
        .. " to " .. tostring(CONFIG_VERSION) .. ".")
    return true
end

local function trySpawnBus()
    local state = ModData.getOrCreate(STATE_KEY)
    if state.spawned and (tonumber(state.configVersion) or 1) >= CONFIG_VERSION then
        Events.OnTick.Remove(trySpawnBus)
        return
    end

    ticks = ticks + 1
    if ticks < CHECK_INTERVAL then
        return
    end
    ticks = 0

    if state.spawned then
        if updateExistingBus(state) then
            Events.OnTick.Remove(trySpawnBus)
        end
        return
    end

    local cell = getCell()
    if not cell or not safetyAreaIsLoaded(cell) then
        return
    end

    if not allRequestedItemsExist() then
        return
    end

    local vehicle = addVehicle(VEHICLE_SCRIPT, SPAWN_X, SPAWN_Y, SPAWN_Z)
    if not vehicle then
        if not loggedSpawnFailure then
            log("addVehicle failed; the mod will keep retrying while the area is loaded.")
            loggedSpawnFailure = true
        end
        return
    end

    finishVehicle(vehicle)
    rememberSpawn(vehicle)
    Events.OnTick.Remove(trySpawnBus)
    log("Spawned fresh Army Bus " .. tostring(vehicle:getId()) .. " at 13705,1793,0 with its curated inventory.")
end

Events.OnTick.Add(trySpawnBus)

local function getSpawnedBusAndRememberRVId(state)
    if state.rvUniqueId then return tostring(state.rvUniqueId) end
    if not state.vehicleId then return nil end

    local vehicle = getVehicleById(state.vehicleId)
    if not vehicle or not vehicle:getModData().CodexArmyBusSpawn then return nil end

    local rvUniqueId = vehicle:getModData().projectRV_uniqueId
    if not rvUniqueId then return nil end

    state.rvUniqueId = tostring(rvUniqueId)
    return state.rvUniqueId
end

local function exteriorSpriteFor(x, y)
    -- All four are vanilla dirt-with-grass variants and remain farmable.
    local variants = {
        "blends_natural_01_80",
        "blends_natural_01_85",
        "blends_natural_01_86",
        "blends_natural_01_87",
    }
    return variants[((x * 3 + y * 5) % #variants) + 1]
end

local function patchExteriorSquare(square)
    local spriteName = exteriorSpriteFor(square:getX(), square:getY())
    local floor = square:getFloor()

    if floor then
        local sprite = floor:getSprite()
        if sprite and sprite:getName() == spriteName then return false end
        floor:setSpriteFromName(spriteName)
        floor:transmitUpdatedSpriteToClients()
    else
        floor = square:addFloor(spriteName)
        if not floor then return false end
        floor:transmitCompleteItemToClients()
    end

    floor:getModData().EugenesArmyBusExterior = RV_EXTERIOR_VERSION
    floor:transmitModData()
    square:RecalcProperties()
    square:RecalcAllWithNeighbours(true)
    return true
end

local function tryPrepareRVExterior()
    local state = ModData.getOrCreate(STATE_KEY)
    if (tonumber(state.rvExteriorVersion) or 0) >= RV_EXTERIOR_VERSION then
        Events.EveryOneMinute.Remove(tryPrepareRVExterior)
        return
    end

    local rvUniqueId = getSpawnedBusAndRememberRVId(state)
    if not rvUniqueId then return end

    local rvData = ModData.getOrCreate(RV_DATA_KEY)
    local assignedRooms = rvData[RV_ASSIGNED_ROOMS_KEY]
    local room = assignedRooms and assignedRooms[rvUniqueId] or nil
    if not room then return end

    local roomX = math.floor(tonumber(room.x) or 0)
    local roomY = math.floor(tonumber(room.y) or 0)
    local roomZ = math.floor(tonumber(room.z) or 0)
    if roomX == 0 or roomY == 0 then return end

    local fromX = roomX - RV_EXTERIOR_MARGIN
    local toX = roomX + RV_ROOM_WIDTH + RV_EXTERIOR_MARGIN
    local fromY = roomY - RV_EXTERIOR_MARGIN
    local toY = roomY + RV_ROOM_HEIGHT + RV_EXTERIOR_MARGIN
    local allSquaresLoaded = true
    local changed = 0

    for x = fromX, toX do
        for y = fromY, toY do
            -- Match RV Interior's own room boundary calculation so walls and
            -- every indoor tile retain their original flooring.
            local outsideRoom = x < roomX or x > roomX + RV_ROOM_WIDTH
                or y < roomY or y > roomY + RV_ROOM_HEIGHT
            if outsideRoom then
                local square = getCell():getGridSquare(x, y, roomZ)
                if not square then
                    allSquaresLoaded = false
                elseif patchExteriorSquare(square) then
                    changed = changed + 1
                end
            end
        end
    end

    if not allSquaresLoaded then return end

    state.rvExteriorVersion = RV_EXTERIOR_VERSION
    state.rvExteriorRoomX = roomX
    state.rvExteriorRoomY = roomY
    state.rvExteriorRoomZ = roomZ
    if isServer() then ModData.transmit(STATE_KEY) end
    Events.EveryOneMinute.Remove(tryPrepareRVExterior)
    log("Converted the assigned Army Bus RV exterior at "
        .. tostring(roomX) .. "," .. tostring(roomY) .. "," .. tostring(roomZ)
        .. " to farmable dirt-with-grass (" .. tostring(changed) .. " tiles changed).")
end

Events.EveryOneMinute.Add(tryPrepareRVExterior)
