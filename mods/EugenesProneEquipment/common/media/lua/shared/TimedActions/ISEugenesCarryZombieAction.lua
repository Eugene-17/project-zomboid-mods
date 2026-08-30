require "TimedActions/ISBaseTimedAction"
require "EugenesProneEquipment_Shared"

ISEugenesCarryZombieAction = ISBaseTimedAction:derive("ISEugenesCarryZombieAction")

local M = EugenesProneEquipment

function ISEugenesCarryZombieAction:isValid()
    if self.operation == "pickup" then
        return M.canCarryZombie(self.character, self.zombie)
    end
    return M.hasZombieCarrier(self.character, self.carrier)
end

function ISEugenesCarryZombieAction:waitToStart()
    if self.zombie then
        self.character:faceLocation(self.zombie:getX(), self.zombie:getY())
    end
    return self.character:isTurning() or self.character:shouldBeTurning()
end

function ISEugenesCarryZombieAction:update()
    if self.zombie then
        self.character:faceLocation(self.zombie:getX(), self.zombie:getY())
    end
    self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
end

function ISEugenesCarryZombieAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.sound = self.character:playSound("RummageInInventory")
end

function ISEugenesCarryZombieAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function ISEugenesCarryZombieAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.perform(self)
end

function ISEugenesCarryZombieAction:complete()
    if not self:isValid() then return false end

    local args = { operation = self.operation }
    if self.operation == "pickup" then
        args = M.makeTargetArgs(self.zombie)
        args.operation = "pickup"
    else
        args.itemId = self.carrier:getID()
        local square = self.dropSquare or self.character:getSquare()
        args.targetX = square:getX()
        args.targetY = square:getY()
        args.targetZ = square:getZ()
    end

    if isClient() then
        sendClientCommand(self.character, M.MODULE, "carryZombie", args)
    elseif M.handleCarryRequest then
        M.handleCarryRequest(self.character, args, self.zombie)
    end
    return true
end

function ISEugenesCarryZombieAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    if self.operation == "pickup" then return 160 end
    return 120
end

function ISEugenesCarryZombieAction:new(character, operation, zombie, carrier, dropSquare)
    local o = ISBaseTimedAction.new(self, character)
    o.operation = operation
    o.zombie = zombie
    o.carrier = carrier
    o.dropSquare = dropSquare
    o.maxTime = o:getDuration()
    o.stopOnWalk = true
    o.stopOnRun = true
    o.fromHotbar = true
    return o
end
