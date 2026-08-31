require "EugenesZombieCure_Shared"
require "BanditCustom"
require "BanditServerSpawner"
require "Bandit"
require "BanditBrain"
require "BanditNames"
require "BanditUtils"

local M = EugenesZombieCure
local EPE = EugenesProneEquipment
local pendingRestorations = {}
local pendingSerums = setmetatable({}, { __mode = "k" })
local restoredUpgradeTicks = 0

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
    if not M.hasTreatmentItem(playerObj, item) or item:getFullType() ~= expectedType then
        return false
    end
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
    local itemId = tonumber(args.itemId)
    if not itemId or not consumeTreatment(playerObj, itemId, M.ITEM_FULL_TYPE) then
        notify(playerObj, getText("IGUI_EZC_CureMissing"), false)
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
    notify(playerObj, getText("IGUI_EZC_ZombiePacified"), true)
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

local function findSpawnedBandit(expectedKey)
    local zombies = getCell():getZombieList()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        local id = zombie:getPersistentOutfitID()
        local cluster = GetBanditClusterData(id)
        local brain = cluster and cluster[id]
        if brain and brain.key == expectedKey then
            return zombie
        end
    end
    return nil
end

local function removeCompanion(companion)
    if not companion then return end
    local id = companion:getPersistentOutfitID()
    local cluster = GetBanditClusterData(id)
    if cluster then
        cluster[id] = nil
        TransmitBanditCluster(id)
    end
    companion:removeFromWorld()
    companion:removeFromSquare()
    companion:setSquare(nil)
end

local function moveAllItemsWithoutSync(source, destination)
    if not source or not destination then return end
    local items = source:getItems()
    for index = items:size() - 1, 0, -1 do
        local item = items:get(index)
        source:Remove(item)
        destination:AddItem(item)
    end
end

local function makeBanditClothing(snapshot)
    local clothing = {}
    local tint = {}
    for _, row in ipairs(snapshot and snapshot.worn or {}) do
        local bodyLocation = row.banditLocation or row.location
        if bodyLocation and row.fullType then
            clothing[bodyLocation] = row.fullType
            local color = row.tint
            if color and BanditUtils and BanditUtils.rgb2dec then
                tint[bodyLocation] = BanditUtils.rgb2dec(
                    color.r or 1,
                    color.g or 1,
                    color.b or 1
                )
            end
        end
    end
    return clothing, tint
end

local function makeCompanionName(female)
    if BanditNames and BanditNames.GenerateName then
        local ok, name = pcall(BanditNames.GenerateName, female == true)
        if ok and name and name ~= "" then return name end
    end
    return getText(female and "IGUI_EZC_FallbackNameFemale" or "IGUI_EZC_FallbackNameMale")
end

local function getMasterId(playerObj)
    if playerObj and BanditUtils and BanditUtils.GetCharacterID then
        local ok, id = pcall(BanditUtils.GetCharacterID, playerObj)
        if ok then return id end
    end
    return nil
end

