local CONFIG = rawget(_G, "GS_BG_INPUT_CONFIG") or {}

local ENABLED = CONFIG.enabled ~= false
local PORT = CONFIG.port or 58891
local STATE_INTERVAL = CONFIG.state_interval_frames or 30

local KEY_A = 1 << 0
local KEY_B = 1 << 1
local KEY_SELECT = 1 << 2
local KEY_START = 1 << 3
local KEY_LEFT = 1 << 4
local KEY_RIGHT = 1 << 5
local KEY_UP = 1 << 6
local KEY_DOWN = 1 << 7
local VALID_KEY_MASK = KEY_A | KEY_B | KEY_SELECT | KEY_START | KEY_LEFT | KEY_RIGHT | KEY_UP | KEY_DOWN

local state = {
	enabled = false,
	server = nil,
	client = nil,
	rx = "",
	keys = 0,
	ttl = 0,
	lastStatePublish = -1,
	frameFallback = 0,
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
	console:log("[GS-BG-INPUT] " .. msg)
end

local function warn(msg)
	if console.warn then
		console:warn("[GS-BG-INPUT] " .. msg)
	else
		console:error("[GS-BG-INPUT] " .. msg)
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

local function closeClient()
	if state.client then
		state.client:close()
		state.client = nil
	end
	state.rx = ""
	state.keys = 0
	state.ttl = 0
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

local function publishState(force)
	local now = currentFrame()
	if not force and state.lastStatePublish >= 0 and (now - state.lastStatePublish) < STATE_INTERVAL then
		return
	end
	_G.GS_BG_INPUT_STATE = {
		keys = state.keys,
		ttl = state.ttl,
		enabled = state.enabled,
		port = PORT,
		connected = state.client ~= nil,
	}
	state.lastStatePublish = now
end

local function onClientError(err)
	warn("bridge error: " .. tostring(err))
	closeClient()
	publishState(true)
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
	state.keys = keys
	state.ttl = ttl
	publishState(true)
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
			parseActionLine(line)
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
				publishState(true)
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
	publishState(true)
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
	log("waiting for keyboard bridge on 127.0.0.1:" .. tostring(PORT))
	return true
end

local function onKeysRead()
	if not state.enabled then
		return
	end
	if state.ttl <= 0 or state.keys == 0 then
		publishState(false)
		return
	end
	local keys = emu:getKeys()
	keys = keys | state.keys
	emu:setKeys(keys)
	state.ttl = state.ttl - 1
	publishState(false)
end

local function startup()
	closeClient()
	closeServer()
	state.keys = 0
	state.ttl = 0
	state.lastStatePublish = -1
	state.frameFallback = 0
	state.enabled = false

	if not ENABLED then
		log("disabled by config")
		publishState(true)
		return
	end
	if startServer() then
		state.enabled = true
	end
	publishState(true)
end

local function shutdown()
	closeClient()
	closeServer()
	state.enabled = false
	publishState(true)
end

startup()
addCallback("start", startup)
addCallback("reset", startup)
addCallback("stop", shutdown)
addCallback("crashed", shutdown)
addCallback("keysRead", onKeysRead)
registerUnload(shutdown)
