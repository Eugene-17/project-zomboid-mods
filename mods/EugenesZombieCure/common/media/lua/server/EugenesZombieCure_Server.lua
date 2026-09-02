require "EugenesZombieCure_Shared"
require "BanditCustom"
require "BanditServerSpawner"
require "Bandit"
require "BanditBrain"
require "BanditUtils"

local M = EugenesZombieCure
local EPE = EugenesProneEquipment
local pendingRestorations = {}
local pendingSerums = setmetatable({}, { __mode = "k" })
local RECRUIT_RETRY_TICKS = 60
local RESTORATION_TIMEOUT_TICKS = 1800

local function notify(playerObj, message, ok)
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "result", { message = message, ok = ok })
    else
        playerObj:setHaloNote(message, 255, ok and 255 or 80, ok and 255 or 80, 300)
    end
end

local function findZombieByOnlineId(onlineId)
    if not onlineId then return nil end
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        if zombie:getOnlineID() == onlineId then return zombie end
    end
    return nil
end

local function ensureZombieInventory(zombie)
    local data = zombie:getModData()
    if data.EugenesProneEquipmentInitialized then return end
    zombie:DoZombieInventory()
    data.EugenesProneEquipmentInitialized = true
end

local function getBanditBrain(zombie)
    if not zombie then return nil end
    if BanditBrain and BanditBrain.Get then
        local brain = BanditBrain.Get(zombie)
        if brain then return brain end
    end
    local id = zombie:getPersistentOutfitID()
    local cluster = GetBanditClusterData and GetBanditClusterData(id) or nil
    return cluster and cluster[id] or zombie:getModData().brain
end

local function findCorpse(args)
    local x = tonumber(args.targetX)
    local y = tonumber(args.targetY)
    local z = tonumber(args.targetZ)
    local targetIndex = tonumber(args.targetIndex)
    if not x or not y or not z or not targetIndex then return nil end
    targetIndex = math.floor(targetIndex)
    local square = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    if not square then return nil end
    local corpses = square:getStaticMovingObjects()
    if targetIndex < 0 or targetIndex >= corpses:size() then return nil end
    local candidate = corpses:get(targetIndex)
    if M.isHumanCorpse(candidate) then return candidate end
    return nil
end

local function consumeTreatment(playerObj, itemId, expectedType)
    local item = playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not M.hasTreatmentItem(playerObj, item) or item:getFullType() ~= expectedType then
        return false
    end
    local container = item:getContainer()
    if isServer() then sendRemoveItemFromContainer(container, item) end
    container:Remove(item)
    return true
end

local function moveTreatmentToContainer(playerObj, itemId, expectedType, destination)
    local item = playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not destination or not M.hasTreatmentItem(playerObj, item)
        or item:getFullType() ~= expectedType then
        return nil
    end

    local source = item:getContainer()
    if not source then return nil end
    if isServer() then sendRemoveItemFromContainer(source, item) end
    source:Remove(item)
    destination:AddItem(item)
    if not destination:containsRecursive(item) then
        source:AddItem(item)
        if isServer() then sendAddItemToContainer(source, item) end
        return nil
    end
    if isServer() then sendAddItemToContainer(destination, item) end
    return item
end

local function purgePacifyingCures(container)
    if not container then return 0 end
    local cures = container:getAllEvalRecurse(function(item)
        return M.isCureItem(item)
    end)
    local removed = 0
    for index = cures:size() - 1, 0, -1 do
        local item = cures:get(index)
        local source = item and item:getContainer() or nil
        if source then
            if isServer() then sendRemoveItemFromContainer(source, item) end
            source:Remove(item)
            removed = removed + 1
        end
    end
    return removed
end

local function purgeZombieRecords(container)
    if not container then return 0 end
    local records = container:getAllEvalRecurse(function(item)
        return EPE.isZombieRecord(item)
    end)
    local removed = 0
    for index = records:size() - 1, 0, -1 do
        local item = records:get(index)
        local source = item and item:getContainer() or nil
        if source then
            if isServer() then sendRemoveItemFromContainer(source, item) end
            source:Remove(item)
            removed = removed + 1
        end
    end
    return removed
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
        notify(playerObj, getText("IGUI_EZC_CureMissing"), false)
        return
    end
    purgePlayerInfection(playerObj)
    notify(playerObj, getText("IGUI_EZC_PlayerCured"), true)
end

