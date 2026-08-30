require "CodexAnimalSpawnItems_Shared"

local M = CodexAnimalSpawnItems

local OFFSETS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
    { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 },
    { 2, 1 }, { 2, -1 }, { -2, 1 }, { -2, -1 },
    { 1, 2 }, { -1, 2 }, { 1, -2 }, { -1, -2 },
    { 3, 0 }, { -3, 0 }, { 0, 3 }, { 0, -3 },
}

local function notify(playerObj, message, ok)
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "result", { message = message, ok = ok })
    else
        playerObj:setHaloNote(message, ok and 255 or 255, ok and 255 or 80, 80, 300)
    end
end

local function getOpenSquare(playerObj)
    local cell = getCell()
    local baseX = math.floor(playerObj:getX())
    local baseY = math.floor(playerObj:getY())
    local z = math.floor(playerObj:getZ())

    local start = ZombRand(#OFFSETS)
    for i = 1, #OFFSETS do
        local offset = OFFSETS[((start + i - 1) % #OFFSETS) + 1]
        local square = cell:getGridSquare(baseX + offset[1], baseY + offset[2], z)
        if square and square:isSolidFloor() and not square:isWaterSquare()
            and square:isFree(true) then
            return square
        end
    end

    return nil
end

local function spawnVanillaAnimal(square, definition, animalType, breedName)
    local animalDefinition = AnimalDefinitions.getDef(animalType)
    if not animalDefinition then return nil end

    local breed = animalDefinition:getBreedByName(breedName)
    if not breed then return nil end

    local animal = addAnimal(
        getCell(), square:getX(), square:getY(), square:getZ(),
        animalType, breed, false
    )
    if not animal then return nil end

    animal:addToWorld()
    animal:randomizeAge()
    return animal
end

local function spawnCat(square, animalType, breedName)
    if not CatsMod or not CatsMod.spawnCat then return nil end

    local animal = CatsMod.spawnCat(
        square:getX(), square:getY(), square:getZ(),
        animalType, breedName, true
    )
    if animal and CatsMod.transmit then
        CatsMod.transmit(animal)
    end
    return animal
end

local function consumeCarrier(carrier)
    local container = carrier:getContainer()
    if not container then return false end

    container:Remove(carrier)
    if isServer() then
        sendRemoveItemFromContainer(container, carrier)
    end
    return true
end

function M.release(playerObj, args)
    if not playerObj or not args then return end

    local definition = M.SPECIES[args.species]
    if not definition then
        notify(playerObj, "That carrier is invalid.", false)
        return
    end

    local carrier = playerObj:getInventory():getFirstTypeRecurse(definition.item)
    if not carrier then
        notify(playerObj, "You no longer have that carrier.", false)
        return
    end

    local square = getOpenSquare(playerObj)
    if not square then
        notify(playerObj, "No clear ground nearby to release the animal.", false)
        return
    end

    local animalType = M.randomChoice(definition.types)
    local breedName = M.randomChoice(definition.breeds)
    local animal
    if definition.catsMod then
        animal = spawnCat(square, animalType, breedName)
    else
        animal = spawnVanillaAnimal(square, definition, animalType, breedName)
    end

    if not animal then
        notify(playerObj, "The animal could not be released; the carrier was not consumed.", false)
        return
    end

    consumeCarrier(carrier)
    notify(playerObj, "Released a random " .. definition.label .. ".", true)
end

local function onClientCommand(module, command, playerObj, args)
    if module == M.MODULE and command == "release" then
        M.release(playerObj, args or {})
    end
end

Events.OnClientCommand.Add(onClientCommand)
