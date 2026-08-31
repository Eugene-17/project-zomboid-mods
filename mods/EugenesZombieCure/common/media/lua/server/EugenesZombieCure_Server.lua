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

local function purgeZombieRecords(container)
    if not container then return 0 end
    local removed = 0
    local records = container:getAllEvalRecurse(function(item)
        return EPE.isZombieRecord(item)
    end)
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
    local itemId = tonumber(args.itemId)
    if not itemId or not consumeTreatment(playerObj, itemId, M.ITEM_FULL_TYPE) then
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

local function makeEmptyWeapons()
    return {
        melee = "Base.BareHands",
        primary = { bulletsLeft = 0, magCount = 0 },
        secondary = { bulletsLeft = 0, magCount = 0 },
    }
end

local function getRestoredCompanionBrain(companion)
    if not companion or not instanceof(companion, "IsoZombie") then return nil end
    local id = companion:getPersistentOutfitID()
    local cluster = GetBanditClusterData and GetBanditClusterData(id) or nil
    local brain = cluster and cluster[id] or companion:getModData().brain
    if not M.isRestoredCompanionBrain(brain) then return nil end
    brain.weapons = brain.weapons or makeEmptyWeapons()
    brain.weapons.melee = brain.weapons.melee or "Base.BareHands"
    brain.weapons.primary = brain.weapons.primary or { bulletsLeft = 0, magCount = 0 }
    brain.weapons.secondary = brain.weapons.secondary or { bulletsLeft = 0, magCount = 0 }
    return brain, cluster, id
end

local function syncRestoredCompanionBrain(companion, brain, cluster, id)
    brain.tasks = {}
    companion:getModData().brain = brain
    if BanditBrain and BanditBrain.Update then BanditBrain.Update(companion, brain) end
    if cluster then
        cluster[id] = brain
        if TransmitBanditCluster then TransmitBanditCluster(id) end
    end
end

local function removeInventoryItem(item)
    local source = item and item:getContainer()
    if not source then return false end
    if isServer() then sendRemoveItemFromContainer(source, item) end
    source:Remove(item)
    return true
end

local function addInventoryItem(container, item)
    if not container or not item then return false end
    container:AddItem(item)
    if isServer() then sendAddItemToContainer(container, item) end
    return true
end

local function addItemType(container, fullType)
    local item = fullType and instanceItem(fullType) or nil
    if item then addInventoryItem(container, item) end
    return item
end

local function materializeRangedAmmo(container, weapon)
    if not weapon then return end
    if weapon.type == "mag" and weapon.magName then
        for _ = 1, math.max(0, tonumber(weapon.magCount) or 0) do
            local magazine = instanceItem(weapon.magName)
            if magazine then
                pcall(function() magazine:setMaxAmmo(tonumber(weapon.magSize) or 0) end)
                pcall(function() magazine:setCurrentAmmoCount(tonumber(weapon.magSize) or 0) end)
                addInventoryItem(container, magazine)
            end
        end
    elseif weapon.type == "nomag" and weapon.ammoName then
        for _ = 1, math.max(0, tonumber(weapon.ammoCount) or 0) do
            addItemType(container, weapon.ammoName)
        end
    end
end

local function materializeWeapon(companion, weapon)
    local fullType = type(weapon) == "table" and weapon.name or weapon
    if not fullType or fullType == "Base.BareHands" then return end
    local inventory = companion:getInventory()
    local item = instanceItem(fullType)
    if item and type(weapon) == "table" then
        pcall(function() item:setCurrentAmmoCount(math.max(0, tonumber(weapon.bulletsLeft) or 0)) end)
        pcall(function() item:setContainsClip(weapon.clipIn == true) end)
    end
    if item then addInventoryItem(inventory, item) end
    if type(weapon) == "table" then materializeRangedAmmo(inventory, weapon) end
end

local function makeRangedWeapon(item)
    local weapon = {
        name = item:getFullType(),
        bulletsLeft = math.max(0, tonumber(item:getCurrentAmmoCount()) or 0),
        racked = true,
    }
    if BanditCompatibility.UsesExternalMagazine(item) then
        weapon.type = "mag"
        weapon.magName = item:getMagazineType()
        weapon.magSize = math.max(1, tonumber(item:getMaxAmmo()) or 1)
        weapon.magCount = 0
        local containsClip = false
        pcall(function() containsClip = item:isContainsClip() end)
        weapon.clipIn = containsClip or weapon.bulletsLeft > 0
    else
        local ammoType = item:getAmmoType()
        weapon.type = "nomag"
        weapon.ammoName = ammoType and ammoType:getItemKey() or nil
        weapon.ammoSize = math.max(1, tonumber(item:getMaxAmmo()) or 1)
        weapon.ammoCount = 0
    end
    return weapon
