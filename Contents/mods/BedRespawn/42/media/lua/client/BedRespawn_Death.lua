require "BedRespawn_Shared"
require "ISUI/ISPostDeathUI"

local BR = BedRespawn

local SYNC_DELAY_MS = 2000
local BED_CHECK_TIMEOUT_MS = 30000
local NEW_CHARACTER_HOURS = 0.01

local DEFAULT_OUTFIT = {
    { type = "Base.Tshirt_WhiteTINT" },
    { type = "Base.Trousers_Denim" },
    { type = "Base.Socks_Ankle" },
    { type = "Base.Shoes_Black" },
}

-- What the server last told us, by player key.
local states = {}
-- The dead character's identity, by player number.
local identities = {}
-- Bed respawns waiting for their new player to appear, by player number.
local pending = {}
-- Players the game has just created as new characters, by player number.
local newCharacters = {}
-- Delayed work and bed checks, processed on tick.
local delayed = {}
local bedChecks = {}

local function localPlayerFor(key)
    for i = 0, getMaxActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and BR.keyFor(player) == key then
            return player
        end
    end
    return nil
end

function BR.clientHandlers.state(args)
    states[args.key] = { bed = args.bed, origin = args.origin }
    print("BedRespawn: state for " .. tostring(args.key) .. ", bed set=" .. tostring(args.bed ~= nil))
end

function BR.clientHandlers.notice(args)
    local player = localPlayerFor(args.key)
    if player then
        player:setHaloNote(getText(args.text))
    end
end

function BR.clientHandlers.restored(args)
    local player = localPlayerFor(args.key)
    if player then
        BR.applyProgress(player, args.snapshot)
        pcall(SyncXp, player)
    end
end

local function onServerCommand(module, command, args)
    if module == BR.MODULE and BR.clientHandlers[command] then
        BR.clientHandlers[command](args)
    end
end

local function captureOutfit(player)
    local outfit = {}
    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local item = worn:getItemByIndex(i)
        if item then
            local entry = { type = item:getFullType() }
            pcall(function()
                local visual = item:getVisual()
                local tint = visual:getTint(item:getClothingItem())
                entry.r = tint:getRedFloat()
                entry.g = tint:getGreenFloat()
                entry.b = tint:getBlueFloat()
                entry.textureChoice = visual:getTextureChoice()
            end)
            table.insert(outfit, entry)
        end
    end
    return outfit
end

local function dress(desc, outfit)
    local dressed = false
    desc:getWornItems():clear()
    for _, entry in pairs(outfit) do
        local item = instanceItem(entry.type)
        local location = item and item:getBodyLocation()
        if location then
            if entry.r then
                pcall(function()
                    local visual = item:getVisual()
                    visual:setTint(ImmutableColor.new(entry.r, entry.g, entry.b, 1))
                    visual:setTextureChoice(entry.textureChoice)
                end)
            end
            desc:setWornItem(location, item)
            dressed = true
        end
    end
    return dressed
end

-- Radio and TV lines are only known on the client and can't be listed directly,
-- so this checks every recorded media line. Broadcast lines aren't covered.
local function captureMediaLines(player)
    local lines = {}
    pcall(function()
        local media = getZomboidRadio():getRecordedMedia()
        local categories = media:getCategories()
        for i = 0, categories:size() - 1 do
            local list = media:getAllMediaForCategory(categories:get(i))
            for j = 0, list:size() - 1 do
                local data = list:get(j)
                for k = 0, data:getLineCount() - 1 do
                    local guid = data:getLine(k):getTextGuid()
                    if player:isKnownMediaLine(guid) then
                        table.insert(lines, guid)
                    end
                end
            end
        end
    end)
    return lines
end

local function captureIdentity(player)
    local desc = player:getDescriptor()
    local visual = player:getHumanVisual()
    return {
        key = BR.keyFor(player),
        username = player:getUsername(),
        forename = desc:getForename(),
        surname = desc:getSurname(),
        female = player:isFemale(),
        voicePrefix = desc:getVoicePrefix(),
        voiceType = desc:getVoiceType(),
        voicePitch = desc:getVoicePitch(),
        profession = desc:getCharacterProfession(),
        traits = BR.traitNames(player),
        hairModel = visual:getHairModel(),
        beardModel = visual:getBeardModel(),
        hairColor = visual:getHairColor(),
        beardColor = visual:getBeardColor(),
        naturalHairColor = visual:getNaturalHairColor(),
        naturalBeardColor = visual:getNaturalBeardColor(),
        nonAttachedHair = visual:getNonAttachedHair(),
        skinTextureIndex = visual:getSkinTextureIndex(),
        bodyHairIndex = visual:getBodyHairIndex(),
    }
end