local function configureRestoredCompanion(companion, pending)
    local record = EPE.findZombieRecord(pending.zombie:getInventory())
    local snapshot = EPE.getZombieRecordSnapshot(record)
    if not record or not snapshot then error("physical zombie record is missing") end

    local id = companion:getPersistentOutfitID()
    local cluster = GetBanditClusterData(id)
    local brain = cluster and cluster[id] or companion:getModData().brain
    if not brain then error("Bandits companion brain is unavailable") end

    local clothing, tint = makeBanditClothing(snapshot)
    brain.EugenesZombieCureRestored = true
    brain.EugenesZombieCureRecordVersion = EPE.RECORD_SCHEMA_VERSION
    brain.EugenesZombieCureSnapshot = nil
    brain.fullname = pending.fullname
    brain.female = snapshot.appearance and snapshot.appearance.female == true
    brain.master = pending.masterId or brain.master
    brain.permanent = true
    brain.loyal = true
    brain.hostile = false
    brain.hostileP = false
    brain.stationary = false
    brain.sleeping = false
    brain.tasks = {}
    brain.program = { name = "Companion", stage = "Prepare" }
    brain.programFallback = "Companion"
    brain.clothing = clothing
    brain.tint = tint
    brain.bag = nil
    brain.key = nil

    companion:getModData().brain = brain
    if BanditBrain and BanditBrain.Update then BanditBrain.Update(companion, brain) end
    if cluster then
        cluster[id] = brain
        TransmitBanditCluster(id)
    end

    companion:clearWornItems()
    companion:getInventory():removeAllItems()
    pending.inventoryTransferred = true
    moveAllItemsWithoutSync(pending.zombie:getInventory(), companion:getInventory())
    if not EPE.applyZombieRecord(companion, record, false) then
        error("physical zombie record could not be applied")
    end
    pending.previousRestoredName = snapshot.restoredName
    snapshot.restoredName = pending.fullname
    record = EPE.createZombieRecordFromSnapshot(snapshot, companion:getInventory())
    if not record then error("physical zombie record could not be named") end
    companion:setTarget(nil)
    companion:clearAggroList()
    companion:setTargetSeenTime(0)
    if Bandit and Bandit.UpdateItemsToSpawnAtDeath then
        Bandit.UpdateItemsToSpawnAtDeath(companion, brain)
    end
    companion:resetModelNextFrame()
end

local function rollbackCompanionInventory(companion, pending)
    local zombie = pending and pending.zombie
    if not companion or not zombie or not pending.inventoryTransferred then return end
    moveAllItemsWithoutSync(companion:getInventory(), zombie:getInventory())
    pending.inventoryTransferred = false
    local record = EPE.findZombieRecord(zombie:getInventory())
    local snapshot = EPE.getZombieRecordSnapshot(record)
    if snapshot then
        snapshot.restoredName = pending.previousRestoredName
        record = EPE.createZombieRecordFromSnapshot(snapshot, zombie:getInventory())
    end
    if record then EPE.applyZombieRecord(zombie, record, true) end
end

local function safeRollbackCompanionInventory(companion, pending)
    local ok, rollbackError = pcall(rollbackCompanionInventory, companion, pending)
    if not ok then
        print("[EugenesZombieCure] companion rollback failed: " .. tostring(rollbackError))
    end
end

local function clearPendingSerum(pending)
    if pending and pending.serum then pendingSerums[pending.serum] = nil end
end

local function finishPendingRestoration(key, pending, companion)
    pendingRestorations[key] = nil
    clearPendingSerum(pending)
    local playerObj = pending.playerObj
    local zombie = pending.zombie
    if not playerObj or not M.isPacifiedZombie(zombie) then
        removeCompanion(companion)
        if playerObj then notify(playerObj, getText("IGUI_EZC_SourceMissing"), false) end
        return
    end

    local configured, configureError = pcall(configureRestoredCompanion, companion, pending)
    if not configured then
        print("[EugenesZombieCure] companion configuration failed: " .. tostring(configureError))
        safeRollbackCompanionInventory(companion, pending)
        removeCompanion(companion)
        notify(playerObj, getText("IGUI_EZC_ConfigureFailed"), false)
        return
    end
    if not consumeTreatment(playerObj, pending.itemId, M.RESTORATION_ITEM_FULL_TYPE) then
        safeRollbackCompanionInventory(companion, pending)
        removeCompanion(companion)
        notify(playerObj, getText("IGUI_EZC_SerumMissing"), false)
        return
    end

    M.clearPacifiedZombieState(zombie)
    zombie:removeFromWorld()
    zombie:removeFromSquare()
    zombie:setSquare(nil)
    notify(playerObj, getText("IGUI_EZC_RestorationSuccess"), true)
end