end

local function getWeaponSlot(item)
    if not item or not item:IsWeapon() then return nil end
    local weaponType = WeaponType.getWeaponType(item)
    if weaponType == WeaponType.FIREARM then return "primary" end
    if weaponType == WeaponType.HANDGUN then return "secondary" end
    return "melee"
end

local function tryAddRangedAmmo(weapons, item)
    for _, slotName in ipairs({ "primary", "secondary" }) do
        local weapon = weapons[slotName]
        if weapon and weapon.name then
            if weapon.type == "mag" and weapon.magName == item:getFullType() then
                local bullets = 0
                pcall(function() bullets = math.max(0, tonumber(item:getCurrentAmmoCount()) or 0) end)
                if bullets > 0 then
                    if (tonumber(weapon.bulletsLeft) or 0) <= 0 and weapon.clipIn ~= true then
                        weapon.bulletsLeft = bullets
                        weapon.clipIn = true
                        weapon.racked = false
                    else
                        weapon.magCount = (tonumber(weapon.magCount) or 0) + 1
                    end
                    return true
                end
            elseif weapon.type == "nomag" and weapon.ammoName == item:getFullType() then
                weapon.ammoCount = (tonumber(weapon.ammoCount) or 0) + 1
                return true
            end
        end
    end
    return false
end

function M.acceptRestoredCompanionCombatItem(companion, item)
    local brain, cluster, id = getRestoredCompanionBrain(companion)
    if not brain or not item then return false end

    local slotName = getWeaponSlot(item)
    if slotName and not item:isBroken() then
        local previous = brain.weapons[slotName]
        if slotName == "melee" then
            materializeWeapon(companion, previous)
            brain.weapons.melee = item:getFullType()
        else
            materializeWeapon(companion, previous)
            brain.weapons[slotName] = makeRangedWeapon(item)
        end
        removeInventoryItem(item)
        syncRestoredCompanionBrain(companion, brain, cluster, id)
        companion:setPrimaryHandItem(nil)
        companion:setSecondaryHandItem(nil)
        local equipped = pcall(Bandit.SetHands, companion, item:getFullType())
        if not equipped then
            companion:setPrimaryHandItem(instanceItem(item:getFullType()))
        end
        if companion.resetEquippedHandsModels then companion:resetEquippedHandsModels() end
        M.updateRestoredItemsToSpawnAtDeath(companion)
        return true
    end

    if tryAddRangedAmmo(brain.weapons, item) then
        removeInventoryItem(item)
        syncRestoredCompanionBrain(companion, brain, cluster, id)
        M.updateRestoredItemsToSpawnAtDeath(companion)
        return true
    end
    return false
end

function M.takeRestoredCompanionWeapon(companion, item, destination)
    local brain, cluster, id = getRestoredCompanionBrain(companion)
    if not brain or not item or not destination or item:getContainer() then return false end
    local fullType = item:getFullType()
    local slotName
    if brain.weapons.primary.name == fullType then
        slotName = "primary"
    elseif brain.weapons.secondary.name == fullType then
        slotName = "secondary"
    elseif brain.weapons.melee == fullType then
        slotName = "melee"
    end
    if not slotName then return false end

    local stored = brain.weapons[slotName]
    if type(stored) == "table" then
        pcall(function() item:setCurrentAmmoCount(math.max(0, tonumber(stored.bulletsLeft) or 0)) end)
        pcall(function() item:setContainsClip(stored.clipIn == true) end)
        materializeRangedAmmo(companion:getInventory(), stored)
        brain.weapons[slotName] = { bulletsLeft = 0, magCount = 0 }
    else
        brain.weapons.melee = "Base.BareHands"
    end
    companion:setPrimaryHandItem(nil)
    companion:setSecondaryHandItem(nil)
    addInventoryItem(destination, item)
    syncRestoredCompanionBrain(companion, brain, cluster, id)
    M.updateRestoredItemsToSpawnAtDeath(companion)
    if companion.resetEquippedHandsModels then companion:resetEquippedHandsModels() end
    return true
end

