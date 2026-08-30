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

local function getCooldowns()
    local data = ModData.getOrCreate(M.DATA_KEY)
    data.cooldowns = data.cooldowns or {}
    return data.cooldowns
end

local function consumeBoneMeal(item)
    local container = item and item:getContainer()
    if not container then return false end
    container:Remove(item)
    if isServer() then
        sendRemoveItemFromContainer(container, item)
    end
    return true
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

    local cooldowns = getCooldowns()
    local key = M.squareKey(x, y, z)
    local now = getGameTime():getWorldAgeHours()
    local record = cooldowns[key]
    if record and record.seedType == plant.typeOfSeed and now < (tonumber(record.untilHour) or 0) then
        local hours = math.max(1, math.ceil(record.untilHour - now))
        notify(playerObj, "This crop needs " .. tostring(hours) .. " more in-game hour(s) before another dose.", false)
        return
    end

    local before = tonumber(plant.nbOfGrow) or -1
    SFarmingSystem.instance:growPlant(plant, nil, true)
    local after = tonumber(plant.nbOfGrow) or before
    if after ~= before + 1 or not plant:isAlive() then
        notify(playerObj, "The crop could not advance, so the bone meal was not consumed.", false)
        return
    end

    if not consumeBoneMeal(item) then
        notify(playerObj, "The bone meal could not be consumed; crop growth was not recorded.", false)
        return
    end

    cooldowns[key] = {
        seedType = plant.typeOfSeed,
        untilHour = now + M.COOLDOWN_HOURS,
    }
    plant:saveData()
    if isServer() then ModData.transmit(M.DATA_KEY) end

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
