-- 视野按半径分桶。过格只推走进和走出，停步和改路才推更新，同一拍合成一条

local sends = {}

local function noop()
end

local function load_env(path)
	local env = setmetatable({}, {__index = _G})
	assert(loadfile(path, "t", env))()
	return env
end

local function load_aoi()
	local skynet = {
		error = noop,
		timeout = noop,
		fork = noop,
		getenv = function()
			return nil
		end,
		call = noop,
		rawcall = noop,
		sleep = noop,
		wait = noop,
		send = function(_, _, cmd, user_id, pack)
			sends[#sends + 1] = {cmd = cmd, user_id = user_id, pack = pack}
		end,
	}
	local prev_skynet = package.loaded.skynet
	package.loaded.skynet = skynet
	local env = setmetatable({
		agent_list = {"agent"},
		CONST = load_env("logic/define/const.lua"),
		MARCH_PATH = load_env("common/march_path.lua"),
		DATA_COMMON = {ENTITY_TYPE = {CITY = 1, TROOP = 2}},
		TIME = {now = function() return 0 end},
		ENCOUNTER_MGR = {
			unindex = noop,
			index_at = noop,
			touch = noop,
			clear_flee = noop,
			note_flee = noop,
			release_cell = function() return {} end,
			conclude = noop,
			advance = function() return {}, {} end,
		},
	}, {__index = _G})
	assert(loadfile("logic/service/world/module/aoi/mgr.lua", "t", env))()
	package.loaded.skynet = prev_skynet
	return env
end

local function clear_sends()
	for i = #sends, 1, -1 do
		sends[i] = nil
	end
end

local function aoi_pushes()
	local list = {}
	for _, s in ipairs(sends) do
		if s.cmd == "aoi_push" then
			list[#list + 1] = s
		end
	end
	return list
end

local function has_pto(list, id)
	for _, item in ipairs(list) do
		if item.entityId == id then
			return true
		end
	end
	return false
end

local function has_num(list, id)
	for _, item in ipairs(list) do
		if item == id then
			return true
		end
	end
	return false
end

local function line(x0, x1)
	return {{_x = x0, _y = 0}, {_x = x1, _y = 0}}
end

local T = {}

function T.parked_troop_is_visible()
	local A = load_aoi()
	A.park_troop(1, 1, 2, 0)
	local view = A.focus(8, 0, 0)
	assert(has_pto(view.enter, A.CONST.troop_entity_id(1, 1)), "a troop standing in the city is an entity")
	assert(view.enter[1].entityType == 2)
	clear_sends()
	A.start_march({
		user_id = 1,
		troop_idx = 1,
		path = line(2, 4),
		start_time = 0,
		end_time = 1,
	})
	local moved = aoi_pushes()
	assert(#moved == 1)
	assert(#moved[1].pack.update == 1, "marching updates the same troop instead of hiding it")
	assert(moved[1].pack.update[1].path)
end

function T.bucket_edge()
	local A = load_aoi()
	local r = A.CONST.AOI_RADIUS
	local focus_x = r - 1
	A.upsert_city(1, focus_x + r, 0)
	A.upsert_city(2, focus_x + r * 4, 0)
	local near = A.focus(10, focus_x, 0)
	assert(has_pto(near.enter, A.CONST.city_entity_id(1)), "city one bucket away is inside the radius")
	assert(not has_pto(near.enter, A.CONST.city_entity_id(2)), "city outside the 3x3 buckets stays out")
	local far = A.focus(10, focus_x + r * 4, 0)
	assert(has_pto(far.enter, A.CONST.city_entity_id(2)), "camera move enters the city in that bucket")
	assert(has_num(far.leave, A.CONST.city_entity_id(1)), "camera move leaves the previous city")
end

function T.cross_has_no_update()
	local A = load_aoi()
	local viewer = 8
	local r = A.CONST.AOI_RADIUS
	A.focus(viewer, 0, 0)
	A.start_march({
		user_id = 1,
		troop_idx = 1,
		path = line(0, r * 4),
		start_time = 0,
		end_time = 6,
	})
	local entered = aoi_pushes()
	assert(#entered == 1, "spawn pushes one enter")
	assert(#entered[1].pack.enter == 1)
	assert(entered[1].pack.enter[1].path)
	clear_sends()
	A.step(1)
	assert(#aoi_pushes() == 0, "crossing a cell on the same path does not push")
	A.step(3)
	local left = aoi_pushes()
	assert(#left == 1)
	assert(#left[1].pack.leave == 1)
	assert(#left[1].pack.update == 0)
	assert(#left[1].pack.enter == 0)
	assert(left[1].user_id == viewer)
end

function T.same_tick_one_push()
	local A = load_aoi()
	local viewer = 8
	local far = A.CONST.AOI_RADIUS + 10
	A.focus(viewer, far, 0)
	A.start_march({
		user_id = 1,
		troop_idx = 1,
		path = line(0, far * 2),
		start_time = 0,
		end_time = 10,
	})
	A.start_march({
		user_id = 2,
		troop_idx = 1,
		path = line(0, far * 2),
		start_time = 0,
		end_time = 10,
	})
	clear_sends()
	A.step(5)
	local list = aoi_pushes()
	assert(#list == 1, "two enters in one tick share one push")
	assert(#list[1].pack.enter == 2)
	assert(has_pto(list[1].pack.enter, A.CONST.troop_entity_id(1, 1)))
	assert(has_pto(list[1].pack.enter, A.CONST.troop_entity_id(2, 1)))
	assert(#list[1].pack.update == 0)
end

function T.stop_and_reroute_update()
	local A = load_aoi()
	A.focus(8, 0, 0)
	A.start_march({
		user_id = 1,
		troop_idx = 1,
		path = line(0, 4),
		start_time = 0,
		end_time = 1,
	})
	clear_sends()
	A.step(1)
	local stopped = aoi_pushes()
	assert(#stopped == 1)
	assert(#stopped[1].pack.update == 1)
	assert(stopped[1].pack.update[1].path == nil)
	clear_sends()
	A.start_march({
		user_id = 1,
		troop_idx = 1,
		path = line(4, 6),
		start_time = 1,
		end_time = 2,
	})
	local again = aoi_pushes()
	assert(#again == 1)
	assert(#again[1].pack.enter == 0)
	assert(#again[1].pack.update == 1)
	assert(again[1].pack.update[1].path)
	assert(again[1].pack.update[1].endTime == 2)
end

function T.step_error_still_flushes()
	local A = load_aoi()
	A.focus(8, 0, 0)
	A.ENCOUNTER_MGR.advance = function()
		error("boom")
	end
	local ok = pcall(A.step, 1)
	assert(not ok)
	A.ENCOUNTER_MGR.advance = function()
		return {}, {}
	end
	clear_sends()
	A.upsert_city(3, 1, 0)
	local list = aoi_pushes()
	assert(#list == 1, "a failed tick does not swallow the next push")
	assert(#list[1].pack.enter == 1)
end

return T
