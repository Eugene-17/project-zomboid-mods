require "EugenesProneEquipment_Shared"

EugenesZombieCure = EugenesZombieCure or {}

local M = EugenesZombieCure
local EPE = EugenesProneEquipment

M.MODULE = "EugenesZombieCure"
M.ITEM_FULL_TYPE = "EugenesZombieCure.ZombieCure"
M.RESTORATION_ITEM_FULL_TYPE = "EugenesZombieCure.RestorationSerum"
M.REANIMATION_ITEM_FULL_TYPE = "EugenesZombieCure.ReanimationStimulant"
M.MAX_DISTANCE_SQUARED = 6.25
M.PACIFICATION_SCHEMA_VERSION = 2
M.PACIFICATION_MARKER_CHECK_INTERVAL = 120
M.RESTORED_COMPANION_AFFINITY = 25

local pacifiedThisSession = setmetatable({}, { __mode = "k" })
local pacifiedAppearanceApplied = setmetatable({}, { __mode = "k" })
local pacifiedRecordApplied = setmetatable({}, { __mode = "k" })
local pacificationInventoryChecked = setmetatable({}, { __mode = "k" })
local pacificationMarkerTicks = setmetatable({}, { __mode = "k" })

function M.isCureItem(item)
    return item and item:getFullType() == M.ITEM_FULL_TYPE
end

function M.findPacifyingCure(zombie)
    local inventory = zombie and zombie:getInventory() or nil
    return inventory and inventory:getFirstTypeRecurse(M.ITEM_FULL_TYPE) or nil
end

function M.hasPacifyingCure(zombie)
    return M.findPacifyingCure(zombie) ~= nil
end

function M.isRestorationItem(item)
    return item and item:getFullType() == M.RESTORATION_ITEM_FULL_TYPE
end

function M.isReanimationItem(item)
    return item and item:getFullType() == M.REANIMATION_ITEM_FULL_TYPE
end

function M.isTreatmentItem(item)
    return M.isCureItem(item) or M.isRestorationItem(item) or M.isReanimationItem(item)
end

function M.hasCure(playerObj, item)
    return playerObj
        and M.isCureItem(item)
        and playerObj:getInventory():containsRecursive(item)
end

function M.hasTreatmentItem(playerObj, item)
    return playerObj
        and M.isTreatmentItem(item)
        and playerObj:getInventory():containsRecursive(item)
end

function M.isPacifiedZombie(zombie)
    return zombie
        and instanceof(zombie, "IsoZombie")
        and not zombie:isDead()
        and zombie:getModData().EugenesZombieCurePacified == true
        and pacifiedThisSession[zombie] == true
end

function M.isProneLivingZombie(zombie)
    return zombie
        and instanceof(zombie, "IsoZombie")
        and not zombie:isDead()
        and (zombie:isKnockedDown() or zombie:isOnFloor() or zombie:isProne())
end

function M.isCloseEnough(playerObj, zombie)
    if not playerObj or not zombie then return false end
    if math.floor(playerObj:getZ()) ~= math.floor(zombie:getZ()) then return false end
    local dx = playerObj:getX() - zombie:getX()
    local dy = playerObj:getY() - zombie:getY()
    return dx * dx + dy * dy <= M.MAX_DISTANCE_SQUARED
end

function M.isHumanCorpse(corpse)
    return corpse
        and instanceof(corpse, "IsoDeadBody")
        and not corpse:isAnimal()
        and corpse:getSquare() ~= nil
        and corpse:getStaticMovingObjectIndex() >= 0
end

function M.canReviveCorpse(playerObj, corpse)
    return M.isHumanCorpse(corpse) and M.isCloseEnough(playerObj, corpse)
end

function M.canTreatZombie(playerObj, zombie)
    return M.isProneLivingZombie(zombie)
        and not EPE.isBanditTarget(zombie)
        and not M.isPacifiedZombie(zombie)
        and M.isCloseEnough(playerObj, zombie)
end

function M.canRestoreZombie(playerObj, zombie)
    return not EPE.isBanditTarget(zombie)
        and M.isPacifiedZombie(zombie)
        and M.isCloseEnough(playerObj, zombie)
end

