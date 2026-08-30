CodexAnimalSpawnItems = CodexAnimalSpawnItems or {}

local M = CodexAnimalSpawnItems

M.MODULE = "CodexAnimalSpawnItems"

-- Adult entries are duplicated so young animals remain a fun surprise rather
-- than the usual result: about 20% young and 80% adult for every family.
M.SPECIES = {
    cat = {
        item = "CodexAnimalSpawnItems.CatCarrier",
        label = "cat",
        catsMod = true,
        types = { "cmkitten", "cmtom", "cmqueen", "cmtom", "cmqueen" },
        breeds = { "shorthair", "smokey", "orange", "siamese", "garfield", "tabby" },
    },
    chicken = {
        item = "CodexAnimalSpawnItems.ChickenCarrier",
        label = "chicken",
        types = { "chick", "hen", "cockerel", "hen", "cockerel" },
        breeds = { "leghorn", "rhodeisland" },
    },
    cow = {
        item = "CodexAnimalSpawnItems.CowCarrier",
        label = "cow",
        types = { "cowcalf", "cow", "bull", "cow", "bull" },
        breeds = { "angus", "holstein", "simmental" },
    },
    deer = {
        item = "CodexAnimalSpawnItems.DeerCarrier",
        label = "deer",
        types = { "fawn", "doe", "buck", "doe", "buck" },
        breeds = { "whitetailed" },
    },
    mouse = {
        item = "CodexAnimalSpawnItems.MouseCarrier",
        label = "mouse",
        types = { "mousepups", "mousefemale", "mouse", "mousefemale", "mouse" },
        breeds = { "deer", "golden", "white" },
    },
    pig = {
        item = "CodexAnimalSpawnItems.PigCarrier",
        label = "pig",
        types = { "piglet", "sow", "boar", "sow", "boar" },
        breeds = { "landrace", "largeblack" },
    },
    rabbit = {
        item = "CodexAnimalSpawnItems.RabbitCarrier",
        label = "rabbit",
        types = { "rabkitten", "rabdoe", "rabbuck", "rabdoe", "rabbuck" },
        breeds = { "appalachian", "cottontail", "swamp" },
    },
    raccoon = {
        item = "CodexAnimalSpawnItems.RaccoonCarrier",
        label = "raccoon",
        types = { "raccoonkit", "raccoonsow", "raccoonboar", "raccoonsow", "raccoonboar" },
        breeds = { "grey" },
    },
    rat = {
        item = "CodexAnimalSpawnItems.RatCarrier",
        label = "rat",
        types = { "ratbaby", "ratfemale", "rat", "ratfemale", "rat" },
        breeds = { "grey", "white" },
    },
    sheep = {
        item = "CodexAnimalSpawnItems.SheepCarrier",
        label = "sheep",
        types = { "lamb", "ewe", "ram", "ewe", "ram" },
        breeds = { "friesian", "rambouillet", "suffolk" },
    },
    turkey = {
        item = "CodexAnimalSpawnItems.TurkeyCarrier",
        label = "turkey",
        types = { "turkeypoult", "turkeyhen", "gobblers", "turkeyhen", "gobblers" },
        breeds = { "meleagris" },
    },
}

M.ITEM_TO_SPECIES = {}
for species, definition in pairs(M.SPECIES) do
    M.ITEM_TO_SPECIES[definition.item] = species
end

