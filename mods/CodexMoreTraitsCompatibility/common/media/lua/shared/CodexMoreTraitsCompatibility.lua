-- Build 42 compatibility patch for More Traits and Traits Purchase System.
-- Workshop files are intentionally left untouched so Steam updates cannot erase this fix.

local PROWESS_TRAIT_NAMES = {
    "problade",
    "problunt",
    "progun",
    "prospear",
}

local PACKER_BAG_TYPE = "MoreTraits.Bag_PackerBag"
local PACKER_BAG_CAPACITY = 150
local PACKER_RAW_CAPACITY_KEY = "CodexMoreTraitsPackerCapacity"
local packerCapacityOverrideInstalled = false

local TRAIT_ORGANIZED
local TRAIT_DISORGANIZED
local TAG_HEAVY_ITEM

local function isPackerBag(item)
    return item and item:getFullType() == PACKER_BAG_TYPE
end

local function getStoredPackerCapacity(item)
    if not isPackerBag(item) then return nil end

    local modData = item:getModData()
    local storedCapacity = tonumber(modData[PACKER_RAW_CAPACITY_KEY])
    local upgradedCapacity = tonumber(modData.LComputedCapacity)

    storedCapacity = math.max(
        PACKER_BAG_CAPACITY,
        storedCapacity or 0,
        upgradedCapacity or 0
    )
    modData[PACKER_RAW_CAPACITY_KEY] = storedCapacity
    return storedCapacity
end

local function rememberPackerCapacity(item, requestedCapacity)
    if not isPackerBag(item) then return end

    local modData = item:getModData()
    modData[PACKER_RAW_CAPACITY_KEY] = math.max(
        PACKER_BAG_CAPACITY,
        tonumber(modData[PACKER_RAW_CAPACITY_KEY]) or 0,
        tonumber(requestedCapacity) or 0
    )
end

local function getPackerContainerCapacity(container)
    if not container then return nil end
    return getStoredPackerCapacity(container:getContainingItem())
end

local function computeEffectiveCapacity(rawCapacity, character, parent, containerType)
    if character
        and not instanceof(parent, "IsoGameCharacter")
        and not instanceof(parent, "IsoDeadBody")
        and containerType ~= "floor"
    then
        if TRAIT_ORGANIZED and character:hasTrait(TRAIT_ORGANIZED) then
            return math.max(math.floor(rawCapacity * 1.3), rawCapacity + 1)
        elseif TRAIT_DISORGANIZED and character:hasTrait(TRAIT_DISORGANIZED) then
            return math.max(math.floor(rawCapacity * 0.7), 1)
        end
    end

    return rawCapacity
end


local function floatingPointCorrection(value)
    return math.floor(value * 100 + 0.5) / 100
end

local function packerHasRoomFor(container, character, weightOrItem, floorWeight)
    local rawCapacity = getPackerContainerCapacity(container)
    if not rawCapacity then return nil end

    local item
    local addedWeight
    if type(weightOrItem) == "number" then
        addedWeight = weightOrItem
        if floorWeight == nil then floorWeight = addedWeight end
    else
        item = weightOrItem
        if not item then return nil end
        addedWeight = item:getUnequippedWeight()
        floorWeight = addedWeight
    end

    if item then
        if TAG_HEAVY_ITEM
            and character
            and character:getVehicle()
            and item:hasTag(TAG_HEAVY_ITEM)
            and instanceof(container:getParent(), "IsoGameCharacter")
        then
            return false
        end

        if not container:isItemAllowed(item) then
            return false
        end

        local containingItem = container:getContainingItem()
        local equipParent = containingItem and containingItem:getEquipParent()
        local equipInventory = equipParent and equipParent:getInventory()
        if equipInventory and not equipInventory:contains(item) then
            if not character then return false end
            if floatingPointCorrection(equipInventory:getCapacityWeight()) + addedWeight
                > equipInventory:getEffectiveCapacity(character)
            then
                return false
            end
        end
    end

    local containingItem = container:getContainingItem()
    if containingItem then
        local maxItemSize = containingItem:getMaxItemSize()
        if maxItemSize > 0 and addedWeight > maxItemSize then
            return false
        end
    end

    if character and not container:isInCharacterInventory(character) then
        local worldItem = container:getWorldItem()
        local square = worldItem and worldItem:getSquare()
        if square and square:getTotalWeightOfItemsOnFloor() + floorWeight > 50 then
            return false
        end
    end

    local parentContainer = containingItem and containingItem:getContainer()
    if parentContainer and parentContainer:getVehiclePart() then
        if floatingPointCorrection(parentContainer:getCapacityWeight() + addedWeight)
            > parentContainer:getEffectiveCapacity(character)
        then
            return false
        end
    end

    local effectiveCapacity = computeEffectiveCapacity(
        rawCapacity,
        character,
        container:getParent(),
        container:getType()
    )
    return floatingPointCorrection(container:getCapacityWeight()) + addedWeight <= effectiveCapacity
end

local function setPackerScriptCapacity()
    local scriptItem = ScriptManager.instance:getItem(PACKER_BAG_TYPE)
    if not scriptItem then
        print("[CodexMoreTraitsCompatibility] Packer Bag script was not available")
        return
    end

    scriptItem:DoParam("Capacity = " .. tostring(PACKER_BAG_CAPACITY))
end

