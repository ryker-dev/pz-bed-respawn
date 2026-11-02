require "BedRespawn_Shared"

if not isServer() then return end

local function onClientCommand(module, command, player, args)
    if module == BedRespawn.MODULE then
        BedRespawn.handleCommand(player, command, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.EveryTenMinutes.Add(BedRespawn.refreshSnapshots)
