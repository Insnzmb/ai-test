local CONFIG = rawget(_G, "GS_SILVER_AGENT_CONFIG") or {}

local ENABLED = CONFIG.enabled ~= false
local PORT = CONFIG.port or 58888
local STATE_INTERVAL = CONFIG.state_interval_frames or 2
local REMOTE_STALE_FRAMES = CONFIG.remote_stale_frames or 120
local BLOCK_HUMAN_INPUT = CONFIG.block_human_input ~= false

local KEY_A = 1 << 0
local KEY_B = 1 << 1
local KEY_SELECT = 1 << 2
local KEY_START = 1 << 3
local KEY_LEFT = 1 << 4
local KEY_RIGHT = 1 << 5
local KEY_UP = 1 << 6
local KEY_DOWN = 1 << 7
local VALID_KEY_MASK = KEY_A | KEY_B | KEY_SELECT | KEY_START | KEY_LEFT | KEY_RIGHT | KEY_UP | KEY_DOWN

local ADDR = {
	MAP_GROUP = 0xDA00,
	MAP_NUMBER = 0xDA01,
	MAP_Y = 0xDA02,
	MAP_X = 0xDA03,
	PLAYER_OBJECT_Y = 0xD447,
	PLAYER_OBJECT_X = 0xD448,
	BATTLE_MODE = 0xD116,
	BATTLE_TYPE = 0xD119,
	SCRIPT_RUNNING = 0xD15F,
	MENU_Y = 0xCEE0,
	MENU_X = 0xCEE1,
	IN_MENU = 0xFFAC,
	PARTY_COUNT = 0xDA22,
	NUM_BALLS = 0xD5FC,
	ENEMY_HP = 0xD0FF,
	ENEMY_SPECIES = 0xD0EF,
	BATTLE_MENU_POS = 0xCFC4,
	JOYPAD_DISABLE = 0xD8BA,
	NAMING_TYPE = 0xC5D4,
	MENU_ITEMS = 0xCEC9,
	MENU_TOP = 0xCEB9,
	MENU_LEFT = 0xCEBA,
	MENU_BOTTOM = 0xCEBB,
	MENU_RIGHT = 0xCEBC,
	MAP_STATUS = 0xD159,
	PLAYERS_HOUSE_1F_SCENE = 0xD6CD,
	SCRIPT_BANK = 0xD160,
	SCRIPT_POS = 0xD161,
	BADGES_JOHTO = 0xD57C,
	BADGES_KANTO = 0xD57D,
	-- Pokedex
	POKEDEX_CAUGHT = 0xDBE4,   -- 32 bytes (bit array, 251 Pokemon)
	POKEDEX_SEEN   = 0xDC04,   -- 32 bytes
	-- Party detail
	PARTY_MONS     = 0xDA2A,   -- 6 * 48-byte structs
	-- Items
	NUM_ITEMS      = 0xD5B7,
	NUM_KEY_ITEMS  = 0xD5E1,
	-- Event flags
	EVENT_FLAGS    = 0xD7B7,   -- 256 bytes (2048 bits)
}

local state = {
	enabled = false,
	server = nil,
	client = nil,
	rx = "",
	aiKeys = 0,
	aiTtl = 0,
	keysReadCount = 0,
	lastSend = -1,
	lastMapGroup = -1,
	lastMapNumber = -1,
	lastX = -1,
	lastY = -1,
	stallFrames = 0,
	frameFallback = 0,
	manualMode = false,   -- true = human has control, AI injection paused
}

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
	console:log("[GS-SILVER-AI] " .. msg)
end

local function warn(msg)
	if console.warn then
		console:warn("[GS-SILVER-AI] " .. msg)
	else
		console:error("[GS-SILVER-AI] " .. msg)
	end
end

local function currentFrame()
	if emu.currentFrame then
		local ok, value = pcall(function()
			return emu:currentFrame()
		end)
		if ok and type(value) == "number" then
			return value
		end
	end
	state.frameFallback = state.frameFallback + 1
	return state.frameFallback
end

local function read8(address)
	return emu:read8(address)
end

local function write8(address, value)
	emu:write8(address, value & 0xFF)
end

local function read16BE(address)
	return (read8(address) << 8) | read8(address + 1)
end

local function read16LE(address)
	return read8(address) | (read8(address + 1) << 8)
end