local function cureZombie(playerObj, args, directTarget)
    local zombie = directTarget or findZombieByOnlineId(tonumber(args.targetId))
    if not M.canTreatZombie(playerObj, zombie) then
        notify(playerObj, getText("IGUI_EZC_ZombieInvalid"), false)
        return
    end
    ensureZombieInventory(zombie)
    local itemId = tonumber(args.itemId)
    if not itemId or not moveTreatmentToContainer(
        playerObj, itemId, M.ITEM_FULL_TYPE, zombie:getInventory()) then
        notify(playerObj, getText("IGUI_EZC_CureMissing"), false)
        return
    end
    purgeZombieRecords(zombie:getInventory())
    local skinName = M.chooseNormalSkinName(zombie)
    M.applyZombieCureState(zombie, skinName)
    if isServer() then
        sendServerCommand(M.MODULE, "zombieCured", {
            targetId = zombie:getOnlineID(),
            skinName = skinName,
        })
    end
    notify(playerObj, getText("IGUI_EZC_ZombiePacified"), true)
end

local function reanimateCorpse(playerObj, args, directTarget)
    local corpse = directTarget or findCorpse(args)
    if not M.canReviveCorpse(playerObj, corpse) then
        notify(playerObj, getText("IGUI_EZC_CorpseInvalid"), false)
        return
    end
    local itemId = tonumber(args.itemId)
    local stimulant = itemId and playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not M.hasTreatmentItem(playerObj, stimulant)
        or stimulant:getFullType() ~= M.REANIMATION_ITEM_FULL_TYPE then
        notify(playerObj, getText("IGUI_EZC_StimulantMissing"), false)
        return
    end
    purgeZombieRecords(corpse:getContainer())
    local ok, result = pcall(function() corpse:reanimateNow() end)
    if not ok then
        print("[EugenesZombieCure] corpse reanimation failed: " .. tostring(result))
        notify(playerObj, getText("IGUI_EZC_ReanimationFailed"), false)
        return
    end
    if not consumeTreatment(playerObj, itemId, M.REANIMATION_ITEM_FULL_TYPE) then
        notify(playerObj, getText("IGUI_EZC_StimulantMissing"), false)
        return
    end
    notify(playerObj, getText("IGUI_EZC_CorpseReanimated"), true)
end

