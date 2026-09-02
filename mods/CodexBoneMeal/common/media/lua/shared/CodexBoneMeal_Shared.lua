CodexBoneMeal = CodexBoneMeal or {}

local M = CodexBoneMeal

M.MODULE = "CodexBoneMeal"
M.ITEM_FULL_TYPE = "CodexBoneMeal.BoneMeal"

function M.getPlantFailure(plant)
    if not plant or plant.state ~= "seeded" or not plant:isAlive() then
        return "Bone meal can only be used on a living crop."
    end
    if plant.hasVegetable then
        return "This crop is already ready to harvest."
    end
    if (tonumber(plant.health) or 0) <= 0 then
        return "This crop is not healthy enough for bone meal."
    end

    local disease = math.max(
        tonumber(plant.mildewLvl) or 0,
        tonumber(plant.aphidLvl) or 0,
        tonumber(plant.fliesLvl) or 0,
        tonumber(plant.slugsLvl) or 0
    )
    if disease >= 30 then
        return "Treat the crop's disease before applying bone meal."
    end

    return nil
end
