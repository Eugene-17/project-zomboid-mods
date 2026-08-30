EugenesProneEquipment = EugenesProneEquipment or {}

local M = EugenesProneEquipment

M.MODULE = "EugenesProneEquipment"
M.MAX_DISTANCE_SQUARED = 6.25
M.CARRIER_FULL_TYPE = "EugenesProneEquipment.PacifiedZombieCarrier"

function M.getWearLocation(item)
    if not item then return nil end

    local location = item:canBeEquipped()
    if location and tostring(location) ~= "" then
        return location
    end

    location = item:getBodyLocation()
    if location and tostring(location) ~= "" then
        return location
    end

    return nil
end

function M.isLooseWearable(playerObj, item)
    if not playerObj or not item or item:isBroken() then return false end
    if not playerObj:getInventory():containsRecursive(item) then return false end
    if playerObj:getPrimaryHandItem() == item then return false end
    if playerObj:getSecondaryHandItem() == item then return false end
    if playerObj:getWornItems():contains(item) then return false end
    if playerObj:isAttachedItem(item) then return false end
    return M.getWearLocation(item) ~= nil
end

function M.isProneLivingTarget(playerObj, target)
    if not playerObj or not target or playerObj == target then return false end
    if not (instanceof(target, "IsoZombie") or instanceof(target, "IsoPlayer")) then return false end
    if target:isDead() then return false end
    if target:isKnockedDown() then return true end
    if target:isOnFloor() then return true end
    return target:isProne()
end

function M.isCloseEnough(playerObj, target)
    if not playerObj or not target then return false end
    if math.floor(playerObj:getZ()) ~= math.floor(target:getZ()) then return false end
    local dx = playerObj:getX() - target:getX()
    local dy = playerObj:getY() - target:getY()
    return dx * dx + dy * dy <= M.MAX_DISTANCE_SQUARED
end

function M.canInteract(playerObj, target)
    return M.isProneLivingTarget(playerObj, target) and M.isCloseEnough(playerObj, target)
end

function M.isPacifiedZombie(target)
    return target
        and instanceof(target, "IsoZombie")
        and not target:isDead()
        and target:getModData().EugenesZombieCurePacified == true
end

function M.canCarryZombie(playerObj, target)
    return M.isPacifiedZombie(target) and M.isCloseEnough(playerObj, target)
end

function M.isZombieCarrier(item)
    return item
        and item:getFullType() == M.CARRIER_FULL_TYPE
        and item:getModData().EugenesProneEquipmentHasZombie == true
end

function M.hasZombieCarrier(playerObj, item)
    return playerObj
        and M.isZombieCarrier(item)
        and playerObj:getInventory():containsRecursive(item)
end

function M.getTargetKind(target)
    if instanceof(target, "IsoZombie") then return "zombie" end
    if instanceof(target, "IsoPlayer") then return "player" end
    return nil
end

function M.getTargetName(target)
    if instanceof(target, "IsoZombie") then return "Zombie" end
    local name = target:getDisplayName()
    if not name or name == "" then name = target:getUsername() end
    return name or "Player"
end

function M.makeTargetArgs(target)
    return {
        targetKind = M.getTargetKind(target),
        targetId = target:getOnlineID(),
        targetX = math.floor(target:getX()),
        targetY = math.floor(target:getY()),
        targetZ = math.floor(target:getZ()),
    }
end

function M.findWornItem(target, locationText, fullType)
    if not target or not locationText then return nil end
    local wornItems = target:getWornItems()
    for index = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(index)
        local location = wornItems:getLocation(item)
        if location and tostring(location) == tostring(locationText)
            and (not fullType or item:getFullType() == fullType)
        then
            return item
        end
    end
    return nil
end
