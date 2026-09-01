require "Tuning2/ATATuning2Commands"

local MOD_TAG = "[CodexArmyBusSpawn] "
local STATE_KEY = "CodexArmyBusSpawn_v1"
local CONFIG_VERSION = 7
local VEHICLE_SCRIPT = "Base.ATAArmyBus"

local SPAWN_X = 13705
local SPAWN_Y = 1793
local SPAWN_Z = 0
local CHECK_INTERVAL = 60

local REQUESTED_ITEMS = {
    "Base.Bag_Satchel_Military",
    "Base.Glasses_Normal",
    "Base.Trousers_CamoGreen",
    "Base.Canteen",
    "Base.Hat_WinterHat",
    "Base.Scarf_White",
    "Base.Gloves_LeatherGlovesBlack",
    "Base.FlashLight_AngleHead_Army",
    "Base.Belt2",
    "Base.SledgehammerHead",
    "Base.Crowbar",
    "Base.RubberHose",
    "Base.Hammer",
    "Base.Saw",
    "Base.BoltCutters",
    "Base.ComfreyCataplasm",
    "Base.ComfreyCataplasm",
    "Base.ComfreyCataplasm",
}

local OPTIONAL_ITEMS = {
    "MoreTraits.AntiqueJacket",
    "MoreTraits.Slugger",
    "MoreTraits.AntiqueBoots",
    "MoreTraits.Bag_PackerBag",
}

local VERSION_2_ITEMS = {}

local VERSION_4_ITEMS = {}

local VERSION_5_REMOVED_ITEMS = {
    "Base.Bag_ALICEpack_Army",
}

local REQUESTED_MOVEABLES = {
    { sprite = "carpentry_01_16", count = 1 },
    { sprite = "location_community_school_01_12", count = 1 },
}

local LEGACY_PACKED_BOOKS = {
    ["Base.BookForagingSet"] = true,
    ["Base.BookCarpentrySet"] = true,
    ["Base.BookTailoringSet"] = true,
    ["ExtraBooks.EBSetBlunt"] = true,
    ["ExtraBooks.EBSetFitness"] = true,
    ["ExtraBooks.EBSetStrength"] = true,
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

local function configureBody(vehicle)
    -- Army Bus skin 0 is the plain default texture. Skin 1 is the painted
    -- variant with side lettering.
    vehicle:setSkinIndex(0)
    vehicle:updateSkin()
    if vehicle.transmitSkinIndex then vehicle:transmitSkinIndex() end

    -- Autotsar gives this tuning part a random spawn chance. Remove it from
    -- the fresh bus so the requested no-roof-rack loadout is deterministic.
    local roofRack = vehicle:getPartById("ATA2InteractiveTrunkRoofRack")
    if roofRack and roofRack:getInventoryItem() then
        if not ATA2Commands or not ATA2Commands.uninstallTuning then
            error("Autotsar tuning API is unavailable for roof-rack removal")
        end
        local tuningData = roofRack:getModData().tuning2
        local modelName = tuningData and tuningData.model or "Fench"
        ATA2Commands.uninstallTuning(vehicle, roofRack, modelName, nil)
        if roofRack:getInventoryItem() then
            error("Could not remove the randomly spawned Army Bus roof rack")
        end
    end
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

local function isLegacySpawnedBook(item)
    local fullType = item:getFullType()
    if LEGACY_PACKED_BOOKS[fullType] then
        return true
    end

    local script = ScriptManager.instance:FindItem(fullType)
    local skill = script and script:getSkillTrained() or nil
    local firstLevel = script and tonumber(script:getLevelSkillTrained()) or 0

    -- This matches the exact class of loose XP-multiplier books that earlier
    -- bus versions spawned, without touching magazines or ordinary literature.
    return skill and skill ~= ""
        and (firstLevel == 1 or firstLevel == 3 or firstLevel == 5
            or firstLevel == 7 or firstLevel == 9)
end

local function removeLegacyBooksAndCharger(container)
    local removedBooks = 0
    local removedChargers = 0
    local items = container:getItems()

    for index = items:size() - 1, 0, -1 do
        local item = items:get(index)
        if item:getFullType() == "Base.CarBatteryCharger" then
            container:Remove(item)
            removedChargers = removedChargers + 1
        elseif isLegacySpawnedBook(item) then
            container:Remove(item)
            removedBooks = removedBooks + 1
        end
    end

    log("Removed " .. tostring(removedBooks) .. " legacy skill-book item(s) and "
        .. tostring(removedChargers) .. " car battery charger(s) from the existing Army Bus.")
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
    configureBody(vehicle)

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

    for _, fullType in ipairs(OPTIONAL_ITEMS) do
        if ScriptManager.instance:FindItem(fullType) then
            addFreshItem(rearStorage, fullType)
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


    if previousVersion < 7 then
        removeLegacyBooksAndCharger(rearStorage)
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
