require "ISUI/ISInventoryPane"
require "TimedActions/ISEugenesZombieCureAction"
require "EugenesZombieCure_Shared"
require "BanditsNPCInteract"
require "BanditsNPCCombat"
require "BanditBrain"
require "BanditUtils"

local M = EugenesZombieCure
local pendingPacifiedZombies = {}
local pendingRestoredCompanions = {}
local restoredFondApplied = setmetatable({}, { __mode = "k" })

local function isCureRestoredCompanion(zombie)
    local brain = zombie and BanditBrain.Get(zombie) or nil
    local marker = brain and brain.npcClothVar
        and brain.npcClothVar.__EugenesZombieCure
    return marker and marker.restored == true, brain
end

local function finishRestoredHelpUp(zombie)
    local restored, brain = isCureRestoredCompanion(zombie)
    if not restored then return end

    -- True Companions resumes a downed NPC at 35% health, while its follow
    -- program selects the zombie-like Limp walk below an absolute 0.40 health.
    -- Keep the survivor fragile, but place it just above that animation gate.
    local health = 0
    pcall(function() health = zombie:getHealth() end)
    if health < 0.45 then pcall(function() zombie:setHealth(0.45) end) end

    -- The NPC is an IsoZombie internally. Clear every engine-level prone/crawler
    -- flag once when Help Up succeeds so none of the source animation state can
    -- survive underneath Bandits' human locomotion graph.
    pcall(function() zombie:setCrawler(false) end)
    pcall(function() zombie:setBecomeCrawler(false) end)
    pcall(function() zombie:setCanWalk(true) end)
    pcall(function() zombie:setUseless(false) end)
    pcall(function() zombie:setKnockedDown(false) end)
    pcall(function() zombie:setAlwaysKnockedDown(false) end)
    pcall(function() zombie:setFallOnFront(false) end)
    pcall(function() zombie:setFakeDead(false) end)
    pcall(function() zombie:setForceFakeDead(false) end)
    pcall(function() zombie:setWasFakeDead(false) end)
    pcall(function() zombie:setSitAgainstWall(false) end)
    pcall(function() zombie:setSitOnGround(false) end)
    pcall(function() zombie:setReanimate(false) end)
    pcall(function() zombie:setReanim(false) end)
    pcall(function() zombie:setReanimatedPlayer(false) end)
    pcall(function() zombie:setBumpType("") end)
    pcall(function() zombie:setBumpFall(false) end)
    pcall(function() zombie:setBumpStaggered(false) end)
    pcall(function() zombie:setAnimatingBackwards(false) end)
    pcall(function() zombie:setVariable("BanditWalkType", "Walk") end)
    pcall(function() zombie:setWalkType("Walk") end)
    if Bandit and Bandit.ForceStationary then
        pcall(function() Bandit.ForceStationary(zombie, false) end)
    end
    if ZombieIdleState and ZombieIdleState.instance then
        pcall(function() zombie:changeState(ZombieIdleState.instance()) end)
    end
    M.normalizeRestoredCompanionAnimation(zombie, brain)
end

local function patchTrueCompanionsHelpUp()
    local combat = BanditsNPC and BanditsNPC.Combat
    if not (combat and combat.HelpUp) or M._helpUpPatched then return end
    M._helpUpPatched = true
    local original = combat.HelpUp
    combat.HelpUp = function(zombie)
        local result = original(zombie)
        if result == true then finishRestoredHelpUp(zombie) end
        return result
    end
end

patchTrueCompanionsHelpUp()

local function beginTreatment(playerObj, item, zombie)
    if not playerObj or not M.hasTreatmentItem(playerObj, item) then return end
    ISTimedActionQueue.add(ISEugenesZombieCureAction:new(playerObj, item, zombie))
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    local actualItems = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(actualItems) do
        if M.isCureItem(item) then
            local option = context:addOption(
                getText("ContextMenu_EZC_UseSelf"),
                playerObj,
                beginTreatment,
                item,
                nil
            )
            option.iconTexture = item:getTexture()
            return
        end
    end
end

