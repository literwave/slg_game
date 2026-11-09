-- 视野按半径分桶。过格只推走进和走出，停步和改路才推更新，同一拍合成一条

local sends = {}

local function noop()
end

local function load_env(path)
	local env = setmetatable({}, {__index = _G})
	assert(loadfile(path, "t", env))()
	return env
end

local function load_aoi(options)
    sends = {} -- Every fixture owns its outbound evidence.
    options = options or {}
    local timers, forks = {}, {}
	local skynet = {
		error = noop,
        hpc = function() return math.floor(os.clock() * 1000000000) end,
        timeout = function(delay, fn) timers[#timers+1] = {delay=delay,fn=fn} end,
        fork = function(fn) forks[#forks+1] = fn end,
        getenv = function(name) return options[name] end,
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
    env._test = {skynet=skynet, timers=timers, forks=forks}
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

function T.unchanged_focus_skips_scan_but_keeps_live_seen_state_and_first_view()
    local A=load_aoi()
    A.upsert_city(1,1,0,{name="first",level=1})
    assert(#A.focus(8,0,0).enter==1)
    local old_pairs=A.pairs
    A.pairs=function() error("unchanged focus rescanned entities") end
    local same=A.focus(8,0,0)
    assert(#same.enter==0 and #same.leave==0)
    A.pairs=old_pairs
    A.upsert_city(2,2,0,{name="second",level=1})
    assert(A.runtime.focus_tbl[8].seen[A.CONST.city_entity_id(2)])
    local after=A.focus(8,0,0)
    assert(#after.enter==0 and #after.leave==0,"live enter already updated the seen set")
    local moved=A.focus(8,900,900)
    assert(#moved.leave==2)
    assert(#A.focus(8,0,0).enter==2)
    A.clear_focus(8)
    assert(#A.focus(8,0,0).enter==2,"recreated observer needs an initial scan")
    assert(#A.focus(9,0,0).enter==2,"new observer at identical coordinates needs a scan")
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

local function actual_encounters(A)
    local E = setmetatable({MARCH_PATH=A.MARCH_PATH, DATA_COMMON={TARGET_TYPE=dofile("game_common/server/enum/TargetTypeEnum.lua")}}, {__index=_G})
    assert(loadfile("logic/service/world/module/encounter/mgr.lua", "t", E))()
    A.ENCOUNTER_MGR = E
    A.DATA_COMMON.get_march_speed = function() return 1 end
    A.MAP_MGR = {find_march_path=function(_,sx,sy,ex,ey) return {{_x=sx,_y=sy},{_x=ex,_y=ey}} end}
    return E
end

local function moving(A, uid)
    return A.runtime.active_movers[A.CONST.troop_entity_id(uid, 1)]
end
local function march(A, uid, target)
    A.start_march({user_id=uid,troop_idx=1,target_type=target or 5,path=line(0,4),start_time=0,end_time=4})
end

function T.active_index_tracks_arrival_siege_return_hide_delete_and_replacement()
    local A = load_aoi()
    march(A,1); assert(moving(A,1))
    A.step(4); assert(not moving(A,1))
    A.siege_troop({user_id=1,troop_idx=1,path=line(0,4),start_time=4,end_time=8,target_id=501},{x=5,y=0})
    assert(not moving(A,1))
    march(A,1,1); local old = moving(A,1); assert(old)
    march(A,1,1); assert(moving(A,1) and moving(A,1) ~= old)
    A.hide_troop(1,1); assert(not moving(A,1))
    march(A,1); A.remove_troop(1,1); assert(not moving(A,1))
    A.park_troop(1,1,0,0); assert(not moving(A,1))
    -- Static entities must not be enumerated in a world step, regardless of count.
    A.pairs = function(t)
        assert(t ~= A.runtime.entities, "world step scanned static entities")
        return pairs(t)
    end
    A.step(5)
end

function T.encounter_wait_and_abort_restore_the_active_index()
    local A = load_aoi(); actual_encounters(A)
    march(A,1); march(A,2); march(A,3)
    assert(not moving(A,1) and not moving(A,2) and not moving(A,3))
    local third = A.runtime.entities[A.CONST.troop_entity_id(3,1)]
    assert(third.waiting, "third troop must be waiting behind the encounter")
    A.agent_list = {} -- failed lookup aborts without contacting a real service
    A._test.forks[1]()
    assert(moving(A,1) and moving(A,2) and moving(A,3))
    assert(not third.waiting)
end

function T.encounter_victory_resumes_only_the_winner()
    local A = load_aoi(); actual_encounters(A)
    march(A,1); march(A,2)
    A._test.skynet.call = function(_,_,cmd)
        if cmd == "encounter_snap" then return {side={},end_time=4,state=1} end
        return {{result=A.CONST.BATTLE_RESULT.WIN,atk_left={},def_left={},actions={}}}
    end
    A._test.forks[1]()
    assert(moving(A,2) and not moving(A,1))
    A.step(4)
    assert(not moving(A,2), "resumed winner must still complete its march")
end

function T.stale_encounter_after_rpc_cannot_remove_a_replacement_march()
    local A = load_aoi(); actual_encounters(A)
    march(A,1); march(A,2)
    A._test.skynet.call = function(_,_,cmd)
        if cmd == "encounter_snap" then coroutine.yield("snapshot"); return {side={},end_time=4,state=1} end
        return {{result=A.CONST.BATTLE_RESULT.WIN,atk_left={},def_left={},actions={}}}
    end
    local worker = coroutine.create(A._test.forks[1])
    local ok, reason = coroutine.resume(worker)
    assert(ok and reason == "snapshot")
    march(A,2,1)
    local replacement = moving(A,2)
    assert(replacement)
    assert(coroutine.resume(worker))
    assert(coroutine.resume(worker) and coroutine.status(worker) == "dead")
    assert(moving(A,2) == replacement, "stale callback must preserve replacement identity")
end

local function failed_step_restores_state(inject, expected)
    clear_sends()
    local A=load_aoi()
    A.focus(8,0,0)
    local old_advance=A.ENCOUNTER_MGR.advance
    local saved={}
    for _,name in ipairs({"call","rawcall","sleep","wait"}) do saved[name]=A._test.skynet[name] end
    A.ENCOUNTER_MGR.advance=function()
        A.upsert_city(1,1,0,{name="pending",level=1})
        return inject(A)
    end
    local ok,err=pcall(A.step,1)
    assert(not ok and tostring(err):find(expected,1,true),tostring(err))
    for name,fn in pairs(saved) do assert(A._test.skynet[name]==fn,"frame leaked a Skynet API override") end
    assert(#aoi_pushes()==1,"failed frame must flush already recorded AOI changes")
    clear_sends()
    A.upsert_city(2,2,0,{name="after",level=1})
    assert(#aoi_pushes()==1,"failed frame must reset batching immediately")
    A.ENCOUNTER_MGR.advance=old_advance
    assert(pcall(A.step,2),"failed frame must release its reentry guard")
end

function T.direct_yield_cannot_suspend_a_world_frame_or_leave_apis_disabled()
    failed_step_restores_state(function() coroutine.yield("forbidden") end,"cannot yield")
end

function T.reentrant_world_step_fails_before_mutating_frame_state()
    failed_step_restores_state(function(A) A.step(1) end,"reentry")
end

function T.world_step_exception_restores_apis_and_allows_the_next_frame()
    failed_step_restores_state(function() error("injected step failure") end,"injected step failure")
end

function T.performance_metrics_are_bounded_and_measure_scheduling_lateness()
    local A = load_aoi({performance_metrics="1"})
    local now = 0
    A.TIME.now = function() return now end
    A.TIME.os_bj_sec = function() return now end
    A.DATA_COMMON.get_monster_group_tbl = function() return {} end
    A.DATA_COMMON.get_main_city_bid = function() return 1 end
    A.MONGO_SLAVE = {COL={USER_INFO="u",USER_BUILD="b",USER_TROOP="t"},common_load_tbl=function() return {} end}
    A.MAP_MGR = {begin_nav_batch=noop,end_nav_batch=noop}
    A.ENCOUNTER_MGR.load_alliances = noop
    A.LAND_MGR, A.CITY_MGR = {init=noop}, {init=noop}
    A._test.skynet.call = function() return {"agent"} end
    A.init()
    local timers = A._test.timers
    now = 0.01; timers[#timers].fn()
    now = 0.08; timers[#timers].fn()
    local metrics = A.performance_stats()
    assert(metrics.enabled and metrics.ticks == 2 and metrics.errors == 0)
    assert(math.abs(metrics.late_ms.max - 20) < 0.001)
    assert(metrics.step_ms.count == 2 and #metrics.step_ms.buckets == 15)
    metrics.step_ms.count = 999
    assert(A.performance_stats().step_ms.count == 2, "diagnostics return a copy")
    local old_advance=A.ENCOUNTER_MGR.advance
    A.ENCOUNTER_MGR.advance=function() coroutine.yield("invalid frame") end
    now=0.13; timers[#timers].fn()
    assert(A.performance_stats().ticks==3 and A.performance_stats().errors==1)
    A.ENCOUNTER_MGR.advance=old_advance
    now=0.18; timers[#timers].fn()
    assert(A.performance_stats().ticks==4 and A.performance_stats().errors==1,"tick must schedule recovery after a failed frame")
    assert(load_aoi().performance_stats().enabled == false)
end

return T