local function clearCompanionEquipment(companion)
    companion:setPrimaryHandItem(nil)
    companion:setSecondaryHandItem(nil)
    local attachedItems = companion:getAttachedItems()
    for index = attachedItems:size() - 1, 0, -1 do
        local entry = attachedItems:get(index)
        local item = entry and entry:getItem() or nil
        if item then companion:removeAttachedItem(item) end
    end
    if companion.resetEquippedHandsModels then companion:resetEquippedHandsModels() end
end

local function acceptAllItems(item)
    return item ~= nil
end

function M.updateRestoredItemsToSpawnAtDeath(companion)
    if not companion then return end
    local brain = companion:getModData().brain
    if brain and brain.weapons and Bandit and Bandit.UpdateItemsToSpawnAtDeath then
        Bandit.UpdateItemsToSpawnAtDeath(companion, brain)
        return
    end
    companion:clearItemsToSpawnAtDeath()
    local items = ArrayList.new()
    companion:getInventory():getAllEvalRecurse(acceptAllItems, items)
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        item:getModData().preserve = true
        companion:addItemToSpawnAtDeath(item)
    end
end

local function makeRecordNetworkVisuals(snapshot)
    local visuals = {}
    for _, row in ipairs(snapshot and snapshot.worn or {}) do
        local tint = row.tint or {}
        visuals[#visuals + 1] = {
            fullType = row.fullType,
            hue = row.hue,
            baseTexture = row.baseTexture,
            textureChoice = row.textureChoice,
            tintR = tint.r,
            tintG = tint.g,
            tintB = tint.b,
            tintA = tint.a,
        }
    end
    return visuals
end

local function syncRecordVisuals(companion, snapshot)
    if not isServer() then return end
    sendServerCommand(EPE.MODULE, "zombieVisuals", {
        targetId = companion:getOnlineID(),
        targetX = math.floor(companion:getX()),
        targetY = math.floor(companion:getY()),
        targetZ = math.floor(companion:getZ()),
        appearance = snapshot.appearance,
        visuals = makeRecordNetworkVisuals(snapshot),
    })
end

local function makeBanditClothing(snapshot)
    local clothing = {}
    local tint = {}
    for _, row in ipairs(snapshot and snapshot.worn or {}) do
        local bodyLocation = row.banditLocation or row.location
        if bodyLocation then
            bodyLocation = tostring(bodyLocation):gsub("^.-:", ""):gsub("^.-%.", "")
        end
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

