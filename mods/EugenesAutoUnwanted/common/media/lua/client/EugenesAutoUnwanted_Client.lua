require "TimedActions/ISInventoryTransferAction"

EugenesAutoUnwanted = EugenesAutoUnwanted or {}

local TOOL_CATEGORIES = {
    carpentryTool = true,
    cleaningTool = true,
    constructionTool = true,
    cookingTool = true,
    electricalTool = true,
    farmingTool = true,
    fishingTool = true,
    foragingTool = true,
    mechanicsTool = true,
    medicalTool = true,
    metalworkingTool = true,
    survivalTool = true,
    tailoringTool = true,
    trappingTool = true,
    Tool = true,
    ToolWeapon = true,
}

local LEGACY_CLOTHING_CATEGORIES = {
    Clothing = true,
    Accessory = true,
    ProtectiveGear = true,
    Ears = true,
    Tail = true,
}

local BOOK_CATEGORIES = {
    literatureExperience = true,
    literatureReadable = true,
    literatureRecipe = true,
    literatureEntertainment = true,
    literatureSkillBook = true,
    Literature = true,
    SkillBook = true,
}

local function startsWith(value, prefix)
    return string.sub(value, 1, string.len(prefix)) == prefix
end

local function getOptions()
    if SandboxVars and SandboxVars.EugenesAutoUnwanted then
        return SandboxVars.EugenesAutoUnwanted
    end
    return nil
end

local function shouldMarkItem(item)
    local options = getOptions()
    if not options or options.Enabled == false or not item then
        return false
    end

    local category = item:getDisplayCategory()
    if not category or category == "" then
        category = item:getCategory()
    end
    category = category and tostring(category) or ""

    if options.Clothing == true
        and (startsWith(category, "clothing") or LEGACY_CLOTHING_CATEGORIES[category]) then
        return true
    end

    if options.Tools == true
        and (startsWith(category, "tool") or TOOL_CATEGORIES[category]) then
        return true
    end

    if options.Firearms == true and startsWith(category, "weaponFirearm") then
        return true
    end

    if options.Books == true and BOOK_CATEGORIES[category] then
        return true
    end

    if options.Artifacts == true and category == "Artifact" then
        return true
    end

    if options.CookingUtensils == true and category == "cookingUtensil" then
        return true
    end

    return false
end

local function isPlayerLootTransfer(action)
    local character = action and action.character
    local source = action and action.srcContainer
    local destination = action and action.destContainer
    if not character or not instanceof(character, "IsoPlayer") or not source or not destination then
        return false
    end
    return not source:isInCharacterInventory(character)
        and destination:isInCharacterInventory(character)
end

local installedWrapper = nil

local function installTransferHook()
    local current = ISInventoryTransferAction and ISInventoryTransferAction.transferItem
    if not current or current == installedWrapper then
        return
    end

    local previous = current
    local wrapper = function(action, item)
        local lootedByPlayer = isPlayerLootTransfer(action)
        local result = previous(action, item)

        if lootedByPlayer then
            local transferred = action.item
            local container = transferred and transferred:getContainer() or nil
            if container and container:isInCharacterInventory(action.character)
                and shouldMarkItem(transferred) then
                transferred:setUnwanted(action.character, true)
            end
        end

        return result
    end

    installedWrapper = wrapper
    ISInventoryTransferAction.transferItem = wrapper
end

installTransferHook()
Events.OnGameStart.Add(installTransferHook)
Events.OnCreatePlayer.Add(installTransferHook)
