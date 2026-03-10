local CONFIG = rawget(_G, "GS_COOP_CONFIG") or {}

local MODE = CONFIG.mode or "host"
local HOST = CONFIG.host or "127.0.0.1"
local PORT = CONFIG.port or 58777
local SYNC_INTERVAL = CONFIG.sync_interval_frames or 8
local APPLY_INTERVAL = CONFIG.apply_interval_frames or 10
local HUD_INTERVAL = CONFIG.hud_interval_frames or 8
local OBJECT_INTERVAL = CONFIG.object_interval_frames or 1
local RECONNECT_INTERVAL = CONFIG.reconnect_interval_frames or 300
local STALE_REMOTE_FRAMES = CONFIG.stale_remote_frames or 240
local MAX_RENDER_DISTANCE_TILES = CONFIG.max_render_distance_tiles or 18
local PARTNER_SMOOTHING_PIXELS = CONFIG.partner_smoothing_pixels or 6
local PARTNER_TELEPORT_PIXELS = CONFIG.partner_teleport_pixels or 28
local OVERWORLD_STEP_PIXELS = CONFIG.overworld_step_pixels or 16
local SYNC_PARTY = CONFIG.sync_party ~= false
local SYNC_ITEMS = CONFIG.sync_items ~= false
local SYNC_MONEY = CONFIG.sync_money ~= false
local FORCE_BLUE_GOLD = CONFIG.force_blue_gold == true

local ADDR = {
	MONEY = 0xD573,
	MONEY_LEN = 3,
	ITEMS = 0xD5B7,
	ITEMS_LEN = 0x5F,
	PARTY = 0xDA22,
	PARTY_LEN = 0x1AC,
	MAP_GROUP = 0xDA00,
	MAP_NUMBER = 0xDA01,
	CAMERA_Y = 0xDA02,
	CAMERA_X = 0xDA03,
	MAP_STATUS = 0xD159,
	SCRIPT_RUNNING = 0xD15F,
	H_IN_MENU = 0xFFAC,
	BATTLE_TYPE = 0xD116,
	PLAYER_OBJECT_STRUCT_ID = 0xD445,
	PLAYER_OBJECT_SPRITE = 0xD446,
	PLAYER_OBJECT_Y = 0xD447,
	PLAYER_OBJECT_X = 0xD448,

	OBJ0_BASE = 0xD1FD,
	OBJ1_BASE = 0xD225,
	OBJ_LEN = 0x28,
	OBJ_SLOT_COUNT = 12,
}

local O = {
	SPRITE = 0x00,
	MAP_OBJECT_INDEX = 0x01,
	MOVEMENT_TYPE = 0x03,
	FLAGS1 = 0x04,
	FLAGS2 = 0x05,
	PALETTE = 0x06,
	WALKING = 0x07,
	DIRECTION = 0x08,
	STEP_TYPE = 0x09,
	ACTION = 0x0B,
	STEP_FRAME = 0x0C,
	FACING = 0x0D,
	MAP_X = 0x10,
	MAP_Y = 0x11,
	LAST_MAP_X = 0x12,
	LAST_MAP_Y = 0x13,
	INIT_X = 0x14,
	INIT_Y = 0x15,
	RADIUS = 0x16,
	SPRITE_X = 0x17,
	SPRITE_Y = 0x18,
	SPRITE_X_OFFSET = 0x19,
	SPRITE_Y_OFFSET = 0x1A,
	MARKER_A = 0x1D,
	MARKER_B = 0x1E,
}

local BITS = {
	INVISIBLE = 0x01,
	WONT_DELETE = 0x02,
	FIXED_FACING = 0x04,
	MOVE_ANYWHERE = 0x20,
	OFF_SCREEN = 0x40,
}

local CONST = {
	SPRITE_BLUE = 0x07,
	SPRITEMOVEDATA_STILL = 0x01,
	STEP_TYPE_STANDING = 0x04,
	OBJECT_ACTION_STAND = 0x01,
	DIR_DOWN = 0x00,
	DIR_UP = 0x04,
	DIR_LEFT = 0x08,
	DIR_RIGHT = 0x0C,
	SCREEN_CENTER_X = 80,
	SCREEN_CENTER_Y = 72,
	MARKER_A = 0xC0,
	MARKER_B = 0x2A,
}

