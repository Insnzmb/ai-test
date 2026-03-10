local function _envOr(name, fallback)
	if type(os) == "table" and type(os.getenv) == "function" then
		local value = os.getenv(name)
		if value and value ~= "" then
			return value
		end
	end
	return fallback
end

local SILVER_AGENT_ENABLED = _envOr("GS_SILVER_AGENT", "0") == "1"
local SILVER_LOCK_INPUT = _envOr("GS_SILVER_LOCK_INPUT", SILVER_AGENT_ENABLED and "1" or "0") ~= "0"

GS_FASTSTART_CONFIG = {
	enabled = _envOr("GS_FASTSTART", SILVER_AGENT_ENABLED and "0" or "1") ~= "0",
	a_pulse_frames = 2,
	start_pulse_frames = 24,
}

GS_BG_INPUT_CONFIG = {
	enabled = _envOr("GS_BG_INPUT", "1") ~= "0",
	port = tonumber(_envOr("GS_BG_INPUT_PORT", "58892")) or 58892,
	state_interval_frames = 30,
}

-- Training mode intentionally does not load gs_coop_core.lua.
-- The 10x trainer runs standalone Silver sandboxes, so there is no co-op host
-- to connect to and no reason to spam localhost connection warnings forever.
GS_COOP_SHARED = {
	connected = false,
	remote = nil,
	frame = 0,
	remoteAge = nil,
}

local function addCallback(eventName, fn)
	local register = rawget(_G, "GS_registerCallback")
	if type(register) == "function" then
		return register(eventName, fn)
	end
	return callbacks:add(eventName, fn)
end

dofile(script.dir .. "/gs_faststart.lua")
dofile(script.dir .. "/gs_bg_input.lua")

if SILVER_AGENT_ENABLED then
	GS_SILVER_AGENT_CONFIG = {
		enabled = true,
		port = tonumber(_envOr("GS_SILVER_AGENT_PORT", "58888")) or 58888,
		state_interval_frames = tonumber(_envOr("GS_SILVER_AGENT_STATE_FRAMES", "2")) or 2,
		block_human_input = SILVER_LOCK_INPUT,
		remote_stale_frames = 0,
	}
	dofile(script.dir .. "/gs_silver_agent.lua")
end

local function onFrame()
	if type(GS_COOP_SHARED) == "table" then
		local frameNow = 0
		if emu and type(emu.frameCount) == "function" then
			frameNow = emu:frameCount()
		end
		GS_COOP_SHARED.frame = frameNow
		GS_COOP_SHARED.connected = false
		GS_COOP_SHARED.remote = nil
		GS_COOP_SHARED.remoteAge = nil
	end
end

addCallback("frame", onFrame)