local function installPackerCapacityOverride()
    if packerCapacityOverrideInstalled then return end

    TRAIT_ORGANIZED = CharacterTrait and CharacterTrait.ORGANIZED
    TRAIT_DISORGANIZED = CharacterTrait and CharacterTrait.DISORGANIZED
    TAG_HEAVY_ITEM = ItemTag and ItemTag.HEAVY_ITEM

    if not ItemContainer or not InventoryContainer or not __classmetatables then
        error("container classes are not available")
    end

    local itemContainerMeta = __classmetatables[ItemContainer.class]
    local inventoryContainerMeta = __classmetatables[InventoryContainer.class]
    if not itemContainerMeta or not itemContainerMeta.__index
        or not inventoryContainerMeta or not inventoryContainerMeta.__index
    then
        error("container metatables are not available")
    end

    local itemIndex = itemContainerMeta.__index
    local inventoryIndex = inventoryContainerMeta.__index
    local originalItemGetCapacity = itemIndex.getCapacity
    local originalItemSetCapacity = itemIndex.setCapacity
    local originalItemGetEffectiveCapacity = itemIndex.getEffectiveCapacity
    local originalItemHasRoomFor = itemIndex.hasRoomFor
    local originalInventoryGetCapacity = inventoryIndex.getCapacity
    local originalInventorySetCapacity = inventoryIndex.setCapacity
    local originalInventoryGetEffectiveCapacity = inventoryIndex.getEffectiveCapacity

    itemIndex.getCapacity = function(self)
        local ok, capacity = pcall(getPackerContainerCapacity, self)
        if ok and capacity then return capacity end
        return originalItemGetCapacity(self)
    end

    itemIndex.setCapacity = function(self, capacity)
        local ok, containingItem = pcall(function() return self:getContainingItem() end)
        if ok and containingItem then
            pcall(rememberPackerCapacity, containingItem, capacity)
        end
        return originalItemSetCapacity(self, capacity)
    end

    itemIndex.getEffectiveCapacity = function(self, character)
        local ok, capacity = pcall(function()
            local rawCapacity = getPackerContainerCapacity(self)
            if not rawCapacity then return nil end
            return computeEffectiveCapacity(rawCapacity, character, self:getParent(), self:getType())
        end)
        if ok and capacity then return capacity end
        return originalItemGetEffectiveCapacity(self, character)
    end

    itemIndex.hasRoomFor = function(self, character, weightOrItem, floorWeight)
        local ok, result = pcall(packerHasRoomFor, self, character, weightOrItem, floorWeight)
        if ok and result ~= nil then return result end
        if floorWeight ~= nil then
            return originalItemHasRoomFor(self, character, weightOrItem, floorWeight)
        end
        return originalItemHasRoomFor(self, character, weightOrItem)
    end

    inventoryIndex.getCapacity = function(self)
        local ok, capacity = pcall(getStoredPackerCapacity, self)
        if ok and capacity then return capacity end
        return originalInventoryGetCapacity(self)
    end

    inventoryIndex.setCapacity = function(self, capacity)
        pcall(rememberPackerCapacity, self, capacity)
        return originalInventorySetCapacity(self, capacity)
    end

    inventoryIndex.getEffectiveCapacity = function(self, character)
        local ok, capacity = pcall(function()
            if not isPackerBag(self) then return nil end
            local container = self:getItemContainer()
            return container and container:getEffectiveCapacity(character) or nil
        end)
        if ok and capacity then return capacity end
        return originalInventoryGetEffectiveCapacity(self, character)
    end

    packerCapacityOverrideInstalled = true
    print("[CodexMoreTraitsCompatibility] Packer Bag effective capacity set to 150")
end

local function tryInstallPackerCapacityOverride()
    local ok, err = pcall(installPackerCapacityOverride)
    if not ok then
        print("[CodexMoreTraitsCompatibility] Could not install Packer Bag capacity override: " .. tostring(err))
    end
end

local function removeProwessMutualExclusions()
    if not ToadTraitsRegistries then
        print("[CodexMoreTraitsCompatibility] More Traits registry was not available")
        return
    end

    for _, sourceName in ipairs(PROWESS_TRAIT_NAMES) do
        local sourceType = ToadTraitsRegistries[sourceName]
        local sourceDefinition = sourceType and CharacterTraitDefinition.getCharacterTraitDefinition(sourceType)

        if sourceDefinition then
            local exclusions = sourceDefinition:getMutuallyExclusiveTraits()

            for _, targetName in ipairs(PROWESS_TRAIT_NAMES) do
                if targetName ~= sourceName then
                    local targetType = ToadTraitsRegistries[targetName]
                    if targetType and exclusions:contains(targetType) then
                        exclusions:remove(targetType)
                    end
                end
            end
        end
    end
end

local function makeAxPertPickable()
    local previousDefinition = CharacterTraitDefinition.getCharacterTraitDefinition(CharacterTrait.AXEMAN)
    local pickableDefinition = CharacterTraitDefinition.addCharacterTraitDefinition(
        CharacterTrait.AXEMAN,
        "UI_trait_axeman",
        2,
        "UI_trait_axemandesc",
        false,
        false
    )

    if previousDefinition and previousDefinition:getTexture() then
        pickableDefinition:setTexture(previousDefinition:getTexture())
    end
end

local function applyCompatibilityPatch()
    removeProwessMutualExclusions()
    makeAxPertPickable()
    setPackerScriptCapacity()
    print("[CodexMoreTraitsCompatibility] Prowess traits unlocked; Ax-pert is pickable for 2 points")
end

Events.OnGameBoot.Add(applyCompatibilityPatch)
Events.OnGameStart.Add(tryInstallPackerCapacityOverride)

if Events.OnServerStarted and Events.OnServerStarted.Add then
    Events.OnServerStarted.Add(tryInstallPackerCapacityOverride)
end
