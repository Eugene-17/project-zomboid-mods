EugenesZombieCure = EugenesZombieCure or {}

local M = EugenesZombieCure

M.MODULE = "EugenesZombieCure"
M.ITEM_FULL_TYPE = "EugenesZombieCure.ZombieCure"
M.RESTORATION_ITEM_FULL_TYPE = "EugenesZombieCure.RestorationSerum"
M.MAX_DISTANCE_SQUARED = 6.25

local appearanceApplied = {}

function M.isCureItem(item)
    return item and item:getFullType() == M.ITEM_FULL_TYPE
end

function M.isRestorationItem(item)
    return item and item:getFullType() == M.RESTORATION_ITEM_FULL_TYPE
end

function M.isTreatmentItem(item)
    return M.isCureItem(item) or M.isRestorationItem(item)
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

function M.canTreatZombie(playerObj, zombie)
    return M.isProneLivingZombie(zombie)
        and not M.isPacifiedZombie(zombie)
        and M.isCloseEnough(playerObj, zombie)
end

function M.canRestoreZombie(playerObj, zombie)
    return M.isPacifiedZombie(zombie) and M.isCloseEnough(playerObj, zombie)
end

function M.makeZombieArgs(zombie)
    return {
        targetId = zombie:getOnlineID(),
        targetX = math.floor(zombie:getX()),
        targetY = math.floor(zombie:getY()),
        targetZ = math.floor(zombie:getZ()),
    }
end

function M.chooseNormalSkinName(zombie)
    local humanVisual = zombie:getHumanVisual()
    local index = humanVisual:getSkinTextureIndex()
    if index < 0 or index > 4 then index = ZombRand(5) end
    local prefix = zombie:isFemale() and "FemaleBody" or "MaleBody"
    return prefix .. string.format("%02d", index + 1)
end

local function cleanItemVisuals(zombie)
    local visuals = zombie:getItemVisuals()
    local bodyPartCount = BloodBodyPartType.MAX:index()
    for visualIndex = 0, visuals:size() - 1 do
        local visual = visuals:get(visualIndex)
        visual:removeBlood()
        visual:removeDirt()
        for bodyPartIndex = 0, bodyPartCount - 1 do
            visual:removeHole(bodyPartIndex)
        end
    end
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
    appearanceApplied[zombie] = true
end

function M.pacifyZombie(zombie)
    if not zombie or zombie:isDead() then return end
    local data = zombie:getModData()
    data.EugenesZombieCurePacified = true

    if zombie:getTarget() then
        zombie:setTarget(nil)
        zombie:clearAggroList()
        zombie:setTargetSeenTime(0)
    end
    if not zombie:isUseless() then zombie:setUseless(true) end
end

function M.applyZombieCureState(zombie, skinName)
    if not zombie then return end
    local data = zombie:getModData()
    data.EugenesZombieCurePacified = true
    data.EugenesZombieCureSkinName = skinName
    M.cleanZombieAppearance(zombie, skinName)
    M.pacifyZombie(zombie)
end

local function onZombieUpdate(zombie)
    if not zombie or zombie:isDead() then return end
    local data = zombie:getModData()
    if not data.EugenesZombieCurePacified then return end

    M.pacifyZombie(zombie)
    if not appearanceApplied[zombie] and data.EugenesZombieCureSkinName then
        M.cleanZombieAppearance(zombie, data.EugenesZombieCureSkinName)
    end
end

if Events.OnZombieUpdate then
    Events.OnZombieUpdate.Add(onZombieUpdate)
end
