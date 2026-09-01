require "CodexFishingPond_Shared"
require "ISUI/ISWorldObjectContextMenu"

local M = CodexFishingPond

local function canInspectFishSchool(playerObj)
    return playerObj and playerObj:getPerkLevel(Perks.Fishing) >= 4
end

local function findWaterSquare(worldobjects)
    for _, object in ipairs(worldobjects or {}) do
        local square = object and object:getSquare() or nil
        if square and square:getProperties()
            and square:getProperties():has(IsoFlagType.water) then
            return square
        end
    end
    return nil
end

local function showFishCheck(playerObj, message)
    if playerObj and message then
        playerObj:setHaloNote(message, 180, 220, 255, 500)
    end
end

local function checkFishSchool(playerObj, square)
    if not playerObj or not square then return end
    if isClient() then
        sendClientCommand(playerObj, M.MODULE, "checkFishSchool", {
            x = square:getX(), y = square:getY(), z = square:getZ(),
        })
    else
        showFishCheck(playerObj, M.describeSchoolInfo(M.getSchoolInfoAt(square)))
    end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not canInspectFishSchool(playerObj) then return end

    local square = findWaterSquare(worldobjects)
    if not square then return end
    if test then return ISWorldObjectContextMenu.setTest() end

    context:addOption(
        getText("ContextMenu_CFP_CheckFishSchool"),
        playerObj,
        checkFishSchool,
        square
    )
end

local function onServerCommand(module, command, args)
    if module ~= M.MODULE or command ~= "result" then return end
    local playerObj = getPlayer()
    if playerObj and args and args.message then
        playerObj:setHaloNote(args.message, 255, args.ok and 255 or 80, 80, 300)
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
