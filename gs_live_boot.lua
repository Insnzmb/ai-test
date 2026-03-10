local CONFIG = rawget(_G, "GS_LIVE_BOOT_CONFIG") or {}

local ENTRY = CONFIG.entry or "gs_coop_host.lua"
local CONTROL_PORT = CONFIG.control_port or 58901
local LABEL = CONFIG.label or "live"

local state = {
	server = nil,
	client = nil,
	rx = "",
	pendingReload = false,
	pendingReason = "remote",
	lastReloadStatus = "none",
	lastReloadFrame = -999999,
	frameFallback = 0,
}

local function log(msg)
	console:log("[GS-LIVE-" .. LABEL .. "] " .. msg)
end

local function warn(msg)
	if console.warn then
		console:warn("[GS-LIVE-" .. LABEL .. "] " .. msg)
	else
		console:error("[GS-LIVE-" .. LABEL .. "] " .. msg)
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

local function resolvePath(path)
	if type(path) ~= "string" then
		return script.dir .. "/gs_coop_host.lua"
	end
	if #path >= 2 and string.sub(path, 2, 2) == ":" then
		return path
	end
	if string.sub(path, 1, 1) == "/" then
		return path
	end
	return script.dir .. "/" .. path
end

local function closeClient()
	if state.client then
		state.client:close()
		state.client = nil
	end
	state.rx = ""
end

local function closeServer()
	if state.server then
		state.server:close()
		state.server = nil
	end
end

local function doReload(reason)
	local frame = currentFrame()
	if (frame - state.lastReloadFrame) < 6 then
		state.lastReloadStatus = "throttled"
		return false, "reload throttled"
	end
	state.lastReloadFrame = frame
	state.lastReloadStatus = "loading"

	local runtime = rawget(_G, "GS_RUNTIME")
	if runtime and type(runtime.unloadAll) == "function" then
		pcall(function()
			runtime.unloadAll()
		end)
	end

	local entryPath = resolvePath(ENTRY)
	local ok, err = pcall(function()
		dofile(script.dir .. "/gs_runtime.lua")
		dofile(entryPath)
	end)
	if not ok then
		warn("reload failed (" .. tostring(reason) .. "): " .. tostring(err))
		state.lastReloadStatus = "error:" .. tostring(err)
		return false, tostring(err)
	end

	log("reloaded (" .. tostring(reason) .. ")")
	state.lastReloadStatus = "ok"
	return true, "ok"
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

local function sendReply(ok, msg)
	if not state.client then
		return
	end
	local code = ok and "OK" or "ERR"
	local payload = "R|" .. code .. "|" .. tostring(msg or "") .. "\n"
	local sent, err = state.client:send(payload)
	if not sent and err then
		warn("reply send failed: " .. tostring(err))
		closeClient()
	end
end

local function handleCommand(line)
	local parts = splitPipe(line)
	local cmd = string.lower(parts[1] or "")
	if cmd == "reload" then
		state.pendingReload = true
		state.pendingReason = "remote"
		sendReply(true, "queued")
		return
	end
	if cmd == "status" then
		sendReply(true, "alive:" .. tostring(state.lastReloadStatus) .. ":pending=" .. tostring(state.pendingReload and 1 or 0) .. ":last=" .. tostring(state.lastReloadFrame))
		return
	end
	sendReply(false, "unknown command")
end

local function onFrame()
	if not state.pendingReload then
		return
	end
	state.pendingReload = false
	doReload(state.pendingReason or "remote")
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
			handleCommand(line)
		end
	end
	if #state.rx > 4096 then
		state.rx = ""
	end
end

local function onClientError(err)
	warn("control socket error: " .. tostring(err))
	closeClient()
end

local function onClientReceived()
	if not state.client then
		return
	end
	while true do
		local chunk, err = state.client:receive(2048)
		if chunk then
			processChunk(chunk)
		else
			if err ~= socket.ERRORS.AGAIN then
				warn("control receive failed: " .. tostring(err))
				closeClient()
			end
			return
		end
	end
end

local function onAccept()
	if not state.server then
		return
	end
	local sock, err = state.server:accept()
	if not sock then
		if err and err ~= socket.ERRORS.AGAIN then
			warn("control accept failed: " .. tostring(err))
		end
		return
	end
	closeClient()
	state.client = sock
	state.client:add("received", onClientReceived)
	state.client:add("error", onClientError)
end

local function startControlServer()
	local server, err = socket.bind("127.0.0.1", CONTROL_PORT)
	if not server then
		warn("control bind failed on " .. tostring(CONTROL_PORT) .. ": " .. tostring(err))
		return false
	end
	local ok, listenErr = server:listen()
	if not ok then
		server:close()
		warn("control listen failed: " .. tostring(listenErr))
		return false
	end
	state.server = server
	state.server:add("received", onAccept)
	log("control listening on 127.0.0.1:" .. tostring(CONTROL_PORT))
	return true
end

local function startup()
	closeClient()
	closeServer()
	state.pendingReload = true
	state.pendingReason = "boot"
	state.lastReloadStatus = "none"
	state.lastReloadFrame = -999999
	state.frameFallback = 0
	startControlServer()
end

local function shutdown()
	local runtime = rawget(_G, "GS_RUNTIME")
	if runtime and type(runtime.unloadAll) == "function" then
		pcall(function()
			runtime.unloadAll()
		end)
	end
	closeClient()
	closeServer()
end

startup()
callbacks:add("start", startup)
callbacks:add("reset", startup)
callbacks:add("stop", shutdown)
callbacks:add("crashed", shutdown)
callbacks:add("frame", onFrame)