function M.updateRestoredCompanionSnapshot(companion, brain, snapshot)
    if not companion or not M.isRestoredCompanionBrain(brain) or not snapshot then
        return false
    end
    brain.EugenesZombieCureSnapshot = snapshot
    brain.EugenesZombieCureVisualVersion = M.RESTORED_VISUAL_VERSION
    brain.clothing, brain.tint = makeBanditClothing(snapshot)
    if snapshot.appearance and snapshot.appearance.female ~= nil then
        brain.female = snapshot.appearance.female == true
    end
    -- These generated Bandits profile fields overwrite the exact appearance
    -- restored from the physical zombie snapshot on every update.
    brain.skin = nil
    brain.hairType = nil
    brain.beardType = nil
    brain.hairColor = nil
    return true
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
    pending.previousRestoredName = snapshot.restoredName
    snapshot.restoredName = pending.fullname

    local id = companion:getPersistentOutfitID()
    local cluster = GetBanditClusterData(id)
    local brain = cluster and cluster[id] or companion:getModData().brain
    if not brain then error("Bandits companion brain is unavailable") end

    brain.EugenesZombieCureRestored = true
    brain.EugenesZombieCureRecordVersion = EPE.RECORD_SCHEMA_VERSION
    brain.EugenesZombieCureEquipmentVersion = M.RESTORED_EQUIPMENT_VERSION
    brain.EugenesZombieCureSnapshot = snapshot
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
    M.updateRestoredCompanionSnapshot(companion, brain, snapshot)
    brain.bag = nil
    brain.weapons = makeEmptyWeapons()
    brain.inventory = {}
    brain.loot = {}
    brain.key = nil

    companion:getModData().brain = brain
    if BanditBrain and BanditBrain.Update then BanditBrain.Update(companion, brain) end
    if cluster then
        cluster[id] = brain
        TransmitBanditCluster(id)
    end

    clearCompanionEquipment(companion)
    companion:clearWornItems()
    companion:getInventory():removeAllItems()
    pending.inventoryTransferred = true
    moveAllItemsWithoutSync(pending.zombie:getInventory(), companion:getInventory())
    if not EPE.applyZombieRecord(companion, record, false) then
        error("physical zombie record could not be applied")
    end
    record = EPE.createZombieRecordFromSnapshot(snapshot, companion:getInventory())
    if not record then error("physical zombie record could not be named") end
    companion:setTarget(nil)
    companion:clearAggroList()
    companion:setTargetSeenTime(0)
    M.updateRestoredItemsToSpawnAtDeath(companion)
    syncRecordVisuals(companion, snapshot)
    companion:resetModelNextFrame()
    companion:setVariable("BanditWalkType", "Walk")
    companion:setWalkType("Walk")
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
        if zombie then purgeZombieRecords(zombie:getInventory()) end
        removeCompanion(companion)
        if playerObj then notify(playerObj, getText("IGUI_EZC_SourceMissing"), false) end
        return
    end

    local configured, configureError = pcall(configureRestoredCompanion, companion, pending)
    if not configured then
        print("[EugenesZombieCure] companion configuration failed: " .. tostring(configureError))
        safeRollbackCompanionInventory(companion, pending)
        purgeZombieRecords(zombie:getInventory())
        removeCompanion(companion)
        notify(playerObj, getText("IGUI_EZC_ConfigureFailed"), false)
        return
    end
    if not consumeTreatment(playerObj, pending.itemId, M.RESTORATION_ITEM_FULL_TYPE) then
        safeRollbackCompanionInventory(companion, pending)
        purgeZombieRecords(zombie:getInventory())
        removeCompanion(companion)
        notify(playerObj, getText("IGUI_EZC_SerumMissing"), false)
        return
    end

    purgeZombieRecords(companion:getInventory())
    M.updateRestoredItemsToSpawnAtDeath(companion)
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
                if pending.zombie then purgeZombieRecords(pending.zombie:getInventory()) end
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
            local appearanceChanged = false
            local record = EPE.findZombieRecord(zombie:getInventory())
            local recordSnapshot = EPE.getZombieRecordSnapshot(record)
                or brain.EugenesZombieCureSnapshot
                or EPE.makeZombieSnapshot(zombie)
            if purgeZombieRecords(zombie:getInventory()) > 0 then changed = true end
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
            if recordSnapshot and tonumber(brain.EugenesZombieCureEquipmentVersion)
                ~= M.RESTORED_EQUIPMENT_VERSION then
                brain.clothing, brain.tint = makeBanditClothing(recordSnapshot)
                brain.bag = nil
                brain.weapons = makeEmptyWeapons()
                brain.inventory = {}
                brain.loot = {}
                brain.EugenesZombieCureEquipmentVersion = M.RESTORED_EQUIPMENT_VERSION
                clearCompanionEquipment(zombie)
                changed = true
            end
            if recordSnapshot and tonumber(brain.EugenesZombieCureVisualVersion)
                ~= M.RESTORED_VISUAL_VERSION then
                M.updateRestoredCompanionSnapshot(zombie, brain, recordSnapshot)
                appearanceChanged = true
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
                changed = true
            end
            if recordSnapshot and brain.EugenesZombieCureSnapshot ~= recordSnapshot then
                brain.EugenesZombieCureSnapshot = recordSnapshot
                changed = true
            end
            local masterId = getMasterId(defaultMaster)
            if masterId and not brain.master then
                brain.master = masterId
                changed = true
            end
            local programName = type(brain.program) == "table" and brain.program.name or brain.program
            if programName ~= "Companion" and programName ~= "CompanionGuard" then
                brain.program = { name = "Companion", stage = "Prepare" }
                brain.programFallback = "Companion"
                brain.tasks = {}
                changed = true
            end
            if not brain.permanent or not brain.loyal or brain.hostile or brain.hostileP then
                brain.permanent = true
                brain.loyal = true
                brain.hostile = false
                brain.hostileP = false
                changed = true
            end
            if changed then
                zombie:getModData().brain = brain
                cluster[id] = brain
                TransmitBanditCluster(id)
                M.updateRestoredItemsToSpawnAtDeath(zombie)
                if appearanceChanged and recordSnapshot then
                    M.clearRestoredRecordCache(zombie)
                    M.activateRestoredCompanion(zombie, brain)
                    syncRecordVisuals(zombie, recordSnapshot)
                end
                print(string.format(
                    "[EugenesZombieCure] migrated record-free companion id=%s name=%s",
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
    purgeZombieRecords(zombie:getInventory())
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
        purgeZombieRecords(zombie:getInventory())
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
    elseif args.operation == "reanimate" then
        reanimateCorpse(playerObj, args, directTarget)
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
