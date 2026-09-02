require "TimedActions/ISBaseTimedAction"
require "EugenesZombieCure_Shared"

ISEugenesZombieCureAction = ISBaseTimedAction:derive("ISEugenesZombieCureAction")

local M = EugenesZombieCure

function ISEugenesZombieCureAction:isValid()
    if not M.hasTreatmentItem(self.character, self.item) then return false end
    if M.isReanimationItem(self.item) then
        return self.target and M.canReviveCorpse(self.character, self.target)
    end
    if M.isRestorationItem(self.item) then
        return self.target and M.canRestoreZombie(self.character, self.target)
    end
    if self.target then return M.canTreatZombie(self.character, self.target) end
    return M.isCureItem(self.item)
end

function ISEugenesZombieCureAction:waitToStart()
    if not self.target then return false end
    self.character:faceLocation(self.target:getX(), self.target:getY())
    return self.character:isTurning() or self.character:shouldBeTurning()
end

function ISEugenesZombieCureAction:update()
    self.item:setJobDelta(self:getJobDelta())
    if self.target then self.character:faceLocation(self.target:getX(), self.target:getY()) end
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function ISEugenesZombieCureAction:start()
    local jobText
    if M.isReanimationItem(self.item) then
        jobText = getText("ContextMenu_EZC_ReanimateCorpse")
    elseif M.isRestorationItem(self.item) then
        jobText = getText("ContextMenu_EZC_RestoreZombie")
    else
        jobText = self.target and getText("ContextMenu_EZC_UseZombie") or getText("ContextMenu_EZC_UseSelf")
    end
    self.item:setJobType(jobText)
    self.item:setJobDelta(0.0)
    if self.target then
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Low")
    else
        self:setActionAnim(CharacterActionAnims.Bandage)
        self.character:reportEvent("EventBandage")
    end
    self:setOverrideHandModels(nil, self.item)
    self.sound = self.character:playSound("FirstAidApplyBandage")
end

function ISEugenesZombieCureAction:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopSound(self.sound)
    end
end

function ISEugenesZombieCureAction:stop()
    self:stopSound()
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.stop(self)
end

function ISEugenesZombieCureAction:perform()
    self:stopSound()
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.perform(self)
end

function ISEugenesZombieCureAction:complete()
    if not self:isValid() then return false end
    local args = {
        operation = M.isReanimationItem(self.item) and "reanimate"
            or (M.isRestorationItem(self.item) and "restore"
            or (self.target and "zombie" or "self")),
        itemId = self.item:getID(),
    }
    if self.target then
        local targetArgs = M.isReanimationItem(self.item)
            and M.makeCorpseArgs(self.target)
            or M.makeZombieArgs(self.target)
        for key, value in pairs(targetArgs) do args[key] = value end
    end

    if isClient() then
        sendClientCommand(self.character, M.MODULE, "useCure", args)
    elseif M.handleUseCure then
        M.handleUseCure(self.character, args, self.target)
    end
    return true
end

function ISEugenesZombieCureAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    if M.isReanimationItem(self.item) then return 300 end
    if M.isRestorationItem(self.item) then return 1 end
    return self.target and 240 or 180
end

function ISEugenesZombieCureAction:new(character, item, target)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.target = target
    o.maxTime = o:getDuration()
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end
