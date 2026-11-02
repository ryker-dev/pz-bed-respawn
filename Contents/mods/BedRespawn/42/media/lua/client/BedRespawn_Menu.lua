require "BedRespawn_Shared"

local BR = BedRespawn

local function saveSpawn(playerNum, bed)
    local player = getSpecificPlayer(playerNum)
    if not player or player:isDead() then return end
    local bedSquare = bed:getSquare()
    local square = player:getCurrentSquare()
    if not bedSquare or not square then return end

    BR.send(player, "setBed", {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        bedX = bedSquare:getX(),
        bedY = bedSquare:getY(),
        bedZ = bedSquare:getZ(),
    })
end

local function onSetSpawn(playerNum, bed)
    local player = getSpecificPlayer(playerNum)
    local bedSquare = bed:getSquare()
    if AdjacentFreeTileFinder.isTileOrAdjacent(player:getCurrentSquare(), bedSquare) then
        saveSpawn(playerNum, bed)
        return
    end

    local adjacent = AdjacentFreeTileFinder.Find(bedSquare, player)
    if adjacent then
        ISTimedActionQueue.clear(player)
        local action = ISWalkToTimedAction:new(player, adjacent)
        action:setOnComplete(saveSpawn, playerNum, bed)
        ISTimedActionQueue.add(action)
    else
        player:setHaloNote(getText("IGUI_BedRespawn_SpawnFailed"))
    end
end

local function onFillMenu(playerNum, context, worldObjects, test)
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end

    local bed = nil
    for _, object in ipairs(worldObjects) do
        bed = BR.findBed(object:getSquare())
        if bed then break end
    end
    if not bed then return end

    if test then return ISWorldObjectContextMenu.setTest() end
    context:addOption(getText("IGUI_BedRespawn_SetSpawn"), playerNum, onSetSpawn, bed)
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)
