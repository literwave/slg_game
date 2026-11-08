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
		require = function(name) if name == 'skynet' then return skynet end return require(name) end,
		agent_list = {"agent"},
		CONST = load_env("logic/define/const.lua"),
		MARCH_PATH = load_env("common/march_path.lua"),
		DATA_COMMON = {TROOP_STATE = {MARCH=1, STAY=2, SIEGE=4}, ENTITY_TYPE = {CITY = 1, TROOP = 2, ALLIANCE_CITY = 5}},
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
	A.upsert_city(1, focus_x + r, 0, {name = "a", level = 1})
	A.upsert_city(2, focus_x + r * 4, 0, {name = "b", level = 1})
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

function T.hot_reload_preserves_march_arrival_and_existing_viewers()
	clear_sends()
	local A = load_aoi()
	A.focus(8, 0, 0)
	A.start_march({user_id=1, troop_idx=1, serial=17, target_type=5,
		path=line(0, 4), start_time=0, end_time=10})
	A.step(4)
	clear_sends()
	-- 和热更相同，在原模块环境里重新执行文件，保留已经排队的世界帧。
	assert(loadfile('logic/service/world/module/aoi/mgr.lua', 't', A))()
	local id = A.CONST.troop_entity_id(1, 1)
	assert(#A.get_march_path(1, id) == 2, 'hot reload must preserve authoritative march')
	local view = A.focus(8, 0, 0)
	assert(#view.enter == 0 and #view.leave == 0, 'existing viewer must not lose its seen set')
	A.step(10)
	local arrivals = 0
	for _, packet in ipairs(sends) do
		if packet.cmd == 'march_arrive' then arrivals = arrivals + 1 end
	end
	assert(arrivals == 1, 'march must still notify agent on arrival after hot reload')
	local updates = aoi_pushes()
	assert(#updates == 1 and #updates[1].pack.update == 1, 'existing watcher receives stop update')
	assert(updates[1].pack.update[1].entityId == id and updates[1].pack.update[1].path == nil)
	clear_sends()
	A.step(11)
	assert(#sends == 0, 'completed march must not repeat arrival')
end

function T.hot_reload_preserves_stationary_entities_and_spatial_buckets()
	clear_sends()
	local A = load_aoi()
	A.upsert_city(1, 2, 0, {name='主城', level=1})
	A.park_troop(1, 1, 3, 0)
	local before = A.focus(8, 0, 0)
	assert(#before.enter == 2)
	assert(loadfile('logic/service/world/module/aoi/mgr.lua', 't', A))()
	assert(#A.focus(9, 0, 0).enter == 2, 'new viewer must still find both entities by bucket')
	clear_sends()
	A.upsert_city(1, 2, 0, {name='主城', level=2})
	local updates = aoi_pushes()
	assert(#updates == 2, 'both old and new viewers still receive updates')
	for _, packet in ipairs(updates) do assert(#packet.pack.update == 1 and #packet.pack.enter == 0) end
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
	A.upsert_city(3, 1, 0, {name = "c", level = 1})
	local list = aoi_pushes()
	assert(#list == 1, "a failed tick does not swallow the next push")
	assert(#list[1].pack.enter == 1)
end

function T.march_path_only_owned_or_visible_and_keeps_float()
	local A = load_aoi()
	A.start_march({user_id = 1, troop_idx = 1, path = {{_x=2.25,_y=1.5},{_x=4.75,_y=3.25}}, start_time=0, end_time=10})
	local id = A.CONST.troop_entity_id(1, 1)
	assert(#A.get_march_path(9, id) == 0)
	local mine = A.get_march_path(1, id)
	assert(mine[1].x == 2.25 and mine[2].y == 3.25)
	mine[1].x = 99
	assert(A.get_march_path(1, id)[1].x == 2.25, "返回独立副本")
	A.focus(9, 2, 2)
	assert(#A.get_march_path(9, id) == 2)
	A.focus(9, 900, 900)
	assert(#A.get_march_path(9, id) == 0)
	A.hide_troop(1, 1)
	assert(#A.get_march_path(1, id) == 0)
	assert(#A.get_march_path(1, 999999) == 0)
end

function T.alliance_city_updates_owner_and_visible_audience()
	local A = load_aoi()
	local id = 5000000000000001
	local info = {entityId = id, cityType = 3, level = 8, pos = {x = 0, y = 0}, allianceId = 0, allianceName = ""}
	A.upsert_alliance_city(info)
	local view = A.focus(8, 0, 0)
	assert(#view.enter == 1 and view.enter[1].entityType == 5 and view.enter[1].cfgId == 308)
	assert(A.city_watchers(id)[8])
	clear_sends()
	info.allianceId, info.allianceName = 77, "山河"
	A.upsert_alliance_city(info)
	local update = aoi_pushes()[1].pack.update[1]
	assert(update.ownerId == 0 and update.allianceId == 77 and update.name == "山河")
	A.focus(8, 900, 900)
	assert(not A.city_watchers(id)[8])
	clear_sends()
end

function T.siege_broadcasts_stationary_phase_and_return_clears_it()
    local env=load_aoi()
    local id=env.CONST.troop_entity_id(1,1)
    env.focus(2,8,0)
    assert(env.siege_troop({user_id=1,troop_idx=1,target_id=501,path=line(0,8),start_time=10,end_time=15},{x=10,y=0}))
    local pack=env.focus(3,8,0)
    local troop
    for _, e in ipairs(pack.enter) do if e.entityId==id then troop=e end end
    assert(troop and troop.troopState==4 and troop.targetId==501 and troop.targetPos.x==10)
    assert(troop.path==nil and troop.startTime==10 and troop.endTime==15 and troop.pos.x==8)
    env.start_march({user_id=1,troop_idx=1,target_type=1,path=line(8,0),start_time=15,end_time=23})
    pack=env.focus(4,8,0)
    for _, e in ipairs(pack.enter) do if e.entityId==id then troop=e end end
    assert(troop.troopState==1 and troop.targetId==0 and troop.targetPos==nil and troop.path)
end

function T.captured_deployment_updates_serial_and_publishes_city_without_hiding_aoi()
    clear_sends()
    local env=load_aoi()
    local id=env.CONST.troop_entity_id(1,1)
    assert(env.siege_troop({user_id=1,troop_idx=1,serial=4,target_id=501,path=line(0,8),start_time=10,end_time=15},{x=10,y=0}))
    env.CITY_MGR={deployed_city=function(uid,idx,seq) return uid==1 and idx==1 and seq==5 and 501 or nil end}
    env.park_troop(1,1,10,0,5)
    local function snapshot(watcher)
        for _,e in ipairs(env.focus(watcher,10,0).enter) do if e.entityId==id then return e end end
    end
    local e=snapshot(8)
    assert(e and e.troopState==2 and e.targetId==501 and e.pos.x==10 and not e.path)
    env.start_march({user_id=1,troop_idx=1,serial=6,target_type=1,path=line(10,0),start_time=15,end_time=25})
    env.park_troop(1,1,10,0,5)
    e=snapshot(9)
    assert(e.troopState==1 and e.targetId==0 and e.path, "旧入城通知不能覆盖已经出城的新行军")
    clear_sends()
end

return T