function M.makeZombieArgs(zombie)
    return {
        targetId = zombie:getOnlineID(),
        targetX = math.floor(zombie:getX()),
        targetY = math.floor(zombie:getY()),
        targetZ = math.floor(zombie:getZ()),
    }
end

function M.makeCorpseArgs(corpse)
    return {
        targetX = math.floor(corpse:getX()),
        targetY = math.floor(corpse:getY()),
        targetZ = math.floor(corpse:getZ()),
        targetIndex = corpse:getStaticMovingObjectIndex(),
    }
end

local function restoredItemLook(row)
    local look = {}
    local hasLook = false
    if row.baseTexture ~= nil then look.bt = row.baseTexture; hasLook = true end
    if row.textureChoice ~= nil then look.tc = row.textureChoice; hasLook = true end
    if row.hue ~= nil then look.hue = row.hue; hasLook = true end
    if row.tint then
        look.tr = row.tint.r
        look.tg = row.tint.g
        look.tb = row.tint.b
        hasLook = true
    end
    return hasLook and look or nil
end

local function restoredItemInfo(row)
    local item
    pcall(function() item = instanceItem(row.fullType) end)
    if not item then return nil, nil, false end
    local location = row.location or EPE.getWearLocation(item)
    local isBag = false
    pcall(function()
        isBag = item.IsInventoryContainer and item:IsInventoryContainer()
    end)
    return item, location and tostring(location) or nil, isBag == true
end

local function restoredSkinIndex(skinTextureName)
    if type(skinTextureName) ~= "string" then return nil end
    local index = tonumber(string.match(skinTextureName, "Body0?(%d+)"))
    if index and index >= 1 and index <= 5 then return index end
    return nil
end

local function normalRestoredSkinName(appearance, brain)
    local female = appearance.female == true
    local index = restoredSkinIndex(appearance.skinTextureName)
        or tonumber(brain and brain.skin)
        or 1
    index = math.max(1, math.min(5, math.floor(index)))
    if Bandit and Bandit.GetSkinTexture then
        return Bandit.GetSkinTexture(female, index)
    end
    return (female and "FemaleBody0" or "MaleBody0") .. tostring(index)
end

local function cleanRestoredCompanionDamage(companion)
    if not companion then return end
    EPE.cleanZombieVisualDamage(companion)
    local humanVisual = companion:getHumanVisual()
    if not humanVisual then return end
    humanVisual:removeBlood()
    humanVisual:removeDirt()
    humanVisual:getBodyVisuals():clear()
    local maxIndex = BloodBodyPartType.MAX:index()
    for index = 0, maxIndex - 1 do
        local part = BloodBodyPartType.FromIndex(index)
        pcall(function() humanVisual:setBlood(part, 0) end)
        pcall(function() humanVisual:setDirt(part, 0) end)
    end
end

function M.normalizeRestoredCompanionAnimation(companion, brain)
    if not companion then return false end
    brain = brain or (BanditBrain and BanditBrain.Get(companion))
    if not brain then return false end

    -- Never set the Bandit flag here. BanditUpdate uses a false flag to run its
    -- complete Banditize initialization; setting it ourselves would skip that
    -- transition and leave the IsoZombie on its original locomotion graph.
    pcall(function() companion:setNoTeeth(true) end)
    pcall(function() companion:setVariable("BanditWalkType", "Walk") end)
    pcall(function() companion:setWalkType("Walk") end)
    pcall(function() companion:setVariable("LimpSpeed", 0.80) end)
    pcall(function() companion:setVariable("RunSpeed", 0.68) end)
    pcall(function() companion:setVariable("WalkSpeed", 1.00) end)
    pcall(function() companion:setVariable("ZombieHitReaction", "Chainsaw") end)
    pcall(function() companion:setVariable("NoLungeTarget", true) end)
    pcall(function() companion:setAnimatingBackwards(false) end)

    local data = companion:getModData()
    data.brainId = brain.id
    data.isDeadBandit = false
    if brain.downed ~= true then
        pcall(function() companion:setUseless(false) end)
        pcall(function() companion:setCanWalk(true) end)
    end
    return true
end