local function collectZombies(playerObj, worldObjects)
    local result = {}
    local seen = {}
    for _, worldObject in ipairs(worldObjects) do
        local square = worldObject and worldObject:getSquare()
        local movingObjects = square and square:getMovingObjects()
        if movingObjects then
            for index = 0, movingObjects:size() - 1 do
                local zombie = movingObjects:get(index)
                if not seen[zombie]
                    and instanceof(zombie, "IsoZombie")
                    and not zombie:isDead()
                    and M.isCloseEnough(playerObj, zombie) then
                    seen[zombie] = true
                    result[#result + 1] = zombie
                end
            end
        end
    end
    return result
end

local function pickHumanCorpse(playerObj)
    local corpse = IsoObjectPicker.Instance:PickCorpse(getMouseX(), getMouseY())
    if M.canReviveCorpse(playerObj, corpse) then return corpse end
    return nil
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    local cure = playerObj:getInventory():getFirstTypeRecurse(M.ITEM_FULL_TYPE)
    local serum = playerObj:getInventory():getFirstTypeRecurse(M.RESTORATION_ITEM_FULL_TYPE)
    local stimulant = playerObj:getInventory():getFirstTypeRecurse(M.REANIMATION_ITEM_FULL_TYPE)
    if not cure and not serum and not stimulant then return end
    local zombies = collectZombies(playerObj, worldObjects)
    local corpse = stimulant and pickHumanCorpse(playerObj) or nil
    if #zombies == 0 and not corpse then return end
    if test then return ISWorldObjectContextMenu.setTest() end

    if corpse then
        local option = context:addOption(
            getText("ContextMenu_EZC_ReanimateCorpse"),
            playerObj,
            beginTreatment,
            stimulant,
            corpse
        )
        option.iconTexture = stimulant:getTexture()
    end

    for _, zombie in ipairs(zombies) do
        if serum and M.canRestoreZombie(playerObj, zombie) then
            local option = context:addOption(
                getText("ContextMenu_EZC_RestoreZombie"),
                playerObj,
                beginTreatment,
                serum,
                zombie
            )
            option.iconTexture = serum:getTexture()
        elseif cure and M.canTreatZombie(playerObj, zombie) then
            local option = context:addOption(
                getText("ContextMenu_EZC_UseZombie"),
                playerObj,
                beginTreatment,
                cure,
                zombie
            )
            option.iconTexture = cure:getTexture()
        end
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

local function findRecruitTarget(args)
    local targetId = tonumber(args.targetId)
    local persistentId = tonumber(args.targetPersistentId)
    local zombies = getCell():getZombieList()

    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        local idMatches = targetId and targetId >= 0
            and zombie:getOnlineID() == targetId
        local persistentMatches = persistentId
            and zombie:getPersistentOutfitID() == persistentId
        local brain = BanditBrain.Get(zombie)
        local keyMatches = args.key and brain and brain.key == args.key
        if idMatches or persistentMatches or keyMatches then
            return zombie, brain
        end
    end
    return nil, nil
end

local function reportRecruitResult(command, args)
    if not isClient() then return end
    local playerObj = getPlayer()
    if playerObj then sendClientCommand(playerObj, M.MODULE, command, args) end
end

function M.recruitWithTrueCompanions(args, directTarget)
    args = args or {}
    local targetId = tonumber(args.targetId)
    local zombie, brain
    if directTarget then
        zombie = directTarget
        brain = BanditBrain.Get(zombie)
    else
        zombie, brain = findRecruitTarget(args)
    end
    if not zombie or not brain or (args.key and brain.key ~= args.key)
        or not zombie:getVariableBoolean("Bandit") then
        print(string.format(
            "[EugenesZombieCure] True Companions recruit target mismatch: targetId=%s zombie=%s brain=%s expectedKey=%s actualKey=%s",
            tostring(targetId),
            tostring(zombie ~= nil),
            tostring(brain ~= nil),
            tostring(args.key),
            tostring(brain and brain.key)
        ))
        reportRecruitResult("trueCompanionRecruitResult", {
            key = args.key,
            ok = false,
            reason = not zombie and "target-not-replicated"
                or (not brain and "brain-not-replicated"
                or ((args.key and brain.key ~= args.key) and "key-not-replicated"
                or "bandit-initializing")),
        })
        return false
    end

    local ok, result = pcall(BanditsNPC.Interact.Recruit, zombie)
    local recruited = ok and result == true
    if recruited then
        -- Recruit() normally activates NPCCompanion immediately. Hold the new
        -- recruit in True Companions' supported downed state during the one-tick
        -- handoff so it cannot target the source zombie before the server copies
        -- the inventory and removes that zombie.
        brain = BanditBrain.Get(zombie) or brain
        brain.downed = true
        brain.downedPosed = nil
        brain.tasks = {}
        brain.prevProgram = { name = "NPCCompanion", stage = "Prepare" }
        brain.program = { name = "NPCDowned", stage = "Prepare" }
        BanditBrain.Update(zombie, brain)
        if Bandit and Bandit.ForceStationary then
            pcall(function() Bandit.ForceStationary(zombie, true) end)
        end
        if Bandit and Bandit.ForceSyncPart then
            pcall(function()
                Bandit.ForceSyncPart(zombie, {
                    id = brain.id,
                    downed = true,
                    prevProgram = brain.prevProgram,
                    program = brain.program,
                    tasks = brain.tasks,
                })
            end)
        end
    else
        print("[EugenesZombieCure] True Companions recruit call failed: "
            .. tostring(ok and "rejected" or result))
    end
    reportRecruitResult("trueCompanionRecruitResult", {
        key = args.key,
        ok = recruited,
        reason = not recruited
            and (ok and "recruit-rejected" or tostring(result)) or nil,
    })
    return recruited
end

local function onServerCommand(module, command, args)
    if module ~= M.MODULE or not args then return end
    if command == "zombieCured" then
        local targetId = tonumber(args.targetId)
        local zombie = findZombieByOnlineId(targetId)
        if zombie and args.skinName then
            M.applyZombieCureState(zombie, args.skinName)
        elseif targetId and args.skinName then
            pendingPacifiedZombies[targetId] = args.skinName
        end
    elseif command == "recruitTrueCompanion" then
        M.recruitWithTrueCompanions(args)
    elseif command == "configureRestoredCompanion" then
        local companion = findRecruitTarget(args)
        if companion and companion:getVariableBoolean("Bandit")
            and M.configureRestoredCompanion(companion, args.snapshot) then
            pendingRestoredCompanions[args.key] = nil
        elseif args.key then
            pendingRestoredCompanions[args.key] = args
        end
    elseif command == "result" and args.message then
        local playerObj = getPlayer()
        if playerObj then
            playerObj:setHaloNote(args.message, 255, args.ok and 255 or 80, args.ok and 255 or 80, 300)
        end
    end
end

local function applyPendingRestoredCompanion(zombie)
    if not zombie or not zombie:getVariableBoolean("Bandit") then return end
    local targetId = zombie:getOnlineID()
    local persistentId = zombie:getPersistentOutfitID()
    local brain = BanditBrain.Get(zombie)
    for key, args in pairs(pendingRestoredCompanions) do
        if (tonumber(args.targetId) == targetId)
            or (tonumber(args.targetPersistentId) == persistentId)
            or (brain and brain.key == key) then
            if M.configureRestoredCompanion(zombie, args.snapshot) then
                pendingRestoredCompanions[key] = nil
            end
            return
        end
    end
end

local function maintainRestoredFond(zombie)
    if not zombie or restoredFondApplied[zombie] then return end
    local brain = BanditBrain.Get(zombie)
    local marker = brain and brain.npcClothVar
        and brain.npcClothVar.__EugenesZombieCure
    if not (marker and marker.fond) then return end
    restoredFondApplied[zombie] = true
    if brain.npcRomance == true
        and (brain.affinity or 0) >= M.RESTORED_COMPANION_AFFINITY then
        return
    end
    brain.npcRomance = true
    brain.affinity = math.max(
        brain.affinity or 0,
        M.RESTORED_COMPANION_AFFINITY
    )
    brain.affinityTier = math.max(brain.affinityTier or 0, 1)
    BanditBrain.Update(zombie, brain)
    if Bandit and Bandit.ForceSyncPart then
        pcall(function()
            Bandit.ForceSyncPart(zombie, {
                id = brain.id,
                npcRomance = true,
                affinity = brain.affinity,
                affinityTier = brain.affinityTier,
            })
        end)
    end
end

local function applyPendingPacification(zombie)
    if not zombie then return end
    local targetId = zombie:getOnlineID()
    local skinName = pendingPacifiedZombies[targetId]
    if not skinName then return end
    pendingPacifiedZombies[targetId] = nil
    M.applyZombieCureState(zombie, skinName)
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnServerCommand.Add(onServerCommand)
Events.OnZombieUpdate.Add(applyPendingPacification)
Events.OnZombieUpdate.Add(applyPendingRestoredCompanion)
Events.OnZombieUpdate.Add(maintainRestoredFond)