local function processPendingRestorations()
    for key, pending in pairs(pendingRestorations) do
        local companion = findSpawnedBandit(key)
        if companion then
            print(string.format(
                "[EugenesZombieCure] restoration verified key=%s after %s tick(s)",
                tostring(key),
                tostring(pending.ticks)
            ))
            finishPendingRestoration(key, pending, companion)
        else
            pending.ticks = pending.ticks + 1
            if pending.ticks >= 300 then
                print(string.format(
                    "[EugenesZombieCure] restoration timed out key=%s bid=%s",
                    tostring(key),
                    tostring(pending.bid)
                ))
                pendingRestorations[key] = nil
                clearPendingSerum(pending)
                notify(pending.playerObj, getText("IGUI_EZC_SpawnTimedOut"), false)
            end
        end
    end
end

local function getFirstPlayer()
    if not isServer() then return getSpecificPlayer(0) end
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if players and players:size() > 0 then return players:get(0) end
    return nil
end

local function upgradeExistingRestoredCompanions()
    restoredUpgradeTicks = restoredUpgradeTicks + 1
    if restoredUpgradeTicks < 300 then return end
    restoredUpgradeTicks = 0
    local zombies = getCell() and getCell():getZombieList()
    if not zombies then return end
    local defaultMaster = getFirstPlayer()
    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        local id = zombie:getPersistentOutfitID()
        local cluster = GetBanditClusterData(id)
        local brain = cluster and cluster[id]
        if M.isRestoredCompanionBrain(brain) then
            local changed = false
            local record = EPE.findZombieRecord(zombie:getInventory())
            if not record then
                record = EPE.createOrUpdateZombieRecord(zombie)
                changed = record ~= nil
            end
            local recordSnapshot = EPE.getZombieRecordSnapshot(record)
            if brain.EugenesZombieCureSnapshot ~= nil then
                brain.EugenesZombieCureSnapshot = nil
                changed = true
            end
            if type(brain.key) == "string" and string.sub(brain.key, 1, 12) == "ezc-restore-" then
                brain.key = nil
                changed = true
            end
            if brain.EugenesZombieCureRestored ~= true then
                brain.EugenesZombieCureRestored = true
                changed = true
            end
            if tonumber(brain.EugenesZombieCureRecordVersion) ~= EPE.RECORD_SCHEMA_VERSION then
                brain.EugenesZombieCureRecordVersion = EPE.RECORD_SCHEMA_VERSION
                changed = true
            end
            if recordSnapshot and recordSnapshot.appearance
                and recordSnapshot.appearance.female ~= nil
                and brain.female ~= (recordSnapshot.appearance.female == true) then
                brain.female = recordSnapshot.appearance.female == true
                changed = true
            end
            if not brain.fullname or brain.fullname == "" then
                brain.fullname = recordSnapshot and recordSnapshot.restoredName
                    or makeCompanionName(zombie:isFemale())
                changed = true
            end
            if recordSnapshot and recordSnapshot.restoredName ~= brain.fullname then
                recordSnapshot.restoredName = brain.fullname
                EPE.createZombieRecordFromSnapshot(recordSnapshot, zombie:getInventory())
                changed = true
            end
            local masterId = getMasterId(defaultMaster)
            if masterId and not brain.master then
                brain.master = masterId
                changed = true
            end
            if changed then
                brain.permanent = true
                brain.loyal = true
                brain.hostile = false
                brain.hostileP = false
                brain.stationary = false
                brain.sleeping = false
                brain.tasks = {}
                brain.program = { name = "Companion", stage = "Prepare" }
                brain.programFallback = "Companion"
                zombie:getModData().brain = brain
                cluster[id] = brain
                TransmitBanditCluster(id)
                M.clearRestoredRecordCache(zombie)
                M.activateRestoredCompanion(zombie, brain)
                if Bandit and Bandit.UpdateItemsToSpawnAtDeath then
                    Bandit.UpdateItemsToSpawnAtDeath(zombie, brain)
                end
                print(string.format(
                    "[EugenesZombieCure] migrated companion to physical record id=%s name=%s",
                    tostring(id),
                    tostring(brain.fullname)
                ))
            end
        end
    end