local state = {
	server = nil,
	peer = nil,
	rx = "",
	remote = nil,
	lastSentFrame = -1,
	lastHudFrame = -1,
	lastApplyFrame = -1,
	lastObjectFrame = -1,
	lastAppliedRemoteFrame = -1,
	nextReconnectFrame = 0,
	partnerBase = nil,
	partnerBackup = nil,
	partnerSpriteX = nil,
	partnerSpriteY = nil,
	partnerMapX = nil,
	partnerMapY = nil,
	lastRemoteWorldX = nil,
	lastRemoteWorldY = nil,
	lastRemoteObjectFrame = -1,
	warnedNoSlot = false,
	hud = nil,
	frameFallback = 0,
}

local function remoteAge(frameNow)
	if not state.remote then
		return nil
	end
	local receivedFrame = state.remote.receivedFrame
	if type(receivedFrame) ~= "number" then
		return 0
	end
	return frameNow - receivedFrame
end

local function addCallback(eventName, fn)
	local register = rawget(_G, "GS_registerCallback")
	if type(register) == "function" then
		return register(eventName, fn)
	end
	return callbacks:add(eventName, fn)
end

local function registerUnload(fn)
	local register = rawget(_G, "GS_registerUnload")
	if type(register) == "function" then
		register(fn)
	end
end

local function log(msg)
	console:log("[GS-COOP] " .. msg)
end

local function warn(msg)
	if console.warn then
		console:warn("[GS-COOP] " .. msg)
	else
		console:error("[GS-COOP] " .. msg)
	end
end