function M.configureRestoredCompanion(
    companion, snapshot, deferPersistence, suppliedBrain)
    if not companion or type(snapshot) ~= "table" or not BanditBrain then return false end
    -- A dedicated server owns the authoritative cluster brain before it is
    -- attached to the client IsoZombie. Accept that authoritative table from
    -- the restoration flow while keeping the normal client lookup unchanged.
    local brain = suppliedBrain or BanditBrain.Get(companion)
    if not brain then return false end
    local appearance = snapshot.appearance or {}

    -- Keep identity features, but never copy the zombie body's decayed skin
    -- tint. A normal skin texture plus an empty body-visual list removes rot,
    -- wounds, scars, bites, scratches, blood, dirt, and holes.
    appearance.skinTextureName = normalRestoredSkinName(appearance, brain)
    appearance.skinColor = nil

    if appearance.female ~= nil then brain.female = appearance.female == true end
    brain.skin = restoredSkinIndex(appearance.skinTextureName) or brain.skin
    brain.hairStyle = appearance.hairModel or ""
    brain.beardStyle = appearance.beardModel or ""
    brain.hairType = false
    brain.beardType = false
    brain.tcHairColor = appearance.hairColor
    brain.tcBeardColor = appearance.beardColor

    brain.clothing = {}
    brain.tint = {}
    brain.npcClothVar = {}
    brain.bag = false
    for _, row in ipairs(snapshot.worn or {}) do
        if row.fullType then
            local _, location, isBag = restoredItemInfo(row)
            if isBag then
                brain.bag = { name = row.fullType }
            elseif location then
                brain.clothing[location] = row.fullType
            end
            local look = restoredItemLook(row)
            if look then brain.npcClothVar[row.fullType] = look end
        end
    end
    -- This harmless entry travels with True Companions' persisted clothing data and
    -- documents why this otherwise ordinary companion starts on the romance track.
    brain.npcClothVar.__EugenesZombieCure = { restored = true, fond = true }

    brain.weapons = {
        melee = "Base.BareHands",
        primary = { bulletsLeft = 0, magCount = 0 },
        secondary = { bulletsLeft = 0, magCount = 0 },
    }
    brain.npcMelee = "Base.BareHands"
    brain.npcMeleeState = nil
    brain.npcItems = nil
    brain.inventory = {}
    brain.loot = {}

    -- "Fond" is romance tier 1 in True Companions: affinity 25 with the romance
    -- track explicitly selected. Starting downed uses its supported Help Up flow.
    brain.affinity = M.RESTORED_COMPANION_AFFINITY
    brain.affinityTier = 1
    brain.npcRomance = true
    brain.partner = nil
    brain.downed = true
    brain.downedPosed = nil
    brain.tasks = {}
    brain.prevProgram = { name = "NPCCompanion", stage = "Prepare" }
    brain.program = { name = "NPCDowned", stage = "Prepare" }
    BanditBrain.Update(companion, brain)

    pcall(function() companion:getEmitter():stopAll() end)
    pcall(function() companion:setHealth(math.max(0.1, (brain.health or 1) * 0.12)) end)
    pcall(function()
        companion:setPrimaryHandItem(nil)
        companion:setSecondaryHandItem(nil)
        local attached = companion:getAttachedItems()
        for index = attached:size() - 1, 0, -1 do
            local item = attached:get(index):getItem()
            if item then companion:removeAttachedItem(item) end
        end
    end)
    if Bandit and Bandit.SetHands then
        pcall(function() Bandit.SetHands(companion, "Base.BareHands") end)
    end
    if BanditsNPC and BanditsNPC.Interact
        and BanditsNPC.Interact.ApplyClothingVisuals then
        pcall(function()
            BanditsNPC.Interact.ApplyClothingVisuals(companion, brain)
        end)
    end
    pcall(function()
        EPE.applyZombieAppearanceSnapshot(companion, appearance, false)
        cleanRestoredCompanionDamage(companion)
        companion:resetModelNextFrame()
    end)
    M.normalizeRestoredCompanionAnimation(companion, brain)

    if not isServer() and Bandit and Bandit.ForceSyncPart then
        pcall(function()
            Bandit.ForceSyncPart(companion, {
                id = brain.id,
                female = brain.female,
                skin = brain.skin,
                hairStyle = brain.hairStyle,
                beardStyle = brain.beardStyle,
                hairType = brain.hairType,
                beardType = brain.beardType,
                tcHairColor = brain.tcHairColor,
                tcBeardColor = brain.tcBeardColor,
                clothing = brain.clothing,
                tint = brain.tint,
                npcClothVar = brain.npcClothVar,
                bag = brain.bag,
                weapons = brain.weapons,
                npcMelee = brain.npcMelee,
                affinity = brain.affinity,
                affinityTier = brain.affinityTier,
                npcRomance = brain.npcRomance,
                partner = false,
                downed = brain.downed,
                prevProgram = brain.prevProgram,
                program = brain.program,
            })
        end)
    end
    if not deferPersistence and BanditsNPC and BanditsNPC.Persistence
        and BanditsNPC.Persistence.Record then
        pcall(function() BanditsNPC.Persistence.Record(companion, brain) end)
    end
    return true