local function readPlayerMapPos()
	local x = read8(ADDR.PLAYER_OBJECT_X)
	local y = read8(ADDR.PLAYER_OBJECT_Y)
	-- Early boot/menu states can report 0 for object coords.
	if x == 0 then
		x = read8(ADDR.MAP_X)
	end
	if y == 0 then
		y = read8(ADDR.MAP_Y)
	end
	return x, y
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

local function closeClient()
	if state.client then
		state.client:close()
		state.client = nil
	end
	state.rx = ""
	state.aiKeys = 0
	state.aiTtl = 0
end

local function closeServer()
	if state.server then
		state.server:close()
		state.server = nil
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

local function onClientError(err)
	warn("bridge error: " .. tostring(err))
	closeClient()
end

local function parseControlLine(line)
	local parts = splitPipe(line)
	if #parts < 3 then return false end
	if parts[1] ~= "C" then return false end
	if parts[2] == "manual" then
		if parts[3] == "1" or parts[3] == "on" then
			state.manualMode = true
			state.aiTtl = 0
			state.aiKeys = 0
			log("manual mode ON  - human has control (F12 to release)")
		elseif parts[3] == "0" or parts[3] == "off" then
			state.manualMode = false
			log("manual mode OFF - AI resumed")
		end
		return true
	end
	return false
end

local function parseActionLine(line)
	local parts = splitPipe(line)
	if #parts < 3 then
		return false
	end
	if parts[1] ~= "A" then
		return false
	end
	local keys = tonumber(parts[2]) or 0
	local ttl = tonumber(parts[3]) or 1
	keys = keys & VALID_KEY_MASK
	if ttl < 1 then
		ttl = 1
	end
	if ttl > 12 then
		ttl = 12
	end
	state.aiKeys = keys
	state.aiTtl = ttl
	return true
end

local function processChunk(chunk)
	state.rx = state.rx .. chunk
	while true do
		local at = string.find(state.rx, "\n", 1, true)
		if not at then
			break
		end
		local line = string.sub(state.rx, 1, at - 1)
		state.rx = string.sub(state.rx, at + 1)
		if #line > 0 then
			if not parseControlLine(line) then
				parseActionLine(line)
			end
		end
	end
	if #state.rx > 16384 then
		state.rx = ""
	end
end

local function onClientReceived()
	if not state.client then
		return
	end
	while true do
		local chunk, err = state.client:receive(4096)
		if chunk then
			processChunk(chunk)
		else
			if err ~= socket.ERRORS.AGAIN then
				warn("bridge receive failed: " .. tostring(err))
				closeClient()
			end
			return
		end
	end
end

local function attachClient(sock)
	closeClient()
	state.client = sock
	state.client:add("received", onClientReceived)
	state.client:add("error", onClientError)
	log("bridge connected on 127.0.0.1:" .. tostring(PORT))
end

local function onAccept()
	if not state.server then
		return
	end
	local sock, err = state.server:accept()
	if not sock then
		if err and err ~= socket.ERRORS.AGAIN then
			warn("bridge accept failed: " .. tostring(err))
		end
		return
	end
	attachClient(sock)
end

local function startServer()
	local server, err = socket.bind("127.0.0.1", PORT)
	if not server then
		warn("bridge bind failed on " .. tostring(PORT) .. ": " .. tostring(err))
		return false
	end
	local ok, listenErr = server:listen()
	if not ok then
		server:close()
		warn("bridge listen failed: " .. tostring(listenErr))
		return false
	end
	state.server = server
	state.server:add("received", onAccept)
	log("waiting for Ollama bridge on 127.0.0.1:" .. tostring(PORT))
	return true
end

local PARTYMON_SIZE = 0x30 -- 48 bytes per party mon
local MON_SPECIES = 0x00
local MON_LEVEL   = 0x1F
local MON_HP      = 0x22   -- 2 bytes big-endian
local MON_MAXHP   = 0x24   -- 2 bytes big-endian

local function countDexCaught()
	local count = 0
	for i = 0, 31 do
		local b = read8(ADDR.POKEDEX_CAUGHT + i)
		-- count set bits
		while b > 0 do
			count = count + (b & 1)
			b = b >> 1
		end
	end
	return count
end

local function countDexSeen()
	local count = 0
	for i = 0, 31 do
		local b = read8(ADDR.POKEDEX_SEEN + i)
		while b > 0 do
			count = count + (b & 1)
			b = b >> 1
		end
	end
	return count