function M.randomChoice(values)
    return values[ZombRand(#values) + 1]
end

-- Build 42 represents a picked-up living animal as Base.Animal, an
-- AnimalInventoryItem that retains the original IsoAnimal and all of its data.
-- Vanilla rejects that item from every container except the floor.  These
-- narrowly scoped wrappers allow it in portable container items while keeping
-- the normal capacity, maximum-item-size, and outer-container checks.

local liveAnimalBagOverrideInstalled = false

function M.isLiveAnimalItem(item)
    return item and instanceof(item, "AnimalInventoryItem") and item:getAnimal() ~= nil
end

function M.isPortableBagContainer(container)
    if not container then return false end
    local containingItem = container:getContainingItem()
    return containingItem and instanceof(containingItem, "InventoryContainer")
end

local function isCharacterInventory(container)
    return container
        and container:getContainingItem() == nil
        and instanceof(container:getParent(), "IsoGameCharacter")
end

function M.isAllowedLiveAnimalDestination(container, item)
    return M.isLiveAnimalItem(item)
        and (M.isPortableBagContainer(container) or isCharacterInventory(container))
end

local function floatingPointCorrection(value)
    return math.floor(value * 100 + 0.5) / 100
end

local function liveAnimalHasRoomFor(container, character, item)
    if not M.isAllowedLiveAnimalDestination(container, item) then return nil end

    local addedWeight = item:getUnequippedWeight()
    local containingItem = container:getContainingItem()

    if containingItem then
        local maxItemSize = containingItem:getMaxItemSize()
        if maxItemSize > 0 and addedWeight > maxItemSize then
            return false
        end

        local equipParent = containingItem:getEquipParent()
        local equipInventory = equipParent and equipParent:getInventory()
        if equipInventory and not equipInventory:contains(item) then
            if not character then return false end
            if floatingPointCorrection(equipInventory:getCapacityWeight()) + addedWeight
                > equipInventory:getEffectiveCapacity(character)
            then
                return false
            end
        end

        local parentContainer = containingItem:getContainer()
        if parentContainer and parentContainer:getVehiclePart() then
            if floatingPointCorrection(parentContainer:getCapacityWeight() + addedWeight)
                > parentContainer:getEffectiveCapacity(character)
            then
                return false
            end
        end
    end

    if character and not container:isInCharacterInventory(character) then
        local worldItem = container:getWorldItem()
        local square = worldItem and worldItem:getSquare()
        if square and square:getTotalWeightOfItemsOnFloor() + addedWeight > 50 then
            return false
        end
    end

    return floatingPointCorrection(container:getCapacityWeight()) + addedWeight
        <= container:getEffectiveCapacity(character)
end


local function installLiveAnimalBagOverride()
    if liveAnimalBagOverrideInstalled then return end
    if not ItemContainer or not __classmetatables then
        error("ItemContainer class is not available")
    end

    local meta = __classmetatables[ItemContainer.class]
    if not meta or not meta.__index then
        error("ItemContainer metatable is not available")
    end

    local index = meta.__index
    local originalIsItemAllowed = index.isItemAllowed
    local originalHasRoomFor = index.hasRoomFor

    index.isItemAllowed = function(self, item)
        local ok, allowed = pcall(M.isAllowedLiveAnimalDestination, self, item)
        if ok and allowed then return true end
        return originalIsItemAllowed(self, item)
    end

    index.hasRoomFor = function(self, character, weightOrItem, floorWeight)
        if floorWeight == nil and type(weightOrItem) ~= "number" then
            local ok, hasRoom = pcall(liveAnimalHasRoomFor, self, character, weightOrItem)
            if ok and hasRoom ~= nil then return hasRoom end
        end

        if floorWeight ~= nil then
            return originalHasRoomFor(self, character, weightOrItem, floorWeight)
        end
        return originalHasRoomFor(self, character, weightOrItem)
    end

    liveAnimalBagOverrideInstalled = true
    print("[CodexAnimalSpawnItems] Living animals may now be carried inside bags")
end

local function tryInstallLiveAnimalBagOverride()
    local ok, err = pcall(installLiveAnimalBagOverride)
    if not ok then
        print("[CodexAnimalSpawnItems] Could not enable live-animal bag storage: " .. tostring(err))
    end
end

Events.OnGameStart.Add(tryInstallLiveAnimalBagOverride)

if Events.OnServerStarted and Events.OnServerStarted.Add then
    Events.OnServerStarted.Add(tryInstallLiveAnimalBagOverride)
end

if ItemContainer and __classmetatables and __classmetatables[ItemContainer.class] then
    tryInstallLiveAnimalBagOverride()
end
