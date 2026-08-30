CodexBoneMeal = CodexBoneMeal or {}

local M = CodexBoneMeal

M.MODULE = "CodexBoneMeal"
M.ITEM_FULL_TYPE = "CodexBoneMeal.BoneMeal"
M.DATA_KEY = "CodexBoneMeal_v1"
M.COOLDOWN_HOURS = 24

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

    local water = tonumber(plant.waterLvl) or 0
    local minimum = tonumber(plant.waterNeeded) or 0
    local maximum = tonumber(plant.waterNeededMax)
    if water < minimum or (maximum and water > maximum) then
        return "Water the crop into its required range first."
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

function M.squareKey(x, y, z)
    return tostring(math.floor(x)) .. ":" .. tostring(math.floor(y)) .. ":" .. tostring(math.floor(z))
end
