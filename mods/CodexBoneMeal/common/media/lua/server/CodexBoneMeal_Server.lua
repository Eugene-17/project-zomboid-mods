require "Farming/SFarmingSystem"
require "Farming/farming_vegetableconf"
require "CodexBoneMeal_Shared"

local M = CodexBoneMeal

local function notify(playerObj, message, ok)
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "result", { message = message, ok = ok })
    else
        playerObj:setHaloNote(message, 255, ok and 255 or 80, 80, 300)
    end
end

local function consumeBoneMeal(item)
    local container = item and item:getContainer()
    if not container then return false end

    if instanceof(item, "DrainableComboItem") then
        local remaining = item:getCurrentUsesFloat() - item:getUseDelta()
        if remaining > 0.0001 then
            item:setUsedDelta(remaining)
            if isServer() then sendItemStats(item) end
            return true
        end

        if isServer() then sendRemoveItemFromContainer(container, item) end
        container:Remove(item)
        local emptySack = container:AddItem("Base.EmptySandbag")
        if isServer() and emptySack then
            sendAddItemToContainer(container, emptySack)
        end
        return emptySack ~= nil
    end

    -- Compatibility for a one-use bone-meal item saved before it became a sack.
    if isServer() then sendRemoveItemFromContainer(container, item) end
    container:Remove(item)
    return true
end

local function growWithoutWaterRequirement(plant, props)
    local originalWater = plant.waterLvl
    local requiredWater = tonumber(plant.waterNeeded)
        or tonumber(props.waterNeeded)
        or tonumber(props.waterLvl)
        or 0
    local maximumWater = tonumber(plant.waterNeededMax)
        or tonumber(props.waterLvlMax)

    -- Vanilla growPlant validates water internally. Give it a valid value for
    -- this single call, then put the crop's actual water back unchanged.
    local growthWater = math.max(0, requiredWater)
    if maximumWater then growthWater = math.min(growthWater, maximumWater) end
    plant.waterLvl = growthWater
    local ok, result = pcall(
        SFarmingSystem.instance.growPlant,
        SFarmingSystem.instance,
        plant,
        nil,
        true
    )
    plant.waterLvl = originalWater
    return ok, result
end

function M.applyBoneMeal(playerObj, args)
    if not playerObj or not args then return end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    if not x or not y or not z then
        notify(playerObj, "That crop could not be found.", false)
        return
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)

    local dx = playerObj:getX() - (x + 0.5)
    local dy = playerObj:getY() - (y + 0.5)
    if z ~= math.floor(playerObj:getZ()) or (dx * dx + dy * dy) > 9 then
        notify(playerObj, "Move closer to the crop.", false)
        return
    end

    local item = playerObj:getInventory():getFirstTypeRecurse(M.ITEM_FULL_TYPE)
    if not item then
        notify(playerObj, "You no longer have any bone meal.", false)
        return
    end

    local plant = SFarmingSystem.instance:getLuaObjectAt(x, y, z)
    local failure = M.getPlantFailure(plant)
    if failure then
        notify(playerObj, failure, false)
        return
    end

    local props = farming_vegetableconf.props[plant.typeOfSeed]
    if not props then
        notify(playerObj, "This crop type does not support normal growth stages.", false)
        return
    end
    if props.harvestLevel and plant.nbOfGrow > props.harvestLevel then
        notify(playerObj, "This crop is already at its final useful growth stage.", false)
        return
    end

    local before = tonumber(plant.nbOfGrow) or -1
    local grew, growError = growWithoutWaterRequirement(plant, props)
    if not grew then
        print("[CodexBoneMeal] crop growth failed: " .. tostring(growError))
        notify(playerObj, "The crop could not advance, so the bone meal was not consumed.", false)
        return
    end
    local after = tonumber(plant.nbOfGrow) or before
    if after ~= before + 1 or not plant:isAlive() then
        notify(playerObj, "The crop could not advance, so the bone meal was not consumed.", false)
        return
    end

    if not consumeBoneMeal(item) then
        notify(playerObj, "The bone meal could not be consumed; crop growth was not recorded.", false)
        return
    end

    local sprite = farming_vegetableconf.getSpriteName(plant)
    if sprite then plant:setSpriteName(sprite) end
    plant:saveData()

    if plant.hasVegetable then
        notify(playerObj, "The crop advanced one stage and is now ready to harvest.", true)
    else
        notify(playerObj, "The crop advanced by one growth stage.", true)
    end
end

local function onClientCommand(module, command, playerObj, args)
    if module == M.MODULE and command == "apply" then
        M.applyBoneMeal(playerObj, args or {})
    end
end

Events.OnClientCommand.Add(onClientCommand)
