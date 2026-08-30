require "EugenesZombieCure_Shared"
require "BanditCustom"
require "BanditServerSpawner"

local M = EugenesZombieCure

local function notify(playerObj, message, ok)
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "result", { message = message, ok = ok })
    else
        playerObj:setHaloNote(message, 255, ok and 255 or 80, ok and 255 or 80, 300)
    end
end

local function findZombieByOnlineId(onlineId)
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        if zombie:getOnlineID() == onlineId then return zombie end
    end
    return nil
end

local function consumeTreatment(playerObj, itemId, expectedType)
    local item = playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not M.hasTreatmentItem(playerObj, item) or item:getFullType() ~= expectedType then return false end
    local container = item:getContainer()
    if isServer() then sendRemoveItemFromContainer(container, item) end
    container:Remove(item)
    return true
end

local function purgePlayerInfection(playerObj)
    local bodyDamage = playerObj:getBodyDamage()
    bodyDamage:setInfected(false)
    bodyDamage:setInfectionMortalityDuration(-1)
    bodyDamage:setInfectionTime(-1)
    bodyDamage:setIsFakeInfected(false)

    local bodyParts = bodyDamage:getBodyParts()
    for index = 0, bodyParts:size() - 1 do
        local bodyPart = bodyParts:get(index)
        if bodyPart:isInfectedWound() then
            bodyPart:SetInfected(false)
            bodyPart:setInfectedWound(false)
            bodyPart:setWoundInfectionLevel(0)
        end
    end

    local stats = playerObj:getStats()
    stats:set(CharacterStat.ZOMBIE_FEVER, 0)
    stats:set(CharacterStat.ZOMBIE_INFECTION, 0)
end

local function curePlayer(playerObj, args)
    local itemId = tonumber(args.itemId)
    if not itemId or not consumeTreatment(playerObj, itemId, M.ITEM_FULL_TYPE) then
        notify(playerObj, "The cure is no longer in your inventory.", false)
        return
    end
    purgePlayerInfection(playerObj)
    notify(playerObj, "The Knox infection has been purged. Existing wounds remain.", true)
end

local function cureZombie(playerObj, args, directTarget)
    local zombie = directTarget or findZombieByOnlineId(tonumber(args.targetId))
    if not M.canTreatZombie(playerObj, zombie) then
        notify(playerObj, "The zombie must still be alive, prone, and within reach.", false)
        return
    end

    local itemId = tonumber(args.itemId)
    if not itemId or not consumeTreatment(playerObj, itemId, M.ITEM_FULL_TYPE) then
        notify(playerObj, "The cure is no longer in your inventory.", false)
        return
    end

    local skinName = M.chooseNormalSkinName(zombie)
    M.applyZombieCureState(zombie, skinName)
    if isServer() then
        sendServerCommand(M.MODULE, "zombieCured", {
            targetId = zombie:getOnlineID(),
            skinName = skinName,
        })
    end
    notify(playerObj, "The zombie now looks human and has been pacified.", true)
end

local function chooseFriendlyBanditProfile(zombie)
    local matching = {}
    local fallback = {}
    for bid, profile in pairs(BanditCustom.GetAll()) do
        local general = profile and profile.general
        local clan = general and BanditCustom.ClanGet(general.cid)
        if clan and clan.spawn and clan.spawn.friendly then
            fallback[#fallback + 1] = bid
            if (general.female == true) == zombie:isFemale() then
                matching[#matching + 1] = bid
            end
        end
    end
    local choices = #matching > 0 and matching or fallback
    if #choices == 0 then return nil end
    return choices[ZombRand(#choices) + 1]
end

local function findSpawnedBandit(existingZombies, expectedBid, x, y, z)
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        if not existingZombies[zombie] then
            local id = zombie:getPersistentOutfitID()
            local cluster = GetBanditClusterData(id)
            local brain = cluster and cluster[id]
            if brain
                and brain.bid == expectedBid
                and math.floor(zombie:getZ()) == math.floor(z)
                and math.abs(zombie:getX() - x) <= 1
                and math.abs(zombie:getY() - y) <= 1 then
                return zombie
            end
        end
    end
    return nil
end

local function restoreZombie(playerObj, args, directTarget)
    local zombie = directTarget or findZombieByOnlineId(tonumber(args.targetId))
    if not M.canRestoreZombie(playerObj, zombie) then
        notify(playerObj, "Only a living zombie pacified by the Knox cure can be restored.", false)
        return
    end

    local bid = chooseFriendlyBanditProfile(zombie)
    if not bid or not BanditServer or not BanditServer.Spawner or not BanditServer.Spawner.Individual then
        notify(playerObj, "Bandits could not provide a compatible companion profile.", false)
        return
    end

    local itemId = tonumber(args.itemId)
    local serum = itemId and playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not M.hasTreatmentItem(playerObj, serum) or serum:getFullType() ~= M.RESTORATION_ITEM_FULL_TYPE then
        notify(playerObj, "The restoration serum is no longer in your inventory.", false)
        return
    end

    local existingZombies = {}
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do existingZombies[zombies:get(index)] = true end

    local spawnX = zombie:getX()
    local spawnY = zombie:getY()
    local spawnZ = zombie:getZ()
    BanditServer.Spawner.Individual(playerObj, {
        bid = bid,
        x = spawnX,
        y = spawnY,
        z = spawnZ,
        program = "Companion",
        permanent = true,
        loyal = true,
        hostile = false,
        hostileP = false,
    })

    local companion = findSpawnedBandit(existingZombies, bid, spawnX, spawnY, spawnZ)
    if not companion then
        notify(playerObj, "The restoration failed before the serum was consumed.", false)
        return
    end

    if not consumeTreatment(playerObj, itemId, M.RESTORATION_ITEM_FULL_TYPE) then
        local companionId = companion:getPersistentOutfitID()
        local cluster = GetBanditClusterData(companionId)
        if cluster then
            cluster[companionId] = nil
            TransmitBanditCluster(companionId)
        end
        companion:removeFromWorld()
        companion:removeFromSquare()
        companion:setSquare(nil)
        notify(playerObj, "The restoration serum is no longer in your inventory.", false)
        return
    end

    local data = zombie:getModData()
    data.EugenesZombieCurePacified = nil
    data.EugenesZombieCureSkinName = nil
    zombie:removeFromWorld()
    zombie:removeFromSquare()
    zombie:setSquare(nil)
    notify(playerObj, "The restored survivor has joined you as a permanent companion.", true)
end

function M.handleUseCure(playerObj, args, directTarget)
    if not playerObj or not args then return end
    if args.operation == "self" then
        curePlayer(playerObj, args)
    elseif args.operation == "zombie" then
        cureZombie(playerObj, args, directTarget)
    elseif args.operation == "restore" then
        restoreZombie(playerObj, args, directTarget)
    end
end

local function onClientCommand(module, command, playerObj, args)
    if module == M.MODULE and command == "useCure" then
        M.handleUseCure(playerObj, args or {})
    end
end

Events.OnClientCommand.Add(onClientCommand)