end

function M.chooseNormalSkinName(zombie)
    local humanVisual = zombie:getHumanVisual()
    local index = humanVisual:getSkinTextureIndex()
    if index < 0 or index > 4 then index = ZombRand(5) end
    local prefix = zombie:isFemale() and "FemaleBody" or "MaleBody"
    return prefix .. string.format("%02d", index + 1)
end

local function cleanItemVisuals(zombie)
    EPE.cleanZombieVisualDamage(zombie)
end

function M.cleanZombieAppearance(zombie, skinName)
    if not zombie then return end
    local humanVisual = zombie:getHumanVisual()
    local outfit = humanVisual:getOutfit()
    local skinColor = humanVisual:getSkinColor()
    local bodyHair = humanVisual:getBodyHairIndex()
    local hairModel = humanVisual:getHairModel()
    local beardModel = humanVisual:getBeardModel()
    local hairColor = humanVisual:getHairColor()
    local beardColor = humanVisual:getBeardColor()
    local naturalHairColor = humanVisual:getNaturalHairColor()
    local naturalBeardColor = humanVisual:getNaturalBeardColor()
    local nonAttachedHair = humanVisual:getNonAttachedHair()

    humanVisual:clear()
    if outfit then humanVisual:setOutfit(outfit) end
    if skinColor then humanVisual:setSkinColor(skinColor) end
    if bodyHair and bodyHair >= 0 then humanVisual:setBodyHairIndex(bodyHair) end
    if hairModel then humanVisual:setHairModel(hairModel) end
    if beardModel then humanVisual:setBeardModel(beardModel) end
    if hairColor then humanVisual:setHairColor(hairColor) end
    if beardColor then humanVisual:setBeardColor(beardColor) end
    if naturalHairColor then humanVisual:setNaturalHairColor(naturalHairColor) end
    if naturalBeardColor then humanVisual:setNaturalBeardColor(naturalBeardColor) end
    if nonAttachedHair then humanVisual:setNonAttachedHair(nonAttachedHair) end
    humanVisual:setSkinTextureName(skinName)
    humanVisual:removeBlood()
    humanVisual:removeDirt()
    humanVisual:getBodyVisuals():clear()
    cleanItemVisuals(zombie)
    zombie:resetModelNextFrame()
    pacifiedAppearanceApplied[zombie] = true
end

function M.pacifyZombie(zombie)
    if not zombie or zombie:isDead() then return end
    pacifiedThisSession[zombie] = true
    zombie:getModData().EugenesZombieCurePacified = true
    zombie:setTarget(nil)
    zombie:clearAggroList()
    zombie:setTargetSeenTime(0)
    zombie:setUseless(true)
    if zombie.setNoTeeth then zombie:setNoTeeth(true) end
    if zombie.setCanWalk then zombie:setCanWalk(false) end
end

function M.applyZombieCureState(zombie, skinName)
    if not zombie then return end
    local data = zombie:getModData()
    data.EugenesZombieCurePacified = true
    data.EugenesZombieCureSkinName = skinName
    data.EugenesZombieCureMarkerVersion = M.PACIFICATION_SCHEMA_VERSION
    pacificationInventoryChecked[zombie] = true
    pacificationMarkerTicks[zombie] = 0
    M.cleanZombieAppearance(zombie, skinName)
    M.pacifyZombie(zombie)
end

function M.clearPacifiedZombieState(zombie)
    if not zombie then return end
    pacifiedThisSession[zombie] = nil
    pacifiedAppearanceApplied[zombie] = nil
    pacifiedRecordApplied[zombie] = nil
    pacificationInventoryChecked[zombie] = true
    pacificationMarkerTicks[zombie] = nil
    local data = zombie:getModData()
    data.EugenesZombieCurePacified = nil
    data.EugenesZombieCureSkinName = nil
    data.EugenesZombieCureMarkerVersion = nil