end

local function ensureZombieInventory(zombie)
    local data = zombie:getModData()
    if data.EugenesProneEquipmentInitialized then return end
    zombie:DoZombieInventory()
    data.EugenesProneEquipmentInitialized = true
end

local function restoreZombie(playerObj, args, directTarget)
    local zombie = directTarget or findZombieByOnlineId(tonumber(args.targetId))
    if not M.canRestoreZombie(playerObj, zombie) then
        notify(playerObj, getText("IGUI_EZC_RestoreInvalid"), false)
        return
    end
    local bid = chooseFriendlyBanditProfile(zombie)
    if not bid or not BanditServer or not BanditServer.Spawner
        or not BanditServer.Spawner.Individual then
        notify(playerObj, getText("IGUI_EZC_ProfileUnavailable"), false)
        return
    end

    local profile = BanditCustom.GetById(bid)
    if not profile or not profile.general then
        notify(playerObj, getText("IGUI_EZC_ProfileUnavailable"), false)
        return
    end
    profile.general.bid = bid
    profile.cid = profile.general.cid

    local itemId = tonumber(args.itemId)
    local serum = itemId and playerObj:getInventory():getItemWithIDRecursiv(itemId)
    if not M.hasTreatmentItem(playerObj, serum)
        or serum:getFullType() ~= M.RESTORATION_ITEM_FULL_TYPE then
        notify(playerObj, getText("IGUI_EZC_SerumMissing"), false)
        return
    end
    serum:getModData().EugenesZombieCureRestorationPending = nil
    if pendingSerums[serum] then
        notify(playerObj, getText("IGUI_EZC_RestorationPending"), false)
        return
    end

    ensureZombieInventory(zombie)
    local record = EPE.createOrUpdateZombieRecord(zombie)
    if not record then
        notify(playerObj, getText("IGUI_EZC_RecordMissing"), false)
        return
    end

    local spawnX = zombie:getX()
    local spawnY = zombie:getY()
    local spawnZ = zombie:getZ()
    local companionName = makeCompanionName(zombie:isFemale())
    local masterId = getMasterId(playerObj)
    local stamp = getTimestampMs and getTimestampMs() or 0
    local restorationKey = string.format(
        "ezc-restore-%s-%s",
        tostring(stamp),
        tostring(ZombRand(1000000000))
    )
    local spawnArgs = {
        bid = bid,
        x = spawnX,
        y = spawnY,
        z = spawnZ,
        program = "Companion",
        key = restorationKey,
        permanent = true,
        loyal = true,
        hostile = false,
        hostileP = false,
        fullname = companionName,
    }
    pendingSerums[serum] = true
    print(string.format(
        "[EugenesZombieCure] requesting companion key=%s bid=%s at %.2f,%.2f,%.2f",
        restorationKey,
        tostring(bid),
        spawnX,
        spawnY,
        spawnZ
    ))
    local spawnOk, spawnError = pcall(BanditServer.Spawner.Individual, playerObj, spawnArgs)
    if not spawnOk then
        print("[EugenesZombieCure] Bandits spawn rejected: " .. tostring(spawnError))
        pendingSerums[serum] = nil
        notify(playerObj, getText("IGUI_EZC_SpawnRejected"), false)
        return
    end
    pendingRestorations[restorationKey] = {
        playerObj = playerObj,
        zombie = zombie,
        serum = serum,
        itemId = itemId,
        bid = bid,
        fullname = companionName,
        masterId = masterId,
        ticks = 0,
    }
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
Events.OnTick.Add(processPendingRestorations)
Events.OnTick.Add(upgradeExistingRestoredCompanions)
