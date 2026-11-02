-- Saved data and command handling. In singleplayer the handlers run directly;
-- in multiplayer they only ever run on the server (see BedRespawn_Server.lua).

BedRespawn = BedRespawn or {}
local BR = BedRespawn

BR.MODULE = "BedRespawn"
BR.clientHandlers = BR.clientHandlers or {}

local MAX_BED_DISTANCE = 3
local FRESH_BODY_HOURS = 0.1

local literatureTypes = nil

local function safely(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        print("BedRespawn: " .. label .. " failed: " .. tostring(err))
    end
end

function BR.keepProgress()
    return SandboxVars.BedRespawn ~= nil and SandboxVars.BedRespawn.KeepProgress == true
end

-- Usernames are unique per player in multiplayer, including splitscreen.
function BR.keyFor(player)
    if isClient() or isServer() then
        return player:getUsername()
    end
    return "player" .. tostring(player:getPlayerNum())
end

function BR.isBed(object)
    local props = object and object:getProperties()
    if not props then return false end
    return props:has(IsoFlagType.bed) or props:get("BedType") ~= nil
end

function BR.findBed(square)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if BR.isBed(object) then
            return object
        end
    end
    return nil
end

function BR.traitNames(player)
    local names = {}
    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, known:size() - 1 do
        table.insert(names, tostring(known:get(i)))
    end
    return names
end

-- CharacterTrait objects can't be saved, so traits are stored by name.
function BR.traitsByName()
    local byName = {}
    local definitions = CharacterTraitDefinition.getTraits()
    for i = 0, definitions:size() - 1 do
        local trait = definitions:get(i):getType()
        byName[tostring(trait)] = trait
    end
    return byName
end

local function forEachPerk(fn)
    for i = 1, Perks.getMaxIndex() do
        local perk = PerkFactory.getPerk(Perks.fromIndex(i - 1))
        if perk and perk:getParent() ~= Perks.None then
            fn(perk)
        end
    end
end

local function getLiteratureTypes()
    if not literatureTypes then
        literatureTypes = {}
        local items = getAllItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getNumberOfPages() > 0 then
                table.insert(literatureTypes, item:getFullName())
            end
        end
    end
    return literatureTypes
end

function BR.captureProgress(player)
    local snapshot = {
        perks = {},
        recipes = {},
        readBooks = {},
        readPages = {},
        traits = {},
        kills = player:getZombieKills(),
        hours = player:getHoursSurvived(),
    }

    safely("reading skills", function()
        local xp = player:getXp()
        forEachPerk(function(perk)
            snapshot.perks[perk:getId()] = {
                level = player:getPerkLevel(perk),
                xp = xp:getXP(perk),
                multiplier = xp:getMultiplier(perk),
            }
        end)
    end)

    safely("reading recipes", function()
        local recipes = player:getKnownRecipes()
        for i = 0, recipes:size() - 1 do
            table.insert(snapshot.recipes, recipes:get(i))
        end
    end)

    safely("reading books", function()
        local books = player:getAlreadyReadBook()
        for i = 0, books:size() - 1 do
            table.insert(snapshot.readBooks, books:get(i))
        end
        for _, fullType in pairs(getLiteratureTypes()) do
            local pages = player:getAlreadyReadPages(fullType)
            if pages > 0 then
                snapshot.readPages[fullType] = pages
            end
        end
    end)

    safely("reading traits", function()
        snapshot.traits = BR.traitNames(player)
    end)

    return snapshot
end

-- Used on the server, then repeated on the owning client with the same values
-- so both copies of the player agree.
function BR.applyProgress(player, snapshot)
    safely("restoring skills", function()
        local xp = player:getXp()
        forEachPerk(function(perk)
            local saved = snapshot.perks and snapshot.perks[perk:getId()]
            if saved then
                player:setPerkLevelDebug(perk, saved.level)
                xp:setXPToLevel(perk, saved.level)
                local remainder = saved.xp - xp:getXP(perk)
                if remainder > 0 then
                    xp:AddXPNoMultiplier(perk, remainder)
                end
                if saved.multiplier > 1 then
                    xp:addXpMultiplier(perk, saved.multiplier, 0, 10)
                end
            end
        end)
    end)

    safely("restoring recipes", function()
        for _, recipe in pairs(snapshot.recipes or {}) do
            player:learnRecipe(recipe)
        end
    end)

    safely("restoring books", function()
        local books = player:getAlreadyReadBook()
        for _, fullType in pairs(snapshot.readBooks or {}) do
            if not books:contains(fullType) then
                books:add(fullType)
            end
        end
        for fullType, pages in pairs(snapshot.readPages or {}) do
            player:setAlreadyReadPages(fullType, pages)
        end
    end)

    safely("restoring traits", function()
        local traits = player:getCharacterTraits()
        local known = traits:getKnownTraits()
        local current = {}
        for i = 0, known:size() - 1 do
            table.insert(current, known:get(i))
        end
        for _, trait in pairs(current) do
            traits:remove(trait)
        end
        local byName = BR.traitsByName()
        for _, name in pairs(snapshot.traits or {}) do
            if byName[name] then
                traits:add(byName[name])
            end
        end
    end)

    safely("restoring stats", function()
        player:setZombieKills(snapshot.kills or 0)
        player:setHoursSurvived(snapshot.hours or 0)
    end)
end

local function record(key)
    local data = ModData.getOrCreate(BR.MODULE)
    if not data[key] then
        data[key] = {}
    end
    return data[key]
end

local function reply(player, command, args)
    if isServer() then
        sendServerCommand(player, BR.MODULE, command, args)
    elseif BR.clientHandlers[command] then
        BR.clientHandlers[command](args)
    end
end

local function sendState(player, key, rec)
    reply(player, "state", { key = key, bed = rec.bed, origin = rec.origin })
end

local function isNear(a, b)
    return math.abs(a - b) <= MAX_BED_DISTANCE
end

local handlers = {}

function handlers.requestState(player, key, rec)
    sendState(player, key, rec)
end

function handlers.recordOrigin(player, key, rec, args)
    if args.fresh then
        -- A brand-new character: anything saved belonged to the previous one.
        rec.bed = nil
        rec.snapshot = nil
        rec.origin = args.origin
    elseif not rec.origin then
        rec.origin = args.origin
    end
    sendState(player, key, rec)
end

function handlers.setBed(player, key, rec, args)
    local valid = type(args.x) == "number" and type(args.y) == "number" and type(args.z) == "number"
        and type(args.bedX) == "number" and type(args.bedY) == "number" and type(args.bedZ) == "number"
    valid = valid and isNear(player:getX(), args.bedX) and isNear(player:getY(), args.bedY)
        and isNear(args.x, args.bedX) and isNear(args.y, args.bedY)
        and player:getZ() - args.bedZ < 1 and args.bedZ - player:getZ() < 1
        and args.z == args.bedZ
        and BR.findBed(getSquare(args.bedX, args.bedY, args.bedZ)) ~= nil

    if valid then
        rec.bed = { x = args.x, y = args.y, z = args.z, bedX = args.bedX, bedY = args.bedY, bedZ = args.bedZ }
        sendState(player, key, rec)
    end
    reply(player, "notice", { key = key, text = valid and "IGUI_BedRespawn_SpawnSet" or "IGUI_BedRespawn_SpawnFailed" })
end

function handlers.clearBed(player, key, rec)
    rec.bed = nil
    sendState(player, key, rec)
end

function handlers.died(player, key, rec)
    if BR.keepProgress() then
        rec.snapshot = BR.captureProgress(player)
    end
end

function handlers.restore(player, key, rec)
    local snapshot = rec.snapshot
    -- Only a body that has just spawned can be restored, and only once.
    if not snapshot or not BR.keepProgress() or player:getHoursSurvived() >= FRESH_BODY_HOURS then
        return
    end
    rec.snapshot = nil
    BR.applyProgress(player, snapshot)
    if isServer() then
        safely("syncing recipes and books", function()
            sendSyncPlayerFields(player, 0x00000007)
        end)
        reply(player, "restored", { key = key, snapshot = snapshot })
    end
end

function BR.handleCommand(player, command, args)
    local handler = handlers[command]
    if not handler or not player then return end
    -- The key always comes from the sender, never from the client's arguments.
    local key = BR.keyFor(player)
    handler(player, key, record(key), args or {})
end

function BR.send(player, command, args)
    if isClient() then
        sendClientCommand(player, BR.MODULE, command, args or {})
    else
        BR.handleCommand(player, command, args)
    end
end

-- Backup for when the server has already dropped a dead player by the time
-- their "died" command arrives.
function BR.refreshSnapshots()
    if not BR.keepProgress() then return end
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        -- A fresh body may still be waiting for its restore; don't overwrite that.
        if not player:isDead() and player:getHoursSurvived() >= FRESH_BODY_HOURS then
            record(BR.keyFor(player)).snapshot = BR.captureProgress(player)
        end
    end
end
