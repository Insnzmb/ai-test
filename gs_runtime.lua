local R = rawget(_G, "GS_RUNTIME")
if type(R) ~= "table" then
	R = {
		callbackIds = {},
		unloadHandlers = {},
	}
	_G.GS_RUNTIME = R
end

function R.registerCallback(eventName, fn)
	local id = callbacks:add(eventName, fn)
	R.callbackIds[#R.callbackIds + 1] = id
	return id
end

function R.registerUnload(fn)
	if type(fn) ~= "function" then
		return
	end
	R.unloadHandlers[#R.unloadHandlers + 1] = fn
end

function R.unloadAll()
	for i = #R.unloadHandlers, 1, -1 do
		pcall(R.unloadHandlers[i])
	end
	R.unloadHandlers = {}

	for i = #R.callbackIds, 1, -1 do
		pcall(function()
			callbacks:remove(R.callbackIds[i])
		end)
	end
	R.callbackIds = {}
end

_G.GS_registerCallback = function(eventName, fn)
	return R.registerCallback(eventName, fn)
end

_G.GS_registerUnload = function(fn)
	R.registerUnload(fn)
end