local function buildDescriptor(identity, origin)
    local desc = SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, identity.female)
    desc:setForename(identity.forename)
    desc:setSurname(identity.surname)
    desc:setFemale(identity.female)
    desc:setVoicePrefix(identity.voicePrefix)
    desc:setVoiceType(identity.voiceType)
    desc:setVoicePitch(identity.voicePitch)

    local definition = CharacterProfessionDefinition.getCharacterProfessionDefinition(identity.profession)
    if definition then
        desc:setProfessionSkills(definition)
    end
    desc:setCharacterProfession(identity.profession)

    local visual = desc:getHumanVisual()
    visual:setHairModel(identity.hairModel or "")
    visual:setBeardModel(identity.beardModel or "")
    if identity.hairColor then visual:setHairColor(identity.hairColor) end
    if identity.beardColor then visual:setBeardColor(identity.beardColor) end
    if identity.naturalHairColor then visual:setNaturalHairColor(identity.naturalHairColor) end
    if identity.naturalBeardColor then visual:setNaturalBeardColor(identity.naturalBeardColor) end
    if identity.nonAttachedHair then visual:setNonAttachedHair(identity.nonAttachedHair) end
    visual:setSkinTextureIndex(identity.skinTextureIndex)
    visual:setBodyHairIndex(identity.bodyHairIndex)

    if not (origin and origin.outfit and dress(desc, origin.outfit)) then
        dress(desc, DEFAULT_OUTFIT)
    end
    return desc
end

local function canRespawnAtBed(playerNum)
    local identity = identities[playerNum]
    local state = identity and states[identity.key]
    return state ~= nil and state.bed ~= nil
end

-- Mirrors CoopCharacterCreation:accept1() and accept(), without the creation screens.
local function respawnAtBed(panel)
    if MainScreen.instance:isReallyVisible() then return end
    local playerNum = panel.playerIndex
    if not canRespawnAtBed(playerNum) then return end

    local identity = identities[playerNum]
    local state = states[identity.key]
    local bed = state.bed
    local desc = buildDescriptor(identity, state.origin)

    setGameSpeed(1)

    local world = getWorld()
    world:setLuaPosX(bed.x)
    world:setLuaPosY(bed.y)
    world:setLuaPosZ(bed.z)
    world:setLuaPlayerDesc(desc)
    world:getLuaTraits():clear()
    local byName = BR.traitsByName()
    for _, name in pairs((state.origin and state.origin.traits) or identity.traits) do
        if byName[name] then
            world:addLuaTrait(byName[name])
        end
    end
    MainScreen.instance.desc = desc
    MainScreen.instance.avatar = nil

    pending[playerNum] = { bed = bed, mediaLines = identity.mediaLines }
    identities[playerNum] = nil

    panel:removeFromUIManager()
    ISPostDeathUI.instance[playerNum] = nil

    local joypadData = JoypadState.players[playerNum + 1]
    if not joypadData then
        setPlayerMouse(nil)
        return
    end

    local username = nil
    if isClient() and playerNum > 0 then
        username = identity.username
    end
    local controller = joypadData.controller
    local slot = JoypadState.joypads[playerNum + 1]
    JoypadState.players[playerNum + 1] = slot
    slot.player = playerNum
    slot:setController(controller)
    slot:setActive(true)
    setPlayerJoypad(playerNum, joypadData.id, nil, username, true)
    joypadData.focus = nil
    joypadData.lastfocus = nil
    joypadData.prevfocus = nil
    joypadData.prevprevfocus = nil
end

-- If another mod's error stops the in-game pause menu loading, the menu is never
-- added to the UI but still counts as visible. Vanilla then hides the death screen
-- until Esc is pressed, and refuses respawn clicks while the menu is "open".
local function showDeathScreenIfMenuBroken(playerNum)
    local screen = MainScreen.instance
    if not screen or not screen.inGame or not screen:isVisible() then return end
    if UIManager.getUI():contains(screen.javaObject) then return end

    screen:setVisible(false)
    local panel = ISPostDeathUI.instance[playerNum]
    if panel then
        panel:setVisible(true)
        local joypadData = JoypadState.players[playerNum + 1]
        if joypadData then
            joypadData.focus = panel
        end
    end
end

local function onPlayerDeath(player)
    if not player:isLocalPlayer() then return end
    showDeathScreenIfMenuBroken(player:getPlayerNum())
    local identity = captureIdentity(player)
    if BR.keepProgress() then
        identity.mediaLines = captureMediaLines(player)
        BR.send(player, "died", {})
    end
    identities[player:getPlayerNum()] = identity
end