local function splitPipe(line)
	local parts = {}
	local startAt = 1
	while true do
		local at = string.find(line, "|", startAt, true)
		if not at then
			parts[#parts + 1] = string.sub(line, startAt)
			break
		end
		parts[#parts + 1] = string.sub(line, startAt, at - 1)
		startAt = at + 1
	end
	return parts
end

local function toHex(data)
	return (string.gsub(data, ".", function(c)
		return string.format("%02X", string.byte(c))
	end))
end

local function fromHex(hex)
	if not hex or hex == "-" then
		return ""
	end
	if (#hex % 2) ~= 0 then
		return nil
	end
	if not string.match(hex, "^[0-9A-Fa-f]*$") then
		return nil
	end
	return (string.gsub(hex, "%x%x", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

local function encodeField(data)
	if not data or #data == 0 then
		return "-"
	end
	return toHex(data)
end

local function decodeField(text, expectedLen)
	local decoded = fromHex(text)
	if decoded == nil then
		return nil
	end
	if expectedLen and #decoded ~= expectedLen then
		return nil
	end
	return decoded
end

local function readBlock(address, len)
	return emu:readRange(address, len)
end

local function writeBlock(address, data)
	for i = 1, #data do
		emu:write8(address + i - 1, string.byte(data, i))
	end
end

local function read8(address)
	return emu:read8(address)
end

local function write8(address, value)
	emu:write8(address, value & 0xFF)
end

local function currentFrame()
	if emu.currentFrame then
		local ok, value = pcall(function() return emu:currentFrame() end)
		if ok and type(value) == "number" then
			return value
		end
	end
	state.frameFallback = state.frameFallback + 1
	return state.frameFallback
end

local function signedByteDelta(target, origin)
	local d = (target - origin) & 0xFF
	if d >= 0x80 then
		d = d - 0x100
	end
	return d
end

local function stepTowardByte(current, target, maxStep)
	local delta = signedByteDelta(target, current)
	if delta == 0 then
		return current & 0xFF
	end
	local step = delta
	if step > maxStep then
		step = maxStep
	elseif step < -maxStep then
		step = -maxStep
	end
	return (current + step) & 0xFF
end

local function localSyncSafe()
	if read8(ADDR.BATTLE_TYPE) ~= 0 then
		return false
	end
	if read8(ADDR.MAP_STATUS) == 0 then
		return false
	end
	if read8(ADDR.SCRIPT_RUNNING) ~= 0 then
		return false
	end
	if read8(ADDR.H_IN_MENU) ~= 0 then
		return false
	end
	return true
end

local function getGameCode()
	if not emu.getGameCode then
		return ""
	end
	local ok, value = pcall(function()
		return emu:getGameCode()
	end)
	if ok and type(value) == "string" then
		return value
	end
	return ""
end

local function objBaseForSlot(slot)
	return ADDR.OBJ1_BASE + ((slot - 1) * ADDR.OBJ_LEN)
end

local function slotForBase(base)
	return math.floor((base - ADDR.OBJ1_BASE) / ADDR.OBJ_LEN) + 1
end

local function getPlayerStructBase()
	local id = read8(ADDR.PLAYER_OBJECT_STRUCT_ID)
	if id >= 0 and id <= ADDR.OBJ_SLOT_COUNT then
		return ADDR.OBJ0_BASE + (id * ADDR.OBJ_LEN)
	end
	return ADDR.OBJ0_BASE
end

local function readCameraPos()
	return {
		mapGroup = read8(ADDR.MAP_GROUP),
		mapNumber = read8(ADDR.MAP_NUMBER),
		x = read8(ADDR.CAMERA_X),
		y = read8(ADDR.CAMERA_Y),
	}
end

local function readLocalAvatar()
	local b = getPlayerStructBase()
	local mapStatus = read8(ADDR.MAP_STATUS)
	local sprite = read8(ADDR.PLAYER_OBJECT_SPRITE)
	if sprite == 0 then
		sprite = read8(b + O.SPRITE)
	end
	local mapX = read8(ADDR.PLAYER_OBJECT_X)
	local mapY = read8(ADDR.PLAYER_OBJECT_Y)
	if mapX == 0 then
		mapX = read8(b + O.MAP_X)
	end
	if mapY == 0 then
		mapY = read8(b + O.MAP_Y)
	end
	-- Only fall back to camera coords during map transitions (mapStatus < 2).
	-- When the map is active, tile (0,0) is a valid player position and must
	-- not be replaced by the camera origin, which may differ.
	if mapStatus < 2 then
		if mapX == 0 then
			mapX = read8(ADDR.CAMERA_X)
		end
		if mapY == 0 then
			mapY = read8(ADDR.CAMERA_Y)
		end
	end
	local spriteX = read8(b + O.SPRITE_X)
	local spriteY = read8(b + O.SPRITE_Y)
	if spriteX == 0 then
		spriteX = CONST.SCREEN_CENTER_X
	end
	if spriteY == 0 then
		spriteY = CONST.SCREEN_CENTER_Y
	end
	return {
		mapX = mapX,
		mapY = mapY,
		spriteX = spriteX,
		spriteY = spriteY,
		sprite = sprite,
		palette = read8(b + O.PALETTE),
		direction = read8(b + O.DIRECTION),
		facing = read8(b + O.FACING),
		walking = read8(b + O.WALKING),
		stepFrame = read8(b + O.STEP_FRAME),
	}
end

local function readLocalPos()
	local camera = readCameraPos()
	local avatar = readLocalAvatar()
	local worldX = avatar.mapX
	local worldY = avatar.mapY
	if worldX == 0 then
		worldX = camera.x
	end
	if worldY == 0 then
		worldY = camera.y
	end
	return {
		mapGroup = camera.mapGroup,
		mapNumber = camera.mapNumber,
		x = worldX,
		y = worldY,
		cameraX = camera.x,
		cameraY = camera.y,
	}
end

local function buildSnapshot()
	local pos = readLocalPos()
	local avatar = readLocalAvatar()
	local snapshot = {
		frame = currentFrame(),
		mapGroup = pos.mapGroup,
		mapNumber = pos.mapNumber,
		x = pos.x,
		y = pos.y,
		objMapX = avatar.mapX,
		objMapY = avatar.mapY,
		objSprite = avatar.sprite,
		objPalette = avatar.palette,
		objDirection = avatar.direction,
		objFacing = avatar.facing,
		objWalking = avatar.walking,
		objStepFrame = avatar.stepFrame,
		money = "",
		party = "",
		items = "",
	}
	if SYNC_MONEY then
		snapshot.money = readBlock(ADDR.MONEY, ADDR.MONEY_LEN)
	end
	if SYNC_PARTY then
		snapshot.party = readBlock(ADDR.PARTY, ADDR.PARTY_LEN)
	end
	if SYNC_ITEMS then
		snapshot.items = readBlock(ADDR.ITEMS, ADDR.ITEMS_LEN)
	end
	return snapshot
end

local function encodeSnapshot(snapshot)
	return table.concat({
		"P3",
		tostring(snapshot.frame),
		tostring(snapshot.mapGroup),
		tostring(snapshot.mapNumber),
		tostring(snapshot.x),
		tostring(snapshot.y),
		tostring(snapshot.objMapX),
		tostring(snapshot.objMapY),
		tostring(snapshot.objSprite),
		tostring(snapshot.objPalette),
		tostring(snapshot.objDirection),
		tostring(snapshot.objFacing),
		tostring(snapshot.objWalking),
		tostring(snapshot.objStepFrame),
		encodeField(snapshot.money),
		encodeField(snapshot.party),
		encodeField(snapshot.items),
	}, "|") .. "\n"
end

local function decodeSnapshot(line)
	local parts = splitPipe(line)
	if #parts ~= 17 then
		return nil, "invalid part count"
	end
	if parts[1] ~= "P3" then
		return nil, "invalid packet type"
	end

	local values = {}
	for i = 2, 14 do
		values[i] = tonumber(parts[i])
		if not values[i] then
			return nil, "invalid numeric field"
		end
	end

	local money = decodeField(parts[15], parts[15] == "-" and 0 or ADDR.MONEY_LEN)
	local party = decodeField(parts[16], parts[16] == "-" and 0 or ADDR.PARTY_LEN)
	local items = decodeField(parts[17], parts[17] == "-" and 0 or ADDR.ITEMS_LEN)
	if money == nil or party == nil or items == nil then
		return nil, "invalid payload field"
	end

	return {
		frame = values[2],
		mapGroup = values[3],
		mapNumber = values[4],
		x = values[5],
		y = values[6],
		objMapX = values[7],
		objMapY = values[8],
		objSprite = values[9],
		objPalette = values[10],
		objDirection = values[11],
		objFacing = values[12],
		objWalking = values[13],
		objStepFrame = values[14],
		money = money,
		party = party,
		items = items,
	}, nil
end

local function closePeer()
	if state.peer then
		state.peer:close()
		state.peer = nil
	end
	state.rx = ""
end

local function closeServer()
	if state.server then
		state.server:close()
		state.server = nil
	end
end

local function clearPartnerRenderCache()
	state.partnerSpriteX = nil
	state.partnerSpriteY = nil
	state.partnerMapX = nil
	state.partnerMapY = nil
	state.lastRemoteWorldX = nil
	state.lastRemoteWorldY = nil
	state.lastRemoteObjectFrame = -1
end

local function releasePartnerObject()
	if state.partnerBase and state.partnerBackup and #state.partnerBackup == ADDR.OBJ_LEN then
		writeBlock(state.partnerBase, state.partnerBackup)
	elseif state.partnerBase then
		write8(state.partnerBase + O.SPRITE, 0)
	end
	state.partnerBase = nil
	state.partnerBackup = nil
	clearPartnerRenderCache()
end

local function onPeerError(err)
	warn("socket error: " .. tostring(err))
	state.remote = nil
	closePeer()
end

local function processLine(line)
	local snapshot, err = decodeSnapshot(line)
	if not snapshot then
		warn("dropped packet: " .. tostring(err))
		return
	end
	snapshot.receivedFrame = currentFrame()
	-- TCP preserves ordering, so the most recently received packet is authoritative.
	state.remote = snapshot
end

local function processChunk(chunk)
	state.rx = state.rx .. chunk
	while true do
		local newlineAt = string.find(state.rx, "\n", 1, true)
		if not newlineAt then
			break
		end
		local line = string.sub(state.rx, 1, newlineAt - 1)
		state.rx = string.sub(state.rx, newlineAt + 1)
		if #line > 0 then
			processLine(line)
		end
	end
	if #state.rx > 32768 then
		warn("rx buffer reset")
		state.rx = ""
	end
end

local function onPeerReceived()
	if not state.peer then
		return
	end
	while true do
		local chunk, err = state.peer:receive(4096)
		if chunk then
			processChunk(chunk)
		else
			if err ~= socket.ERRORS.AGAIN then
				warn("receive failed: " .. tostring(err))
				state.remote = nil
				closePeer()
			end
			return
		end
	end
end

local function attachPeer(sock, label)
	closePeer()
	state.peer = sock
	state.peer:add("received", onPeerReceived)
	state.peer:add("error", onPeerError)
	log("connected: " .. label)
end

local function onAccept()
	if not state.server then
		return
	end
	local sock, err = state.server:accept()
	if not sock then
		if err and err ~= socket.ERRORS.AGAIN then
			warn("accept failed: " .. tostring(err))
		end
		return
	end
	attachPeer(sock, "incoming client")
end

local function startHost()
	local server, err = socket.bind(nil, PORT)
	if not server then
		warn("bind failed on port " .. tostring(PORT) .. ": " .. tostring(err))
		return
	end
	local ok, listenErr = server:listen()
	if not ok then
		server:close()
		warn("listen failed: " .. tostring(listenErr))
		return
	end
	state.server = server
	state.server:add("received", onAccept)
	log("hosting on port " .. tostring(PORT))
end

local function tryClientConnect()
	local sock = socket.tcp()
	local ok, err = sock:connect(HOST, PORT)
	if not ok then
		sock:close()
		warn("connect failed: " .. tostring(HOST) .. ":" .. tostring(PORT) .. " (" .. tostring(err) .. ")")
		return false
	end
	attachPeer(sock, tostring(HOST) .. ":" .. tostring(PORT))
	return true
end

local function sendSnapshot()
	if not state.peer then
		return
	end
	local packet = encodeSnapshot(buildSnapshot())
	local sent, err = state.peer:send(packet)
	if not sent and err then
		warn("send failed: " .. tostring(err))
		state.remote = nil
		closePeer()
	end
end

local function applyRemoteData()
	if not state.remote then
		return
	end
	if state.remote.frame == state.lastAppliedRemoteFrame then
		return
	end
	if not localSyncSafe() then
		return
	end
	if SYNC_MONEY and #state.remote.money == ADDR.MONEY_LEN then
		local localMoney = readBlock(ADDR.MONEY, ADDR.MONEY_LEN)
		if localMoney ~= state.remote.money then
			writeBlock(ADDR.MONEY, state.remote.money)
		end
	end
	if SYNC_PARTY and #state.remote.party == ADDR.PARTY_LEN then
		local localParty = readBlock(ADDR.PARTY, ADDR.PARTY_LEN)
		if localParty ~= state.remote.party then
			writeBlock(ADDR.PARTY, state.remote.party)
		end
	end
	if SYNC_ITEMS and #state.remote.items == ADDR.ITEMS_LEN then
		local localItems = readBlock(ADDR.ITEMS, ADDR.ITEMS_LEN)
		if localItems ~= state.remote.items then
			writeBlock(ADDR.ITEMS, state.remote.items)
		end
	end
	state.lastAppliedRemoteFrame = state.remote.frame
end

local function applyGoldCosmetic()
	if not FORCE_BLUE_GOLD then
		return
	end
	if getGameCode() ~= "AAUE" then
		return
	end
	local b = getPlayerStructBase()
	-- Read-before-write: only touch RAM when the value actually needs to change.
	-- Writing unconditionally every frame fights scripts that adjust the sprite
	-- temporarily and wastes RAM bus bandwidth.
	if read8(ADDR.PLAYER_OBJECT_SPRITE) ~= CONST.SPRITE_BLUE then
		write8(ADDR.PLAYER_OBJECT_SPRITE, CONST.SPRITE_BLUE)
	end
	if read8(b + O.SPRITE) ~= CONST.SPRITE_BLUE then
		write8(b + O.SPRITE, CONST.SPRITE_BLUE)
	end
end

local function publishSharedState()
	local frame = currentFrame()
	_G.GS_COOP_SHARED = {
		frame = frame,
		mode = MODE,
		connected = state.peer ~= nil,
		localPos = readLocalPos(),
		localAvatar = readLocalAvatar(),
		remote = state.remote,
		remoteAge = remoteAge(frame),
	}
end

local function isMarkedSlot(base)
	return read8(base + O.MARKER_A) == CONST.MARKER_A and read8(base + O.MARKER_B) == CONST.MARKER_B
end

local function markSlot(base)
	write8(base + O.MARKER_A, CONST.MARKER_A)
	write8(base + O.MARKER_B, CONST.MARKER_B)
end

local function claimPartnerSlot()
	if state.partnerBase and isMarkedSlot(state.partnerBase) then
		return state.partnerBase
	end

	local freeBase = nil
	for slot = ADDR.OBJ_SLOT_COUNT, 2, -1 do
		local base = objBaseForSlot(slot)
		if isMarkedSlot(base) then
			state.partnerBase = base
			return base
		end
		if not freeBase and read8(base + O.SPRITE) == 0 then
			freeBase = base
		end
	end

	if freeBase then
		releasePartnerObject()
		state.partnerBase = freeBase
		state.partnerBackup = readBlock(freeBase, ADDR.OBJ_LEN)
		markSlot(freeBase)
		return freeBase
	end

	if not state.warnedNoSlot then
		warn("no empty object slot; overriding slot 12")
		state.warnedNoSlot = true
	end
	releasePartnerObject()
	state.partnerBase = objBaseForSlot(ADDR.OBJ_SLOT_COUNT)
	state.partnerBackup = readBlock(state.partnerBase, ADDR.OBJ_LEN)
	markSlot(state.partnerBase)
	return state.partnerBase
end

local function hidePartnerObject()
	local base = state.partnerBase
	if not base then
		clearPartnerRenderCache()
		return
	end
	local flags1 = read8(base + O.FLAGS1)
	flags1 = flags1 | BITS.INVISIBLE | BITS.WONT_DELETE
	write8(base + O.FLAGS1, flags1)
	clearPartnerRenderCache()
end

local function showPartnerObject(remote)
	local base = claimPartnerSlot()
	if not base then
		return
	end

	local localPos = readLocalPos()
	local localAvatar = readLocalAvatar()
	local sprite = remote.objSprite
	if sprite == 0 then
		sprite = 0x01
	end
	-- Use world/object coordinates for both peers. wXCoord/wYCoord are camera-space
	-- origins in Gen 2, while OBJECT_MAP_* tracks the trainer's actual map tile.
	local mapX = remote.objMapX or remote.x or localPos.x
	local mapY = remote.objMapY or remote.y or localPos.y

	local dxTiles = signedByteDelta(mapX, localAvatar.mapX)
	local dyTiles = signedByteDelta(mapY, localAvatar.mapY)
	if math.abs(dxTiles) > MAX_RENDER_DISTANCE_TILES or math.abs(dyTiles) > MAX_RENDER_DISTANCE_TILES then
		hidePartnerObject()
		return
	end

	local flags1 = BITS.WONT_DELETE | BITS.MOVE_ANYWHERE
	local flags2 = read8(base + O.FLAGS2)
	flags2 = flags2 & (~BITS.OFF_SCREEN & 0xFF)
	local anchorX = localAvatar.spriteX
	local anchorY = localAvatar.spriteY
	if anchorX == 0 then
		anchorX = CONST.SCREEN_CENTER_X
	end
	if anchorY == 0 then
		anchorY = CONST.SCREEN_CENTER_Y
	end
	-- One overworld step is 16 px in Gen 2 (metatile grid), not 8 px.
	local targetSpriteX = (anchorX + (dxTiles * OVERWORLD_STEP_PIXELS)) & 0xFF
	local targetSpriteY = (anchorY + (dyTiles * OVERWORLD_STEP_PIXELS)) & 0xFF
	local spriteX = targetSpriteX
	local spriteY = targetSpriteY
	if state.partnerSpriteX ~= nil and state.partnerSpriteY ~= nil then
		local distX = math.abs(signedByteDelta(targetSpriteX, state.partnerSpriteX))
		local distY = math.abs(signedByteDelta(targetSpriteY, state.partnerSpriteY))
		if distX <= PARTNER_TELEPORT_PIXELS and distY <= PARTNER_TELEPORT_PIXELS then
			spriteX = stepTowardByte(state.partnerSpriteX, targetSpriteX, PARTNER_SMOOTHING_PIXELS)
			spriteY = stepTowardByte(state.partnerSpriteY, targetSpriteY, PARTNER_SMOOTHING_PIXELS)
		end
	end
	local direction = remote.objDirection or CONST.DIR_DOWN
	local facing = remote.objFacing or direction
	local mdx = 0
	local mdy = 0
	local remoteMotionX = mapX
	local remoteMotionY = mapY
	if state.lastRemoteWorldX ~= nil and state.lastRemoteWorldY ~= nil then
		mdx = signedByteDelta(remoteMotionX, state.lastRemoteWorldX)
		mdy = signedByteDelta(remoteMotionY, state.lastRemoteWorldY)
	end
	if mdx ~= 0 or mdy ~= 0 then
		if math.abs(mdx) >= math.abs(mdy) then
			direction = mdx > 0 and CONST.DIR_RIGHT or CONST.DIR_LEFT
		else
			direction = mdy > 0 and CONST.DIR_DOWN or CONST.DIR_UP
		end
		facing = direction
	end
	local walking = ((mdx ~= 0 or mdy ~= 0) and 1) or (remote.objWalking or 0)
	local stepFrame = remote.objStepFrame or ((walking ~= 0 and ((currentFrame() >> 1) & 1)) or 0)

	write8(base + O.SPRITE, sprite)
	write8(base + O.MAP_OBJECT_INDEX, 0xFF)
	write8(base + O.MOVEMENT_TYPE, CONST.SPRITEMOVEDATA_STILL)
	write8(base + O.FLAGS1, flags1)
	write8(base + O.FLAGS2, flags2)
	write8(base + O.PALETTE, remote.objPalette)
	write8(base + O.WALKING, walking)
	write8(base + O.DIRECTION, direction)
	write8(base + O.STEP_TYPE, CONST.STEP_TYPE_STANDING)
	write8(base + O.ACTION, CONST.OBJECT_ACTION_STAND)
	write8(base + O.STEP_FRAME, stepFrame)
	write8(base + O.FACING, facing)
	write8(base + O.MAP_X, mapX)
	write8(base + O.MAP_Y, mapY)
	write8(base + O.LAST_MAP_X, mapX)
	write8(base + O.LAST_MAP_Y, mapY)
	write8(base + O.INIT_X, mapX)
	write8(base + O.INIT_Y, mapY)
	write8(base + O.SPRITE_X, spriteX)
	write8(base + O.SPRITE_Y, spriteY)
	write8(base + O.SPRITE_X_OFFSET, 0)
	write8(base + O.SPRITE_Y_OFFSET, 0)
	write8(base + O.RADIUS, 0)
	markSlot(base)
	state.partnerSpriteX = spriteX
	state.partnerSpriteY = spriteY
	state.partnerMapX = mapX
	state.partnerMapY = mapY
	state.lastRemoteWorldX = remoteMotionX
	state.lastRemoteWorldY = remoteMotionY
	state.lastRemoteObjectFrame = remote.frame or -1
end

local function applyRemoteObject()
	local frame = currentFrame()
	if read8(ADDR.MAP_STATUS) == 0 then
		hidePartnerObject()
		return
	end
	if not state.remote then
		hidePartnerObject()
		return
	end
	local age = remoteAge(frame)
	if age and age > STALE_REMOTE_FRAMES then
		hidePartnerObject()
		return
	end

	local pos = readLocalPos()
	local sameMap = state.remote.mapGroup == pos.mapGroup and state.remote.mapNumber == pos.mapNumber
	if not sameMap then
		hidePartnerObject()
		return
	end

	showPartnerObject(state.remote)
end

local function initHud()
	state.hud = console:createBuffer("GS Co-op")
	state.hud:setSize(82, 14)
end

local function updateHud()
	if not state.hud then
		return
	end
	local frame = currentFrame()
	local pos = readLocalPos()
	local title = "UNKNOWN"
	if emu.getGameTitle then
		local ok, value = pcall(function() return emu:getGameTitle() end)
		if ok and value and value ~= "" then
			title = value
		end
	elseif emu.getGameCode then
		local ok, value = pcall(function() return emu:getGameCode() end)
		if ok and value and value ~= "" then
			title = value
		end
	end

	state.hud:clear()
	state.hud:print("Mode: " .. MODE .. "   Game: " .. title .. "\n")
	state.hud:print("Socket: " .. (state.peer and "connected" or "waiting") .. "\n")
	state.hud:print(string.format("Local map %d-%d  x:%d y:%d  cam:%d,%d\n", pos.mapGroup, pos.mapNumber, pos.x, pos.y, pos.cameraX or 0, pos.cameraY or 0))

	if state.remote then
		local age = remoteAge(frame) or -1
		local sameMap = state.remote.mapGroup == pos.mapGroup and state.remote.mapNumber == pos.mapNumber
		state.hud:print(string.format("Peer  map %d-%d  x:%d y:%d  age:%d\n", state.remote.mapGroup, state.remote.mapNumber, state.remote.x, state.remote.y, age))
		state.hud:print("In-world sprite: " .. (sameMap and "visible" or "hidden (other map)") .. "\n")
	end
	if not state.remote then
		state.hud:print("Peer: waiting for packet\n")
	end

	if state.partnerBase then
		local slot = slotForBase(state.partnerBase)
		state.hud:print("Partner slot: " .. tostring(slot) .. "\n")
	else
		state.hud:print("Partner slot: unclaimed\n")
	end
	state.hud:print(string.format("Sync party:%s items:%s money:%s\n", tostring(SYNC_PARTY), tostring(SYNC_ITEMS), tostring(SYNC_MONEY)))
	state.hud:print(string.format("Render range:%dt smooth:%dpx\n", MAX_RENDER_DISTANCE_TILES, PARTNER_SMOOTHING_PIXELS))
	state.hud:print("Battle/trade still use mGBA link club.\n")
end

local function startup()
	closePeer()
	closeServer()
	releasePartnerObject()

	state.remote = nil
	state.rx = ""
	state.lastSentFrame = -1
	state.lastHudFrame = -1
	state.lastApplyFrame = -1
	state.lastObjectFrame = -1
	state.lastAppliedRemoteFrame = -1
	state.nextReconnectFrame = 0
	state.partnerBase = nil
	state.partnerBackup = nil
	clearPartnerRenderCache()
	state.warnedNoSlot = false

	if MODE == "host" then
		startHost()
	else
		log("client mode; target " .. tostring(HOST) .. ":" .. tostring(PORT))
	end
end

local function shutdown()
	releasePartnerObject()
	closePeer()
	closeServer()
end

local function onFrame()
	local frame = currentFrame()
	applyGoldCosmetic()
	publishSharedState()

	if MODE == "client" and not state.peer and frame >= state.nextReconnectFrame then
		tryClientConnect()
		state.nextReconnectFrame = frame + RECONNECT_INTERVAL
	end

	if state.peer and (state.lastSentFrame < 0 or (frame - state.lastSentFrame) >= SYNC_INTERVAL) then
		sendSnapshot()
		state.lastSentFrame = frame
	end

	if state.remote and (state.lastApplyFrame < 0 or (frame - state.lastApplyFrame) >= APPLY_INTERVAL) then
		-- Only advance the timer when the write actually ran.  If localSyncSafe()
		-- bails (menu, battle, transition), we keep retrying next frame so the
		-- sync catches up immediately on exit rather than waiting another full
		-- APPLY_INTERVAL after the menu closes.
		if localSyncSafe() then
			applyRemoteData()
			state.lastApplyFrame = frame
		end
	end

	if state.lastObjectFrame < 0 or (frame - state.lastObjectFrame) >= OBJECT_INTERVAL then
		applyRemoteObject()
		state.lastObjectFrame = frame
	end

	if state.lastHudFrame < 0 or (frame - state.lastHudFrame) >= HUD_INTERVAL then
		updateHud()
		state.lastHudFrame = frame
	end
end

initHud()
startup()

addCallback("start", startup)
addCallback("reset", startup)
addCallback("stop", shutdown)
addCallback("crashed", shutdown)
addCallback("frame", onFrame)
registerUnload(shutdown)
