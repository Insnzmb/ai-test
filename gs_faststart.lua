local CONFIG = rawget(_G, "GS_FASTSTART_CONFIG") or {}

local ENABLED = CONFIG.enabled ~= false
local A_PULSE_FRAMES = CONFIG.a_pulse_frames or 2
local START_PULSE_FRAMES = CONFIG.start_pulse_frames or 24

local KEY_A = 1 << 0
local KEY_START = 1 << 3

local ADDR = {
	NAMING_TYPE = 0xC5D4,
	MENU_ITEMS = 0xCEC9,
	MENU_TOP = 0xCEB9,
	MENU_LEFT = 0xCEBA,
	MENU_BOTTOM = 0xCEBB,
	MENU_RIGHT = 0xCEBC,
	MAP_STATUS = 0xD159,
	SCRIPT_RUNNING = 0xD15F,
	SCRIPT_BANK = 0xD160,
	SCRIPT_POS = 0xD161,
	PLAYERS_HOUSE_1F_SCENE = 0xD6CD,
	H_IN_MENU = 0xFFAC,
}

local MOM_SCRIPT_BANK = 0x60
local MOM_CLOCK_DST_START = 0x5680
local MOM_CLOCK_DST_END_EXCLUSIVE = 0x569C

local PHASE = {
	PRE_NAME = 0,
	NAMING = 1,
	POST_NAME = 2,
	DONE = 3,
}

local state = {
	phase = PHASE.PRE_NAME,
	done = false,
	frameFallback = 0,
}

local function addCallback(eventName, fn)
	local register = rawget(_G, "GS_registerCallback")
	if type(register) == "function" then
		return register(eventName, fn)
	end
	return callbacks:add(eventName, fn)
end

local function log(msg)
	console:log("[GS-FASTSTART] " .. msg)
end

local function read8(address)
	return emu:read8(address)
end

local function read16(address)
	local lo = read8(address)
	local hi = read8(address + 1)
	return lo | (hi << 8)
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

local function pulse(interval, shift)
	if interval <= 0 then
		return false
	end
	local frame = currentFrame()
	return ((frame + (shift or 0)) % interval) == 0
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

local function romSupportState()
	local code = getGameCode()
	if code == "" then
		return "unknown"
	end
	if code == "AAXE" or code == "AAUE" then
		return "supported"
	end
	return "unsupported"
end

local function namingActive()
	return read8(ADDR.NAMING_TYPE) ~= 0
end

local function inMenu()
	return read8(ADDR.H_IN_MENU) ~= 0
end

local function mapStatus()
	return read8(ADDR.MAP_STATUS)
end

local function playersHouseScene()
	return read8(ADDR.PLAYERS_HOUSE_1F_SCENE)
end

local function isNameChoiceMenu()
	if not inMenu() then
		return false
	end
	-- NameMenuHeader is menu_coords 0,0,10,17 with 5 items.
	if read8(ADDR.MENU_ITEMS) ~= 5 then
		return false
	end
	if read8(ADDR.MENU_TOP) ~= 0 then
		return false
	end
	if read8(ADDR.MENU_LEFT) ~= 0 then
		return false
	end
	if read8(ADDR.MENU_BOTTOM) ~= 17 then
		return false
	end
	if read8(ADDR.MENU_RIGHT) ~= 10 then
		return false
	end
	return true
end

local function inMomClockDstWindow()
	if read8(ADDR.SCRIPT_BANK) ~= MOM_SCRIPT_BANK then
		return false
	end
	local pos = read16(ADDR.SCRIPT_POS)
	return pos >= MOM_CLOCK_DST_START and pos < MOM_CLOCK_DST_END_EXCLUSIVE
end

local function updatePhase()
	if state.done then
		return
	end
	if namingActive() then
		if state.phase ~= PHASE.NAMING then
			state.phase = PHASE.NAMING
			log("reached naming screen; waiting for manual name entry")
		end
		return
	end
	if state.phase == PHASE.NAMING then
		state.phase = PHASE.POST_NAME
		log("name entry complete; resuming auto skip")
		return
	end

	if state.phase == PHASE.PRE_NAME and mapStatus() ~= 0 then
		state.phase = PHASE.POST_NAME
	end

	if state.phase == PHASE.POST_NAME and mapStatus() ~= 0 and playersHouseScene() ~= 0 then
		state.phase = PHASE.DONE
		state.done = true
		log("mom intro scene complete; faststart disabled")
	end
end

local function decideAutoKeys()
	if not ENABLED or state.done then
		return false, false
	end
	local support = romSupportState()
	if support == "unknown" then
		return false, false
	end
	if support == "unsupported" then
		state.done = true
		state.phase = PHASE.DONE
		log("unsupported game code; faststart disabled")
		return false, false
	end
	if namingActive() then
		return false, false
	end

	if state.phase == PHASE.PRE_NAME then
		if isNameChoiceMenu() then
			return pulse(A_PULSE_FRAMES), false
		end
		-- Let user control clock/day setup manually.
		if inMenu() then
			return false, false
		end
		return pulse(A_PULSE_FRAMES), pulse(START_PULSE_FRAMES, 5)
	end

	if state.phase == PHASE.NAMING then
		return false, false
	end

	if state.phase == PHASE.POST_NAME then
		if mapStatus() == 0 then
			-- Still in Oak intro cleanup after naming.
			if inMenu() then
				return false, false
			end
			return pulse(A_PULSE_FRAMES), false
		end

		-- In-world: only automate the initial mom scene.
		if playersHouseScene() ~= 0 then
			state.done = true
			state.phase = PHASE.DONE
			return false, false
		end

		-- Preserve manual control for day-of-week and DST choice window.
		if inMomClockDstWindow() then
			return false, false
		end

		if read8(ADDR.SCRIPT_RUNNING) ~= 0 then
			return pulse(A_PULSE_FRAMES), false
		end
		return false, false
	end

	return false, false
end

local function onKeysRead()
	updatePhase()
	local pressA, pressStart = decideAutoKeys()
	if not pressA and not pressStart then
		return
	end

	local keys = emu:getKeys()
	if pressA then
		keys = keys | KEY_A
	end
	if pressStart then
		keys = keys | KEY_START
	end
	emu:setKeys(keys)
end

local function startup()
	state.phase = PHASE.PRE_NAME
	state.done = false
	state.frameFallback = 0
	if not ENABLED then
		state.phase = PHASE.DONE
		state.done = true
		log("disabled by config")
		return
	end
	if mapStatus() ~= 0 and playersHouseScene() ~= 0 then
		state.phase = PHASE.DONE
		state.done = true
		log("existing save state detected; no faststart automation")
		return
	end
	log("enabled")
end

startup()
addCallback("start", startup)
addCallback("reset", startup)
addCallback("keysRead", onKeysRead)