local function afterSpawn(playerNum, player)
    local isNew = newCharacters[playerNum] == true
    newCharacters[playerNum] = nil

    local respawn = pending[playerNum]
    if respawn then
        pending[playerNum] = nil
        print("BedRespawn: respawned at bed, player " .. tostring(playerNum))
        for _, guid in pairs(respawn.mediaLines or {}) do
            player:addKnownMediaLine(guid)
        end
        BR.send(player, "restore", {})
        table.insert(bedChecks, {
            player = player,
            bed = respawn.bed,
            expires = getTimestampMs() + BED_CHECK_TIMEOUT_MS,
        })
        return
    end

    -- Loading a save must never count as a new character, because that clears the bed.
    -- Hours are only a fallback for multiplayer clients, in case OnNewGame doesn't reach them.
    local fresh = isNew or (isClient() and player:getHoursSurvived() <= NEW_CHARACTER_HOURS)
    print("BedRespawn: player " .. tostring(playerNum) .. " spawned, new character=" .. tostring(fresh)
        .. " hours=" .. tostring(player:getHoursSurvived()))
    local origin = { traits = BR.traitNames(player) }
    -- A character already in play has changed clothes, so this isn't their starting outfit.
    if fresh then
        origin.outfit = captureOutfit(player)
    end
    BR.send(player, "recordOrigin", { fresh = fresh, origin = origin })
end

local function onNewGame(player)
    newCharacters[player:getPlayerNum()] = true
end

local function onCreatePlayer(playerNum, player)
    -- Give the server time to finish creating its copy of the player.
    table.insert(delayed, {
        at = getTimestampMs() + SYNC_DELAY_MS,
        run = function() afterSpawn(playerNum, player) end,
    })
end

local function checkBed(check)
    local square = getSquare(check.bed.bedX, check.bed.bedY, check.bed.bedZ)
    if not square then
        -- Not loaded yet. Leave the spawn point alone if it never loads.
        return getTimestampMs() > check.expires
    end
    if not BR.findBed(square) then
        BR.send(check.player, "clearBed", {})
        check.player:setHaloNote(getText("IGUI_BedRespawn_BedGone"))
    end
    return true
end

local function onTick()
    local now = getTimestampMs()
    for i = #delayed, 1, -1 do
        if now >= delayed[i].at then
            local entry = table.remove(delayed, i)
            entry.run()
        end
    end
    for i = #bedChecks, 1, -1 do
        if checkBed(bedChecks[i]) then
            table.remove(bedChecks, i)
        end
    end
end

-- Death screen: add one button above the vanilla ones.

local createChildren = ISPostDeathUI.createChildren
function ISPostDeathUI:createChildren()
    createChildren(self)

    local text = getText("IGUI_BedRespawn_Respawn")
    local buttonHgt = self.buttonRespawn:getHeight()
    local gap = self.buttonExit:getY() - self.buttonRespawn:getY() - buttonHgt
    local shift = buttonHgt + gap
    local width = math.max(self:getWidth(), getTextManager():MeasureStringX(UIFont.Small, text) + 20)
    local x = self:getX() - (width - self:getWidth()) / 2
    local y = self:getY() - shift
    local buttons = { self.buttonRespawn, self.buttonExit, self.buttonQuit }
    local buttonYs = {}
    for i, button in ipairs(buttons) do
        buttonYs[i] = button:getY() + shift
    end

    self:setWidth(width)
    self:setHeight(self:getHeight() + shift)
    -- must set these after setWidth/setHeight, as vanilla does
    self:setX(x)
    self:setY(y)

    for i, button in ipairs(buttons) do
        button:setX(0)
        button:setY(buttonYs[i])
        button:setWidth(width)
    end

    local button = ISButton:new(0, 0, width, buttonHgt, text, self, respawnAtBed)
    self:configButton(button)
    button:setVisible(false)
    self:addChild(button)
    self.buttonBedRespawn = button
end

local prerender = ISPostDeathUI.prerender
function ISPostDeathUI:prerender()
    prerender(self)
    -- Same rules as the vanilla Respawn button, which covers server settings and challenges.
    local allowed = self.buttonRespawn:isVisible() and self.buttonRespawn.enable ~= false
    self.buttonBedRespawn:setVisible(allowed and canRespawnAtBed(self.playerIndex))
end

local onGainJoypadFocus = ISPostDeathUI.onGainJoypadFocus
function ISPostDeathUI:onGainJoypadFocus(joypadData)
    onGainJoypadFocus(self, joypadData)
    self:setISButtonForY(self.buttonBedRespawn)
end

local onJoypadReactivate = ISPostDeathUI.onJoypadReactivate
function ISPostDeathUI:onJoypadReactivate(joypadData)
    onJoypadReactivate(self, joypadData)
    self:setISButtonForY(self.buttonBedRespawn)
end

local onJoypadBeforeDeactivate = ISPostDeathUI.onJoypadBeforeDeactivate
function ISPostDeathUI:onJoypadBeforeDeactivate(joypadData)
    onJoypadBeforeDeactivate(self, joypadData)
    self.buttonBedRespawn:clearJoypadButton()
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnNewGame.Add(onNewGame)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnTick.Add(onTick)