local function chooseTrueCompanionProfile(zombie)
    BanditCustom.Load()
    local matching = {}
    local fallback = {}
    for bid, profile in pairs(BanditCustom.GetAll()) do
        local general = profile and profile.general
        local cid = general and general.cid
        local clan = cid and BanditCustom.ClanGet(cid) or nil
        local spawn = clan and clan.spawn
        if spawn and spawn.friendly and spawn.companion then
            local candidate = { bid = bid, cid = cid, profile = profile }
            fallback[#fallback + 1] = candidate
            if (general.female == true) == zombie:isFemale() then
                matching[#matching + 1] = candidate
            end
        end
    end
    local choices = #matching > 0 and matching or fallback
    if #choices == 0 then return nil end
    return choices[ZombRand(#choices) + 1]
end

local function spawnThroughTrueCompanions(playerObj, choice, key, x, y, z)
    if not choice or not BanditServer or not BanditServer.Spawner
        or not BanditServer.Spawner.Clan then
        return false, "True Companions clan spawner is unavailable"
    end

    local originalGetFromClan = BanditCustom.GetFromClan
    BanditCustom.GetFromClan = function(cid)
        local all = originalGetFromClan(cid)
        if all and all[choice.bid] then
            return { [choice.bid] = all[choice.bid] }
        end
        return all
    end

    local args = {
        cid = choice.cid,
        x = x,
        y = y,
        z = z,
        program = "NPCNeutral",
        size = 1,
        key = key,
        permanent = true,
        hostile = false,
        hostileP = false,
    }
    local ok, err = pcall(BanditServer.Spawner.Clan, playerObj, args)
    BanditCustom.GetFromClan = originalGetFromClan
    if ok and TransmitBanditModData then TransmitBanditModData() end
    return ok, err
end

local function findSpawnedCompanion(expectedKey)
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        local brain = getBanditBrain(zombie)
        if brain and brain.key == expectedKey then return zombie, brain end
    end
    return nil, nil
end

local function removeCompanion(companion)
    if not companion then return end
    local id = companion:getPersistentOutfitID()
    local cluster = GetBanditClusterData and GetBanditClusterData(id) or nil
    if cluster then
        cluster[id] = nil
        if TransmitBanditCluster then TransmitBanditCluster(id) end
    end
    companion:removeFromWorld()
    companion:removeFromSquare()
    companion:setSquare(nil)
end

local function clearContainer(container)
    if not container then return end
    local items = container:getItems()
    for index = items:size() - 1, 0, -1 do
        local item = items:get(index)
        if isServer() then sendRemoveItemFromContainer(container, item) end
        container:Remove(item)
    end
end

local function emptyCompanionInventory(companion)
    if not companion then return end
    pcall(function()
        companion:setPrimaryHandItem(nil)
        companion:setSecondaryHandItem(nil)
        companion:clearWornItems()
        local attached = companion:getAttachedItems()
        for index = attached:size() - 1, 0, -1 do
            local item = attached:get(index):getItem()
            if item then companion:removeAttachedItem(item) end
        end
    end)
    clearContainer(companion:getInventory())
end

local function dropZombieBelongings(zombie)
    local source = zombie and zombie:getInventory()
    local square = zombie and zombie:getSquare()
    if not source or not square then return false end
    purgeZombieRecords(source)
    purgePacifyingCures(source)
    zombie:clearWornItems()

    -- Drop top-level items as themselves so backpacks and other containers keep
    -- their contents. Internal wear markers must not leak onto lootable items.
    local items = source:getItems()
    for index = items:size() - 1, 0, -1 do
        local item = items:get(index)
        if isServer() then sendRemoveItemFromContainer(source, item) end
        source:Remove(item)
        EPE.clearRecordWearMarker(item)
        square:AddWorldInventoryItem(
            item,
            ZombRandFloat(0.25, 0.75),
            ZombRandFloat(0.25, 0.75),
            0.0
        )
    end
    return true
end

local function clearPending(pending)
    if pending and pending.serum then pendingSerums[pending.serum] = nil end
end

local function failPending(key, pending, message)
    pendingRestorations[key] = nil
    clearPending(pending)
    if pending.companion and not pending.sourceRemoved then
        removeCompanion(pending.companion)
    elseif pending.sourceRemoved then
        -- The committed companion now owns the source zombie's real items. If
        -- recruitment/persistence ever times out, preserve it downed rather
        -- than deleting the player's only remaining copy of those belongings.
        print("[EugenesZombieCure] committed restoration could not finalize; "
            .. "the configured companion was preserved downed: " .. tostring(key))
    end
    if pending.playerObj then notify(pending.playerObj, message, false) end
end

local function finishRestoration(key, pending)
    local playerObj = pending.playerObj
    local companion = pending.companion
    local snapshot = pending.snapshot
    if not playerObj or not companion or type(snapshot) ~= "table" then
        failPending(key, pending, getText("IGUI_EZC_SourceMissing"))
        return
    end
    local companionBrain = getBanditBrain(companion)
    if not snapshot or not M.configureRestoredCompanion(
            companion, snapshot, true, companionBrain) then
        failPending(key, pending, getText("IGUI_EZC_ConfigureFailed"))
        return
    end

    pendingRestorations[key] = nil
    clearPending(pending)
    local configuredBrain = getBanditBrain(companion)
    if not isServer() and configuredBrain and BanditsNPC
        and BanditsNPC.Persistence and BanditsNPC.Persistence.Record then
        pcall(function()
            BanditsNPC.Persistence.Record(companion, configuredBrain)
        end)
    end
    local brain = getBanditBrain(companion)
    local persistentId = companion:getPersistentOutfitID()
    if brain and TransmitBanditCluster then TransmitBanditCluster(persistentId) end
    if isServer() then
        sendServerCommand(playerObj, M.MODULE, "configureRestoredCompanion", {
            key = key,
            targetId = companion:getOnlineID(),
            targetPersistentId = persistentId,
            snapshot = snapshot,
        })
    end
    notify(playerObj, getText("IGUI_EZC_RestorationSuccess"), true)
end

local function commitInstantRestoration(
    playerObj, zombie, companion, brain, itemId)
    local snapshot = EPE.makeZombieSnapshot(zombie)
    if not snapshot then return nil, "snapshot-unavailable" end

    emptyCompanionInventory(companion)
    local configured, configureResult = pcall(
        M.configureRestoredCompanion,
        companion,
        snapshot,
        true,
        brain
    )
    if not configured or configureResult ~= true then
        return nil, configured and "configuration-rejected"
            or tostring(configureResult)
    end

    if not consumeTreatment(
            playerObj, itemId, M.RESTORATION_ITEM_FULL_TYPE) then
        return nil, "serum-missing"
    end

    -- Commit in one Lua call: the temporary NPC is already configured downed
    -- and visually matches the source, while all physical belongings are left
    -- on the ground and the companion inventory stays empty.
    if not dropZombieBelongings(zombie) then
        return nil, "drop-square-unavailable"
    end
    M.clearPacifiedZombieState(zombie)
    zombie:removeFromWorld()
    zombie:removeFromSquare()
    zombie:setSquare(nil)

    local persistentId = companion:getPersistentOutfitID()
    if TransmitBanditCluster then TransmitBanditCluster(persistentId) end
    return snapshot, nil
end

local function processPendingRestorations()
    for key, pending in pairs(pendingRestorations) do
        if pending.failed then
            failPending(key, pending, getText("IGUI_EZC_ConfigureFailed"))
        else
            local companion, brain = pending.companion, nil
            if companion then brain = getBanditBrain(companion) end
            if not companion or not brain then
                companion, brain = findSpawnedCompanion(key)
                pending.companion = companion
            end

            if companion and brain then
                local masterId = BanditUtils.GetCharacterID(pending.playerObj)
                local recruited = brain.recruited == true and brain.master == masterId
                -- In single player the server cluster brain exists before
                -- BanditUpdate has attached that brain to the IsoZombie. True
                -- Companions' Recruit() only reads the attached client brain,
                -- so calling it during this gap always rejects the target.
                local recruitBrainReady = isServer()
                    or (BanditBrain and BanditBrain.Get
                        and BanditBrain.Get(companion) ~= nil)

                if recruited then
                    local completed, failure = pcall(
                        finishRestoration, key, pending)
                    if not completed then
                        print("[EugenesZombieCure] restoration completion failed: "
                            .. tostring(failure))
                        failPending(
                            key, pending, getText("IGUI_EZC_ConfigureFailed"))
                    end
                elseif recruitBrainReady
                    and pending.ticks >= (pending.nextRecruitTick or 0) then
                    pending.recruitAttempts = (pending.recruitAttempts or 0) + 1
                    pending.nextRecruitTick = pending.ticks + RECRUIT_RETRY_TICKS
                    local recruitArgs = {
                        key = key,
                        targetId = companion:getOnlineID(),
                        targetPersistentId = companion:getPersistentOutfitID(),
                    }
                    if isServer() then
                        sendServerCommand(pending.playerObj, M.MODULE,
                            "recruitTrueCompanion", recruitArgs)
                    elseif M.recruitWithTrueCompanions then
                        if not M.recruitWithTrueCompanions(recruitArgs, companion) then
                            pending.lastRecruitFailure = "local-recruit-not-ready"
                        end
                    else
                        pending.failed = true
                    end
                end
            end

            pending.ticks = pending.ticks + 1
            if pendingRestorations[key] and pending.ticks % 300 == 0 then
                print(string.format(
                    "[EugenesZombieCure] waiting for True Companions key=%s ticks=%d attempts=%d companion=%s brain=%s lastFailure=%s",
                    tostring(key),
                    pending.ticks,
                    pending.recruitAttempts or 0,
                    tostring(companion ~= nil),
                    tostring(brain ~= nil),
                    tostring(pending.lastRecruitFailure)
                ))
            end
            if pendingRestorations[key]
                and pending.ticks >= RESTORATION_TIMEOUT_TICKS then
                failPending(key, pending, getText("IGUI_EZC_SpawnTimedOut"))
            end
        end
    end
end

local function restoreZombie(playerObj, args, directTarget)
    local zombie = directTarget or findZombieByOnlineId(tonumber(args.targetId))
    if not M.canRestoreZombie(playerObj, zombie) then
        notify(playerObj, getText("IGUI_EZC_RestoreInvalid"), false)
        return
    end

    local choice = chooseTrueCompanionProfile(zombie)
    if not choice then
        notify(playerObj, getText("IGUI_EZC_ProfileUnavailable"), false)
        return
    end

    local itemId = tonumber(args.itemId)
    local serum = itemId and playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not M.hasTreatmentItem(playerObj, serum)
        or serum:getFullType() ~= M.RESTORATION_ITEM_FULL_TYPE then
        notify(playerObj, getText("IGUI_EZC_SerumMissing"), false)
        return
    end
    if pendingSerums[serum] then
        notify(playerObj, getText("IGUI_EZC_RestorationPending"), false)
        return
    end

    ensureZombieInventory(zombie)
    local stamp = getTimestampMs and getTimestampMs() or 0
    local restorationKey = string.format(
        "ezc-tc-%s-%s",
        tostring(stamp),
        tostring(ZombRand(1000000000))
    )
    pendingSerums[serum] = true
    local spawnOk, spawnError = spawnThroughTrueCompanions(
        playerObj,
        choice,
        restorationKey,
        zombie:getX(),
        zombie:getY(),
        zombie:getZ()
    )
    if not spawnOk then
        print("[EugenesZombieCure] True Companions spawn rejected: " .. tostring(spawnError))
        pendingSerums[serum] = nil
        notify(playerObj, getText("IGUI_EZC_SpawnRejected"), false)
        return
    end

    local companion, brain = findSpawnedCompanion(restorationKey)
    if not companion or not brain then
        pendingSerums[serum] = nil
        print("[EugenesZombieCure] True Companions spawn produced no keyed NPC: "
            .. tostring(restorationKey))
        notify(playerObj, getText("IGUI_EZC_SpawnRejected"), false)
        return
    end

    local snapshot, commitError = commitInstantRestoration(
        playerObj, zombie, companion, brain, itemId)
    if not snapshot then
        pendingSerums[serum] = nil
        print("[EugenesZombieCure] instantaneous restoration rejected: "
            .. tostring(commitError))
        removeCompanion(companion)
        notify(playerObj, getText("IGUI_EZC_ConfigureFailed"), false)
        return
    end

    pendingRestorations[restorationKey] = {
        playerObj = playerObj,
        companion = companion,
        snapshot = snapshot,
        sourceRemoved = true,
        serum = serum,
        bid = choice.bid,
        cid = choice.cid,
        ticks = 0,
    }
end

local function isLegacyRestoredBrain(brain)
    return brain and (brain.EugenesZombieCureRestored == true
        or (type(brain.key) == "string" and string.sub(brain.key, 1, 12) == "ezc-restore-"))
end

local function finishLegacyMigration(playerObj, args, directTarget)
    local zombie = directTarget or findZombieByOnlineId(tonumber(args.targetId))
    local brain = getBanditBrain(zombie)
    if not zombie or not isLegacyRestoredBrain(brain) then return end
    if brain.master ~= BanditUtils.GetCharacterID(playerObj) then return end

    if type(brain.npcClothVar) ~= "table" then brain.npcClothVar = {} end
    brain.npcClothVar.__EugenesZombieCure = { restored = true, fond = true }
    brain.EugenesZombieCureRestored = nil
    brain.EugenesZombieCureRecordVersion = nil
    brain.EugenesZombieCureEquipmentVersion = nil
    brain.EugenesZombieCureVisualVersion = nil
    brain.EugenesZombieCureSnapshot = nil
    if type(brain.key) == "string" and string.sub(brain.key, 1, 12) == "ezc-restore-" then
        brain.key = nil
    end
    zombie:getModData().brain = brain
    BanditBrain.Update(zombie, brain)
    local id = zombie:getPersistentOutfitID()
    local cluster = GetBanditClusterData and GetBanditClusterData(id) or nil
    if cluster then
        cluster[id] = brain
        if TransmitBanditCluster then TransmitBanditCluster(id) end
    end
    purgeZombieRecords(zombie:getInventory())
    zombie:getModData().EugenesProneEquipmentInitialized = nil
    M.normalizeRestoredCompanionAnimation(zombie, brain)
    zombie:resetModelNextFrame()
    print("[EugenesZombieCure] migrated legacy restored NPC to True Companions: "
        .. tostring(brain.fullname or brain.id))
end

M.finishLegacyMigration = finishLegacyMigration

function M.handleUseCure(playerObj, args, directTarget)
    if not playerObj or not args then return end
    if args.operation == "self" then
        curePlayer(playerObj, args)
    elseif args.operation == "zombie" then
        cureZombie(playerObj, args, directTarget)
    elseif args.operation == "restore" then
        restoreZombie(playerObj, args, directTarget)
    elseif args.operation == "reanimate" then
        reanimateCorpse(playerObj, args, directTarget)
    end
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= M.MODULE then return end
    args = args or {}
    if command == "useCure" then
        M.handleUseCure(playerObj, args)
    elseif command == "trueCompanionRecruitResult" then
        local pending = pendingRestorations[args.key]
        if pending and pending.playerObj == playerObj then
            if args.ok == true then
                pending.lastRecruitFailure = nil
            else
                pending.lastRecruitFailure = args.reason or "client-recruit-not-ready"
                -- The companion object and its brain replicate separately. A
                -- first miss is expected in MP, so retry instead of aborting.
                pending.nextRecruitTick = math.min(
                    pending.nextRecruitTick or pending.ticks,
                    pending.ticks + 15
                )
            end
        end
    elseif command == "legacyTrueCompanionMigrated" then
        finishLegacyMigration(playerObj, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(processPendingRestorations)