end

local function readEventBit(bitIndex)
	local byteOff = math.floor(bitIndex / 8)
	local bitMask = 1 << (bitIndex % 8)
	local val = read8(ADDR.EVENT_FLAGS + byteOff)
	if (val & bitMask) ~= 0 then return 1 end
	return 0
end

local function partySpeciesStr()
	-- Returns "species1:level1:hp1:maxhp1,species2:level2:hp2:maxhp2,..."
	local count = read8(ADDR.PARTY_COUNT)
	if count < 1 or count > 6 then return "0" end
	local parts = {}
	for i = 0, count - 1 do
		local base = ADDR.PARTY_MONS + (i * PARTYMON_SIZE)
		local sp  = read8(base + MON_SPECIES)
		local lv  = read8(base + MON_LEVEL)
		local hp  = read16BE(base + MON_HP)
		local mhp = read16BE(base + MON_MAXHP)
		parts[#parts + 1] = sp .. ":" .. lv .. ":" .. hp .. ":" .. mhp
	end
	return table.concat(parts, ",")
end

local function buildStateLine()
	local frameNow = currentFrame()
	local localX, localY = readPlayerMapPos()
	local shared = rawget(_G, "GS_COOP_SHARED")
	local remote = nil
	local sharedFrame = frameNow
	local remoteAge = nil
	if shared then
		if shared.connected ~= false then
			remote = shared.remote
		end
		sharedFrame = shared.frame or frameNow
		remoteAge = tonumber(shared.remoteAge)
		if remoteAge == nil and remote and type(remote.receivedFrame) == "number" then
			remoteAge = sharedFrame - remote.receivedFrame
		end
	end
	local hostMapGroup = -1
	local hostMapNumber = -1
	local hostX = -1
	local hostY = -1
	if remote then
		local age = remoteAge
		if age == nil then
			age = 0
		end
		if age < 0 then
			age = 0
		end
		if age <= REMOTE_STALE_FRAMES then
		hostMapGroup = remote.mapGroup or -1
		hostMapNumber = remote.mapNumber or -1
		hostX = remote.objMapX or remote.x or -1
		hostY = remote.objMapY or remote.y or -1
		end
	end
	return table.concat({
		"S",
		tostring(frameNow),
		tostring(read8(ADDR.MAP_GROUP)),
		tostring(read8(ADDR.MAP_NUMBER)),
		tostring(localX),
		tostring(localY),
		tostring(hostMapGroup),
		tostring(hostMapNumber),
		tostring(hostX),
		tostring(hostY),
		tostring(read8(ADDR.BATTLE_MODE)),
		tostring(read8(ADDR.BATTLE_TYPE)),
		tostring(read8(ADDR.IN_MENU)),
		tostring(read8(ADDR.SCRIPT_RUNNING)),
		tostring(read8(ADDR.MENU_Y)),
		tostring(read8(ADDR.MENU_X)),
		tostring(read8(ADDR.PARTY_COUNT)),
		tostring(read8(ADDR.NUM_BALLS)),
		tostring(read16BE(ADDR.ENEMY_HP)),
		tostring(read8(ADDR.ENEMY_SPECIES)),
		tostring(read8(ADDR.BATTLE_MENU_POS)),
		tostring(read8(ADDR.JOYPAD_DISABLE)),
		tostring(read8(ADDR.NAMING_TYPE)),
		tostring(read8(ADDR.MENU_ITEMS)),
		tostring(read8(ADDR.MENU_TOP)),
		tostring(read8(ADDR.MENU_LEFT)),
		tostring(read8(ADDR.MENU_BOTTOM)),
		tostring(read8(ADDR.MENU_RIGHT)),
		tostring(read8(ADDR.MAP_STATUS)),
		tostring(read8(ADDR.PLAYERS_HOUSE_1F_SCENE)),
		tostring(read8(ADDR.SCRIPT_BANK)),
		tostring(read16LE(ADDR.SCRIPT_POS)),
		tostring(read8(ADDR.BADGES_JOHTO)),
		tostring(read8(ADDR.BADGES_KANTO)),
		tostring(state.aiTtl or 0),
		tostring(state.aiKeys or 0),
		tostring(emu:getKeys() or 0),
		tostring(state.keysReadCount or 0),
		-- Extended telemetry (indices 37+)
		tostring(countDexCaught()),           -- 37: pokedex caught count
		tostring(countDexSeen()),             -- 38: pokedex seen count
		tostring(read8(ADDR.NUM_ITEMS)),      -- 39: bag item count
		tostring(read8(ADDR.NUM_KEY_ITEMS)),  -- 40: key item count
		partySpeciesStr(),                    -- 41: party detail "sp:lv:hp:mhp,..."
		tostring(readEventBit(68)),           -- 42: beat elite four (EVENT 68)
		tostring(readEventBit(1205)),         -- 43: red in mt silver (EVENT 1205)
	}, "|") .. "\n"
end

local function sendState()
	if not state.client then
		return
	end
	local now = currentFrame()
	if state.lastSend >= 0 and (now - state.lastSend) < STATE_INTERVAL then
		return
	end
	local line = buildStateLine()
	local sent, err = state.client:send(line)
	if not sent and err then
		warn("bridge send failed: " .. tostring(err))
		closeClient()
		return
	end
	state.lastSend = now
end

local function applyInjectedKeys()
	if not state.enabled then
		return
	end

	-- Manual mode: human has full control — don't strip input, don't inject AI keys.
	if state.manualMode then
		return
	end

	local keys = emu:getKeys()
	if BLOCK_HUMAN_INPUT then
		keys = keys & (~VALID_KEY_MASK & 0xFFFFFFFF)
	end

	local injected = 0
	local bg = rawget(_G, "GS_BG_INPUT_STATE")
	if bg and (bg.keys or 0) ~= 0 and (bg.ttl or 0) > 0 then
		injected = (bg.keys or 0) & VALID_KEY_MASK
	elseif state.aiTtl > 0 and state.aiKeys ~= 0 then
		injected = state.aiKeys & VALID_KEY_MASK
	end

	if injected ~= 0 then
		keys = keys | injected
		emu:setKeys(keys)
	elseif BLOCK_HUMAN_INPUT then
		emu:setKeys(keys)
	end
end

local function onKeysRead()
	state.keysReadCount = (state.keysReadCount or 0) + 1
	-- Inject on key-read timing for reliable menu confirms.
	-- onFrame injection remains as a fallback when keysRead cadence is sparse.
	applyInjectedKeys()
end

local function onFrame()
	if not state.enabled then
		return
	end
	applyInjectedKeys()
	if state.aiTtl > 0 then
		state.aiTtl = state.aiTtl - 1
	end

	local mapGroup = read8(ADDR.MAP_GROUP)
	local mapNumber = read8(ADDR.MAP_NUMBER)
	local x, y = readPlayerMapPos()
	local scriptRunning = read8(ADDR.SCRIPT_RUNNING)
	local inMenu = read8(ADDR.IN_MENU)
	local battleMode = read8(ADDR.BATTLE_MODE)
	local mapStatus = read8(ADDR.MAP_STATUS)

	if mapGroup == state.lastMapGroup and mapNumber == state.lastMapNumber and x == state.lastX and y == state.lastY then
		state.stallFrames = state.stallFrames + 1
	else
		state.stallFrames = 0
	end
	state.lastMapGroup = mapGroup
	state.lastMapNumber = mapNumber
	state.lastX = x
	state.lastY = y

	-- Safety: recover from hard-stuck script/menu lock in idle intro/script states.
	-- Do not force-clear on the player's home maps, where long scripted sequences
	-- (mom intro / stairs transitions) legitimately hold script 0xFF.
	local homeIntroMap = (mapGroup == 24 and (mapNumber == 6 or mapNumber == 7))
	if mapGroup == 24 and mapNumber == 7 and battleMode == 0 and mapStatus >= 2 and state.stallFrames >= 180 and read8(ADDR.PARTY_COUNT) == 0 then
		-- Keep input unlocked on 2F intro if the game wedges controls.
		write8(ADDR.JOYPAD_DISABLE, 0)
		write8(ADDR.IN_MENU, 0)
	end
	if mapGroup == 24 and mapNumber == 7 and scriptRunning == 0xFF and battleMode == 0 and mapStatus >= 2 and state.stallFrames >= 240 and read8(ADDR.PARTY_COUNT) == 0 then
		-- 2F wake-up can hard-lock in script 0xFF with no movement.
		-- Place Silver at the stair lane and release script/input lock.
		write8(ADDR.PLAYER_OBJECT_X, 7)
		write8(ADDR.PLAYER_OBJECT_Y, 1)
		write8(ADDR.MAP_X, 7)
		write8(ADDR.MAP_Y, 1)
		write8(ADDR.SCRIPT_RUNNING, 0)
		write8(ADDR.JOYPAD_DISABLE, 0)
		write8(ADDR.IN_MENU, 0)
		state.stallFrames = 0
		log("watchdog: nudged 2F intro toward stairs")
	end
	if mapGroup == 24 and mapNumber == 7 and battleMode == 0 and mapStatus >= 2 and state.stallFrames >= 420 and read8(ADDR.PARTY_COUNT) == 0 then
		-- Final recovery: force transition to 1F so co-op can proceed.
		write8(ADDR.MAP_GROUP, 24)
		write8(ADDR.MAP_NUMBER, 6)
		write8(ADDR.PLAYER_OBJECT_X, 8)
		write8(ADDR.PLAYER_OBJECT_Y, 4)
		write8(ADDR.MAP_X, 8)
		write8(ADDR.MAP_Y, 4)
		write8(ADDR.SCRIPT_RUNNING, 0)
		write8(ADDR.JOYPAD_DISABLE, 0)
		write8(ADDR.IN_MENU, 0)
		state.stallFrames = 0
		log("watchdog: hard-warped intro from 2F to 1F")
	end
	if mapGroup == 24 and mapNumber == 6 and scriptRunning == 0xFF and battleMode == 0 and mapStatus >= 2 and state.stallFrames >= 300 then
		-- If the 1F intro script wedges on the stair landing, place the player
		-- near mom's trigger lane and release controls so story can continue.
		write8(ADDR.PLAYER_OBJECT_X, 8)
		write8(ADDR.PLAYER_OBJECT_Y, 4)
		write8(ADDR.MAP_X, 8)
		write8(ADDR.MAP_Y, 4)
		write8(ADDR.SCRIPT_RUNNING, 0)
		write8(ADDR.JOYPAD_DISABLE, 0)
		write8(ADDR.IN_MENU, 0)
		state.stallFrames = 0
		log("watchdog: nudged 1F intro from stairs to mom trigger")
	end
	if mapGroup == 24 and mapNumber == 6 and battleMode == 0 and mapStatus >= 2 and state.stallFrames >= 240 and read8(ADDR.PARTY_COUNT) == 0 then
		-- Some builds can loop near mom's lane without ever advancing scene state.
		-- Move toward the house exit lane and unlock input/script so flow can resume.
		write8(ADDR.PLAYER_OBJECT_X, 6)
		write8(ADDR.PLAYER_OBJECT_Y, 7)
		write8(ADDR.MAP_X, 6)
		write8(ADDR.MAP_Y, 7)
		write8(ADDR.SCRIPT_RUNNING, 0)
		write8(ADDR.JOYPAD_DISABLE, 0)
		write8(ADDR.IN_MENU, 0)
		state.stallFrames = 0
		log("watchdog: relocated 1F intro from mom-lock to exit lane")
	end
	if scriptRunning == 0xFF and battleMode == 0 and mapStatus >= 2 and state.stallFrames >= 240 and not homeIntroMap then
		write8(ADDR.SCRIPT_RUNNING, 0)
		write8(ADDR.JOYPAD_DISABLE, 0)
		write8(ADDR.IN_MENU, 0)
		state.stallFrames = 0
		log("watchdog: cleared stuck script/menu/jpad lock")
	end

	sendState()
end

local function startup()
	closeClient()
	closeServer()
	state.lastSend = -1
	state.aiKeys = 0
	state.aiTtl = 0
	state.keysReadCount = 0
	state.lastMapGroup = -1
	state.lastMapNumber = -1
	state.lastX = -1
	state.lastY = -1
	state.stallFrames = 0
	state.frameFallback = 0
	state.enabled = false

	if not ENABLED then
		log("disabled by config")
		return
	end
	local code = getGameCode()
	if code ~= "" and code ~= "AAXE" then
		log("non-silver ROM detected; disabled")
		return
	end
	if startServer() then
		state.enabled = true
	end
end

local function shutdown()
	closeClient()
	closeServer()
	state.enabled = false
end

startup()
addCallback("start", startup)
addCallback("reset", startup)
addCallback("stop", shutdown)
addCallback("crashed", shutdown)
addCallback("frame", onFrame)
addCallback("keysRead", onKeysRead)
registerUnload(shutdown)
