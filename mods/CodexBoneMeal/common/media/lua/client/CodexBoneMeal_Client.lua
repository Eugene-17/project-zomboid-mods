require "Farming/ISUI/ISFarmingMenu"
require "ISUI/ISToolTip"
require "TimedActions/ISBaseTimedAction"
require "CodexBoneMeal_Shared"

local M = CodexBoneMeal

ISApplyCodexBoneMealAction = ISBaseTimedAction:derive("ISApplyCodexBoneMealAction")

function ISApplyCodexBoneMealAction:isValid()
    if not self.character:getInventory():containsTypeRecurse(M.ITEM_FULL_TYPE) then
        return false
    end
    self.plant:updateFromIsoObject()
    return self.plant:getIsoObject() ~= nil and M.getPlantFailure(self.plant) == nil
end

function ISApplyCodexBoneMealAction:waitToStart()
    self.character:faceThisObject(self.plant:getObject())
    return self.character:isTurning() or self.character:shouldBeTurning()
end

function ISApplyCodexBoneMealAction:update()
    self.item:setJobDelta(self:getJobDelta())
    self.character:faceThisObject(self.plant:getObject())
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function ISApplyCodexBoneMealAction:start()
    self.item:setJobType(getText("ContextMenu_CBM_ApplyBoneMeal"))
    self.item:setJobDelta(0.0)
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self:setOverrideHandModels(self.item, nil)
    self.sound = self.character:playSound("DropSoilFromSandBag")
end

function ISApplyCodexBoneMealAction:stop()
    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopOrTriggerSound(self.sound)
    end
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.stop(self)
end

function ISApplyCodexBoneMealAction:perform()
    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopOrTriggerSound(self.sound)
    end
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.perform(self)
end

function ISApplyCodexBoneMealAction:complete()
    local args = { x = self.plant.x, y = self.plant.y, z = self.plant.z }
    if isClient() then
        sendClientCommand(self.character, M.MODULE, "apply", args)
    elseif M.applyBoneMeal then
        M.applyBoneMeal(self.character, args)
    end
    return true
end

function ISApplyCodexBoneMealAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 120
end

function ISApplyCodexBoneMealAction:new(character, item, plant)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.item = item
    o.plant = plant
    o.maxTime = o:getDuration()
    return o
end

local function makeTooltip(text)
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip:setVisible(false)
    tooltip.description = text
    return tooltip
end

local function applyFromMenu(playerObj, item, plant)
    if not playerObj or not item or not plant then return end
    local square = plant:getSquare()
    if not square or not ISFarmingMenu.walkToPlant(playerObj, square) then return end
    ISTimedActionQueue.add(ISApplyCodexBoneMealAction:new(playerObj, item, plant))
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local item = playerObj:getInventory():getFirstTypeRecurse(M.ITEM_FULL_TYPE)
    if not item then return end

    local plant = ISFarmingMenu.getBestPlantFromTable(playerObj, worldobjects)
    if not plant then return end

    if test then return ISWorldObjectContextMenu.setTest() end

    local option = context:addOption(
        getText("ContextMenu_CBM_ApplyBoneMeal"),
        playerObj,
        applyFromMenu,
        item,
        plant
    )
    option.iconTexture = item:getTexture()

    local failure = M.getPlantFailure(plant)
    if failure then
        option.notAvailable = true
        option.toolTip = makeTooltip(failure)
    else
        option.toolTip = makeTooltip(getText("Tooltip_CBM_ApplyBoneMeal"))
    end
end

local function onServerCommand(module, command, args)
    if module ~= M.MODULE or command ~= "result" then return end
    local playerObj = getPlayer()
    if playerObj and args and args.message then
        playerObj:setHaloNote(args.message, 255, args.ok and 255 or 80, 80, 300)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnServerCommand.Add(onServerCommand)
