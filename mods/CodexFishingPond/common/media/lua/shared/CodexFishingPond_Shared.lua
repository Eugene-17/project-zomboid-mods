CodexFishingPond = CodexFishingPond or {}

local M = CodexFishingPond

M.MODULE = "CodexFishingPond"
M.DATA_KEY = "CodexFishingPond_v2"
M.MARKER_KEY = "CodexFishingPondTileId"
M.VARIANT_KEY = "CodexFishingPondVariant"
M.SHORE_SCHEMA_VERSION = 5
M.SCHOOL_BASE_CAPACITY = 10
M.SCHOOL_FISH_PER_CENTER = 5
M.SCHOOL_REPOPULATE_PER_DAY = 1
M.SCHOOL_CHUM_FORCE_MINUTES = 180

-- Vanilla's true water floors. These carry IsoFlagType.water and are what
-- fishing, fishing nets, and bobber movement actually inspect.
M.WATER_SPRITES = {
    "blends_natural_02_0",
    "blends_natural_02_5",
    "blends_natural_02_6",
    "blends_natural_02_7",
}

-- Vanilla pond/river shoreline attachments. These deliberately do not carry
-- the water flag: they remain walkable land surrounding the fishable center.
-- Each sprite faces inward toward the neighboring water square. Corners are
-- intentionally omitted because diagonal wedges do not join cleanly here.
M.SHORE_SPRITES = {
    edgeN = "blends_natural_02_11",
    edgeW = "blends_natural_02_10",
    edgeE = "blends_natural_02_9",
    edgeS = "blends_natural_02_8",
    edgeN2 = "blends_natural_02_15",
    edgeW2 = "blends_natural_02_14",
    edgeE2 = "blends_natural_02_13",
    edgeS2 = "blends_natural_02_12",
}

-- Earlier layouts used other straight-edge assignments and four diagonal
-- wedges. Retain those names so an old pond can remain untouched and still be
-- filled in safely later; version 5 selects only the inward-facing pieces.
M.LEGACY_SHORE_SPRITES = {
    cornerNW = "blends_natural_02_1",
    cornerNE = "blends_natural_02_4",
    cornerSW = "blends_natural_02_3",
    cornerSE = "blends_natural_02_2",
    edgeN = "blends_natural_02_8",
    edgeW = "blends_natural_02_9",
    edgeE = "blends_natural_02_10",
    edgeS = "blends_natural_02_11",
    edgeN2 = "blends_natural_02_12",
    edgeW2 = "blends_natural_02_13",
    edgeE2 = "blends_natural_02_14",
    edgeS2 = "blends_natural_02_15",
}

function M.getKnownShoreSprite(variant)
    return M.SHORE_SPRITES[variant] or M.LEGACY_SHORE_SPRITES[variant]
end

function M.findMarkedObject(square)
    if not square then return nil, nil end
    for i = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(i)
        if object and object:hasModData() then
            local tileId = object:getModData()[M.MARKER_KEY]
            if tileId then return object, tileId end
        end
    end
    return nil, nil
end

function M.getMarkedTileId(square)
    local _, tileId = M.findMarkedObject(square)
    return tileId
end

function M.getSchoolInfoAt(square)
    if not square or not square:getProperties()
        or not square:getProperties():has(IsoFlagType.water) then
        return nil
    end

    local x = square:getX()
    local y = square:getY()
    local manager = FishSchoolManager and FishSchoolManager.getInstance()
    local vanillaAbundance = manager and manager:getFishAbundance(x, y) or 0
    local tileId = M.getMarkedTileId(square)

    if tileId then
        local data = ModData.getOrCreate(M.DATA_KEY)
        local record = data.tiles and data.tiles[tileId] or nil
        if record and record.variant == "center" then
            for schoolId, school in pairs(data.schools or {}) do
                if type(school.tileIds) == "table" and school.tileIds[tileId] == true then
                    local centerCount = 0
                    for _ in pairs(school.tileIds) do centerCount = centerCount + 1 end
                    return {
                        kind = "constructed",
                        schoolId = tostring(schoolId),
                        stock = tonumber(school.stock) or 0,
                        capacity = tonumber(school.capacity) or 0,
                        centerCount = centerCount,
                        vanillaAbundance = vanillaAbundance,
                    }
                end
            end

            return {
                kind = "incomplete",
                vanillaAbundance = vanillaAbundance,
            }
        end
    end

    return {
        kind = "natural",
        vanillaAbundance = vanillaAbundance,
    }
end

function M.describeSchoolInfo(info)
    if not info then return "That square is not fishable water." end

    if info.kind == "constructed" then
        return string.format(
            "Pond school #%s: %d/%d fish, %d connected water tile(s), +%d fish/day. Current abundance: %.1f.",
            tostring(info.schoolId),
            math.floor(info.stock),
            math.floor(info.capacity),
            math.floor(info.centerCount),
            M.SCHOOL_REPOPULATE_PER_DAY,
            info.vanillaAbundance
        )
    elseif info.kind == "incomplete" then
        return string.format(
            "Constructed pond: no school. Complete the shoreline. Current natural abundance: %.1f.",
            info.vanillaAbundance
        )
    end

    return string.format("Natural water fish abundance: %.1f.", info.vanillaAbundance)
end
