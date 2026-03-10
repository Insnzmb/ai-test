local function _envOr(name, fallback)
	if type(os) == "table" and type(os.getenv) == "function" then
		local value = os.getenv(name)
		if value and value ~= "" then
			return value
		end
	end
	return fallback
end

GS_FASTSTART_CONFIG = {
	enabled = _envOr("GS_FASTSTART", "1") ~= "0",
	a_pulse_frames = 2,
	start_pulse_frames = 24,
}

GS_BG_INPUT_CONFIG = {
	enabled = _envOr("GS_BG_INPUT", "1") ~= "0",
	port = tonumber(_envOr("GS_BG_INPUT_PORT", "58891")) or 58891,
	state_interval_frames = 30,
}

GS_COOP_CONFIG = {
	mode = "host",
	host = _envOr("GS_COOP_HOST", "127.0.0.1"),
	port = tonumber(_envOr("GS_COOP_PORT", "58777")) or 58777,
	sync_interval_frames = 4,
	apply_interval_frames = 6,
	hud_interval_frames = 8,
	object_interval_frames = 1,
	reconnect_interval_frames = 300,
	stale_remote_frames = 120,
	max_render_distance_tiles = 48,
	partner_smoothing_pixels = 6,
	partner_teleport_pixels = 28,
	sync_party = true,
	sync_items = true,
	sync_money = true,
	force_blue_gold = true,
}

dofile(script.dir .. "/gs_faststart.lua")
dofile(script.dir .. "/gs_bg_input.lua")
dofile(script.dir .. "/gs_coop_core.lua")
