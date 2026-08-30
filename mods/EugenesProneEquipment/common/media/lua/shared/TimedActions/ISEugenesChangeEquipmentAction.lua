require "TimedActions/ISBaseTimedAction"
require "EugenesProneEquipment_Shared"

ISEugenesChangeEquipmentAction = ISBaseTimedAction:derive("ISEugenesChangeEquipmentAction")

local M = EugenesProneEquipment

function ISEugenesChangeEquipmentAction:isValid()
    if not M.canInteract(self.character, self.target) then return false end
    if self.operation == "wear" then
        return M.isLooseWearable(self.character, self.item)
    end
    return true
end

function ISEugenesChangeEquipmentAction:waitToStart()
    self.character:faceLocation(self.target:getX(), self.target:getY())
    return self.character:isTurning() or self.character:shouldBeTurning()
end

function ISEugenesChangeEquipmentAction:update()
    self.character:faceLocation(self.target:getX(), self.target:getY())
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function ISEugenesChangeEquipmentAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.sound = self.character:playSound("RummageInInventory")
end

function ISEugenesChangeEquipmentAction:stop()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function ISEugenesChangeEquipmentAction:perform()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.perform(self)
end

function ISEugenesChangeEquipmentAction:complete()
    if not self:isValid() then return false end

    local args = M.makeTargetArgs(self.target)
    args.operation = self.operation
    if self.operation == "wear" then
        args.itemId = self.item:getID()
    else
        args.location = self.location
        args.fullType = self.fullType
    end

    if isClient() then
        sendClientCommand(self.character, M.MODULE, "changeEquipment", args)
    elseif M.handleRequest then
        M.handleRequest(self.character, args, self.target)
    end
    return true
end

function ISEugenesChangeEquipmentAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 80
end

function ISEugenesChangeEquipmentAction:new(character, target, operation, item, location, fullType)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.operation = operation
    o.item = item
    o.location = location
    o.fullType = fullType
    o.maxTime = o:getDuration()
    o.stopOnWalk = true
    o.stopOnRun = true
    o.fromHotbar = true
    return o
end
