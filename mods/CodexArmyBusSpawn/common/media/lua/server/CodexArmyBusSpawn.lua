local MOD_TAG = "[CodexArmyBusSpawn] "
local STATE_KEY = "CodexArmyBusSpawn_v1"
local CONFIG_VERSION = 6
local VEHICLE_SCRIPT = "Base.ATAArmyBus"

local SPAWN_X = 13705
local SPAWN_Y = 1793
local SPAWN_Z = 0
local CHECK_INTERVAL = 60

local REQUESTED_ITEMS = {
    "Base.Bag_Satchel_Military",
    "Base.Glasses_Normal",
    "Base.Trousers_CamoGreen",
    "MoreTraits.AntiqueJacket",
    "MoreTraits.Slugger",
    "MoreTraits.AntiqueBoots",
    "Base.Canteen",
    "Base.Hat_WinterHat",
    "Base.Scarf_White",
    "Base.Gloves_LeatherGlovesBlack",
    "Base.FlashLight_AngleHead_Army",
    "MoreTraits.Thumper",
    "Base.Belt2",
    "Base.GasmaskFilter",
    "MoreTraits.Bag_PackerBag",
    "Base.CarBatteryCharger",
}

local VERSION_2_ITEMS = {
    "Base.GasmaskFilter",
}

local VERSION_4_ITEMS = {
    "MoreTraits.Bag_PackerBag",
    "Base.CarBatteryCharger",
}

local VERSION_5_REMOVED_ITEMS = {
    "Base.Bag_ALICEpack_Army",
}

local REQUESTED_MOVEABLES = {
    { sprite = "carpentry_01_16", count = 9 },
    { sprite = "location_trailer_02_22", count = 4 },
    { sprite = "location_community_school_01_12", count = 2 },
}

local VERSION_6_MOVEABLES = {
    { sprite = "carpentry_01_16", count = 3 },
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

local function getLevelingBookTypes()
    local books = {}
    local scripts = getScriptManager():getAllItems()

    for index = 0, scripts:size() - 1 do
        local script = scripts:get(index)
        local skill = script and script:getSkillTrained() or nil
        local firstLevel = script and tonumber(script:getLevelSkillTrained()) or 0

        -- Proper XP-multiplier books use the five vanilla level bands. Recipe
        -- magazines, trait books, and boxed book sets do not have SkillTrained.
        if skill and skill ~= ""
                and (firstLevel == 1 or firstLevel == 3 or firstLevel == 5
                    or firstLevel == 7 or firstLevel == 9) then
            table.insert(books, script:getFullName())
        end
    end

    table.sort(books)
    return books
end

local function getPackedLevelingBookTypes()
    local packedBooks = {}
    local packedModules = {}
    local scripts = getScriptManager():getAllItems()

    for index = 0, scripts:size() - 1 do
        local script = scripts:get(index)
        if script and script:getDoubleClickRecipe() == "UnpackSetOfBooks" then
            local fullType = script:getFullName()
            table.insert(packedBooks, fullType)

            local moduleName = string.match(fullType, "^([^%.]+)%.")
            if moduleName then
                packedModules[moduleName] = true
            end
        end
    end

    table.sort(packedBooks)
    return packedBooks, packedModules
end

local function containerHasFullType(container, fullType)
    local items = container:getItems()
    for index = 0, items:size() - 1 do
        if items:get(index):getFullType() == fullType then
            return true
        end
    end
    return false
end

local function addMissingBusBooks(container)
    local added = 0
    local packedBooks, packedModules = getPackedLevelingBookTypes()
    local books = {}

    for _, fullType in ipairs(packedBooks) do
        table.insert(books, fullType)
    end

    -- Keep individual volumes only for loaded skills whose mod does not
    -- provide an unpackable set item.
    for _, fullType in ipairs(getLevelingBookTypes()) do
        local moduleName = string.match(fullType, "^([^%.]+)%.")
        if not moduleName or not packedModules[moduleName] then
            table.insert(books, fullType)
        end
    end

    table.sort(books)

    for _, fullType in ipairs(books) do
        if not containerHasFullType(container, fullType) then
            if not addFreshItem(container, fullType) then
                error("Could not create bus book item " .. fullType)
            end
            added = added + 1
        end
    end

    log("Added " .. tostring(added) .. " missing packed book sets or unpacked fallback volumes from "
        .. tostring(#books) .. " loaded base-game and mod book definitions.")
end

local function addMissingLooseLevelingBooks(container)
    local added = 0
    local books = getLevelingBookTypes()

    for _, fullType in ipairs(books) do
        if not containerHasFullType(container, fullType) then
            if not addFreshItem(container, fullType) then
                error("Could not create leveling book " .. fullType)
            end
            added = added + 1
        end
    end

    log("Added " .. tostring(added) .. " missing leveling books from "
        .. tostring(#books) .. " loaded base-game and mod book definitions.")
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

    addMissingBusBooks(rearStorage)

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


    if previousVersion < 6 then
        -- Preserve the original version-6 migration for existing buses.
        addMissingLooseLevelingBooks(rearStorage)

        for _, definition in ipairs(VERSION_6_MOVEABLES) do
            for _ = 1, definition.count do
                if not addMoveable(rearStorage, definition.sprite) then
                    error("Could not add version 6 moveable " .. definition.sprite
                        .. " to the existing Army Bus")
                end
            end
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
