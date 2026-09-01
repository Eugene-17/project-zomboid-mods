require "BanditCustom"
require "BanditServerSpawner"

EugenesBanditsCompatibility = EugenesBanditsCompatibility or {}

local M = EugenesBanditsCompatibility

if BanditServer and BanditServer.Spawner
    and BanditServer.Spawner.Individual
    and not M.individualSpawnerPatched then
    local originalIndividual = BanditServer.Spawner.Individual

    BanditServer.Spawner.Individual = function(playerObj, args)
        local profile = args and args.bid and BanditCustom.GetById(args.bid) or nil
        local previousClanId = profile and profile.cid or nil

        -- Bandits' custom files persist this value under general.cid, while
        -- its Individual spawner currently reads the old root-level field.
        if profile and not profile.cid and profile.general then
            profile.cid = profile.general.cid
        end

        local ok, result = pcall(originalIndividual, playerObj, args)

        -- Do not leave the compatibility alias in profile data: Bandits.Save
        -- expects every root field to be a section table.
        if profile then profile.cid = previousClanId end

        if not ok then error(result) end
        return result
    end

    M.individualSpawnerPatched = true
end