end

local function restoreZombieMovement(zombie)
    zombie:setUseless(false)
    if zombie.setCanWalk then zombie:setCanWalk(true) end
    if zombie.setNoTeeth then zombie:setNoTeeth(false) end
end

local function addLegacyPacificationMarker(zombie)
    local inventory = zombie and zombie:getInventory() or nil
    if not inventory then return nil end
    local cure = inventory:AddItem(M.ITEM_FULL_TYPE)
    if cure and isServer() then sendAddItemToContainer(inventory, cure) end
    return cure
end

local function restorePacificationFromInventory(zombie, data)
    local cure = M.findPacifyingCure(zombie)
    if not cure and data.EugenesZombieCurePacified == true
        and data.EugenesZombieCureMarkerVersion ~= M.PACIFICATION_SCHEMA_VERSION
        and not isClient() then
        -- Old saves consumed the cure and retained only zombie mod data. Give
        -- each such zombie one marker item so it enters the new stable model.
        cure = addLegacyPacificationMarker(zombie)
    end

    if cure then
        local skinName = data.EugenesZombieCureSkinName
            or M.chooseNormalSkinName(zombie)
        M.applyZombieCureState(zombie, skinName)
        if zombie.transmitModData and isServer() then
            pcall(zombie.transmitModData, zombie)
        end
        return true
    end

    if isClient() and data.EugenesZombieCurePacified == true then
        -- Zombie inventory replication can arrive after mod data. Trust the
        -- server-side state rather than briefly making the zombie hostile.
        local skinName = data.EugenesZombieCureSkinName
            or M.chooseNormalSkinName(zombie)
        M.applyZombieCureState(zombie, skinName)
        return true
    end

    if data.EugenesZombieCurePacified == true then
        M.clearPacifiedZombieState(zombie)
        restoreZombieMovement(zombie)
        if zombie.transmitModData and isServer() then
            pcall(zombie.transmitModData, zombie)
        end
    end
    return false
end

local function onZombieUpdate(zombie)
    if not zombie or zombie:isDead() then return end
    local data = zombie:getModData()

    -- Scan every loaded zombie once. Only the few pacified zombies receive a
    -- cheap periodic recheck, avoiding a recursive inventory scan every frame.
    if pacificationInventoryChecked[zombie] ~= true then
        pacificationInventoryChecked[zombie] = true
        if not restorePacificationFromInventory(zombie, data) then return end
    end

    if pacifiedThisSession[zombie] ~= true then return end

    if not isClient() then
        local ticks = (pacificationMarkerTicks[zombie] or 0) + 1
        if ticks >= M.PACIFICATION_MARKER_CHECK_INTERVAL then
            ticks = 0
            if not M.hasPacifyingCure(zombie) then
                M.clearPacifiedZombieState(zombie)
                restoreZombieMovement(zombie)
                if zombie.transmitModData and isServer() then
                    pcall(zombie.transmitModData, zombie)
                end
                return
            end
        end
        pacificationMarkerTicks[zombie] = ticks
    end

    M.pacifyZombie(zombie)
    local record = EPE.findZombieRecord(zombie:getInventory())
    local snapshot = EPE.getZombieRecordSnapshot(record)
    local equipmentMatches = snapshot and EPE.zombieEquipmentMatchesSnapshot(zombie, snapshot)
    local hasVisualDamage = EPE.hasZombieVisualDamage(zombie)
    if record and (not pacifiedRecordApplied[zombie] or not equipmentMatches
        or hasVisualDamage)
        and EPE.applyZombieRecord(zombie, record, false) then
        pacifiedRecordApplied[zombie] = true
        pacifiedAppearanceApplied[zombie] = true
    elseif data.EugenesZombieCureSkinName and (not pacifiedAppearanceApplied[zombie]
        or hasVisualDamage) then
        M.cleanZombieAppearance(zombie, data.EugenesZombieCureSkinName)
    end
end

if Events.OnZombieUpdate then
    Events.OnZombieUpdate.Add(onZombieUpdate)
end
