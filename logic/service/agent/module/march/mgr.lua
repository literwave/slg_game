local skynet = require "skynet"

function world_call(cmd, ...)
	local addr = skynet.localname(".world")
	if not addr then
		return
	end
	return skynet.call(addr, "lua", cmd, ...)
end

-- 离开资源地时结算采集：按部队记的采集时间算，世界服务再按剩余储量截一下
local function leave_gather(user, troop)
	local user_id = user:get_user_id()
	local entity_id = troop:get_target_id()
	local info = world_call("res_land_info", entity_id)
	local conf = info and DATA_COMMON.get_res_land_conf(info.cfg_id)
	if not conf then
		return
	end
	local sec = math.max(0, math.min(TIME.os_bj_sec(), troop:get_end_time()) - troop:get_start_time())
	local gathered = math.floor(conf.GatherSpeed * sec / CONST.ONE_HOUR_SEC)
	gathered = world_call("leave_res_land", entity_id, user_id, troop:get_troop_idx(), gathered) or gathered
	if gathered > 0 then
		local reward_type = conf.OutputItem == CONST.RES_TYPE_STONE and CONST.REWARD_TYPE_RES or CONST.REWARD_TYPE_ITEM
		REWARD_MGR.reward_user_and_show(user_id, {
			GLOBAL_FUNC.gen_reward_info(reward_type, conf.OutputItem, gathered),
		}, {CONST.FLOW_REASON.GATHER, info.cfg_id})
	end
end

local function begin_march(user, troop, target_type, target_id, ex, ey, ox, oy)
	local now = TIME.now()
	local sx, sy
	if ox ~= nil then
		sx, sy = ox, oy
	else
		local state = troop:get_march_state()
		if state == 0 then
			sx, sy = user:get_birth_x(), user:get_birth_y()
		elseif state == CONST.MARCH_STATE.ARRIVED then
			sx, sy = troop:get_end_pos()
		else
			sx, sy = troop:calc_pos(now)
		end
	end
	local path = world_call("find_march_path", user:get_user_id(), sx, sy, ex, ey)
	if not path then
		return false
	end
	if troop:is_gathering() then
		leave_gather(user, troop)
	elseif troop:get_march_state() == CONST.MARCH_STATE.ARRIVED
		and troop:get_target_type() == DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND then
		world_call("leave_res_land", troop:get_target_id(), user:get_user_id(), troop:get_troop_idx(), 0)
	end
	local cost = MARCH_PATH.march_seconds(path, DATA_COMMON.get_march_speed(target_type))
	troop:set_march({
		state = CONST.MARCH_STATE.MOVING,
		target_type = target_type,
		target_id = target_id,
		path = path,
		start_time = now,
		end_time = now + cost,
	})
	local ok = world_call("start_march", troop:get_march_info())
	if not ok then
		troop:clear_march()
		return false
	end
	return true
end

local function begin_return(user, troop)
	if not user:has_birth_pos() then
		return false
	end
	return begin_march(user, troop, DATA_COMMON.TARGET_TYPE.RETURN_CITY, 0, user:get_birth_x(), user:get_birth_y())
end

-- 同格战打输，从遭遇的那一格回城
function return_from(user, troop, x, y)
	if not user:has_birth_pos() then
		return false
	end
	return begin_march(user, troop, DATA_COMMON.TARGET_TYPE.RETURN_CITY, 0, user:get_birth_x(), user:get_birth_y(), x, y)
end

function on_arrive(user_id, troop_idx, end_time)
	local user = USER_MGR.try_init_user(user_id)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if not troop or troop:get_march_state() ~= CONST.MARCH_STATE.MOVING then
		return
	end
	if end_time and end_time ~= troop:get_end_time() then
		return
	end
	if TIME.os_bj_sec() + 1 < troop:get_end_time() then
		return
	end
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.ATTACK_MONSTER then
		troop:set_arrived()
		BATTLE_MGR.attack_monster(user, troop)
		if begin_return(user, troop) and fd then
			for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
		end
		return
	end
	if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND then
		troop:set_arrived()
		local gather_end, held, occupy_end = BATTLE_MGR.occupy_res_land(user, troop)
		if gather_end then
			troop:set_gather(TIME.os_bj_sec(), gather_end)
		elseif occupy_end then
			troop:set_occupy_wait(occupy_end - DATA_COMMON.get_occupy_seconds(), occupy_end)
		elseif not held and not begin_return(user, troop) then
			return
		end
		if fd then
			for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
		end
		return
	end
	if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.MOVE then
		troop:set_arrived()
		if fd then
			for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
		end
		return
	end
	local pto = troop:get_march_pto()
	pto.state = CONST.MARCH_STATE.ARRIVED
	troop:clear_march()
	world_call("hide_troop", user_id, troop_idx)
	if fd then
		for_caller.s2c_sync_march(fd, {marchInfo = pto})
	end
end

-- 资源地采满，世界服务通知回城
function on_occupy_done(user_id, troop_idx, gather_end)
	local user = USER_MGR.try_init_user(user_id)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if not user or not troop or troop:get_march_state() ~= CONST.MARCH_STATE.ARRIVED then
		return
	end
	if troop:get_target_type() ~= DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND then
		return
	end
	if not still_occupying(user_id, troop) then
		return
	end
	local now = TIME.os_bj_sec()
	if gather_end and gather_end > now then
		troop:set_gather(now, gather_end)
	else
		troop:set_occupy_wait(now, now)
	end
	local fd = user:get_fd()
	if fd then
		for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
	end
end

function on_gather_full(user_id, troop_idx, end_time)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if not troop or not troop:is_gathering() or troop:get_end_time() ~= end_time then
		return
	end
	local user = USER_MGR.try_init_user(user_id)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if begin_return(user, troop) and fd then
		for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
	end
end

-- 世界服务里还是这支部队占着就继续采。倒计时没结束时归属还没写上，也要留在原地
local function land_hold(user_id, troop)
	local info = world_call("res_land_info", troop:get_target_id())
	if not info or info.troop_idx ~= troop:get_troop_idx() then
		return
	end
	if info.owner_id == user_id then
		return "owned"
	end
	if info.pending_owner == user_id and info.occupy_end > TIME.os_bj_sec() then
		return "wait"
	end
end

local function still_occupying(user_id, troop)
	return land_hold(user_id, troop) == "owned"
end

function on_aoi_push(fd, pack)
	if not fd or not pack then
		return
	end
	if pack.enter and #pack.enter > 0 then
		for_caller.s2c_aoi_enter(fd, {entities = pack.enter})
	end
	if pack.leave and #pack.leave > 0 then
		for_caller.s2c_aoi_leave(fd, {entityIds = pack.leave})
	end
	if pack.update and #pack.update > 0 then
		for_caller.s2c_aoi_update(fd, {entities = pack.update})
	end
end

function on_user_login(user_id)
	local user = USER_MGR.try_init_user(user_id)
	if user:has_birth_pos() then
		USER_MGR.sync_city_aoi(user)
	end
	local now = TIME.os_bj_sec()
	for _, troop in pairs(TROOP_MGR.get_user_troops(user_id)) do
		local state = troop:get_march_state()
		if state == CONST.MARCH_STATE.MOVING then
			if now >= troop:get_end_time() then
				on_arrive(user_id, troop:get_troop_idx(), troop:get_end_time())
			else
				world_call("start_march", troop:get_march_info())
			end
		elseif state == 0 then
			world_call("hide_troop", user_id, troop:get_troop_idx())
		elseif state == CONST.MARCH_STATE.ARRIVED and troop:get_target_type() == DATA_COMMON.TARGET_TYPE.MOVE then
			world_call("start_march", troop:get_march_info())
		elseif state == CONST.MARCH_STATE.ARRIVED and (troop:get_target_type() == DATA_COMMON.TARGET_TYPE.ATTACK_MONSTER or troop:is_gathering()) then
			-- 还占着资源地的继续采；世界服务重启过占领没了就结算回城
			if not (troop:is_gathering() and still_occupying(user_id, troop)) and begin_return(user, troop) then
				local fd = user:get_fd()
				if fd then
					for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
				end
			end
		elseif state == CONST.MARCH_STATE.ARRIVED and troop:get_target_type() == DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND then
			local x, y = troop:get_end_pos()
			if land_hold(user_id, troop) and x ~= nil then
				world_call("park_troop", user_id, troop:get_troop_idx(), x, y)
			elseif begin_return(user, troop) then
				local fd = user:get_fd()
				if fd then
					for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
				end
			end
		elseif state == CONST.MARCH_STATE.ARRIVED then
			troop:clear_march()
			world_call("hide_troop", user_id, troop:get_troop_idx())
		end
	end
end

local function on_march(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user or not user:has_birth_pos() then
		return
	end
	local user_id = user:get_user_id()
	local troop = TROOP_MGR.get_troop(user_id, packet.troopIdx)
	if not troop or not troop:has_hero() then
		return
	end
	local was_moving = troop:get_march_state() == CONST.MARCH_STATE.MOVING
	local ex, ey, target_id
	if packet.targetType == DATA_COMMON.TARGET_TYPE.ATTACK_MONSTER then
		local pos = world_call("monster_pos", packet.targetId)
		if not pos then
			USER_MGR.tell_me(user_id, "目标不存在")
			return
		end
		ex, ey = pos.x, pos.y
		target_id = packet.targetId
	elseif packet.targetType == DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND then
		local x = CONST.res_land_xy(packet.targetId)
		if x == nil then
			USER_MGR.tell_me(user_id, "目标不存在")
			return
		end
		local info = world_call("res_land_info", packet.targetId)
		if not info then
			USER_MGR.tell_me(user_id, "此处不能占领")
			return
		end
		if info.covered then
			USER_MGR.tell_me(user_id, "城池范围内不能占领")
			return
		end
		local empty = info.cfg_id == 0
		local conf = not empty and DATA_COMMON.get_res_land_conf(info.cfg_id)
		if not empty and (not conf or not SYSTEM_OPEN.is_cond_ok(user, conf.OpenCond)) then
			USER_MGR.tell_me(user_id, "等级不足")
			return
		end
		if info.owner_id ~= 0 and info.owner_id ~= user_id then
			USER_MGR.tell_me(user_id, empty and "这块空地已被占领" or "资源地已被占领")
			return
		end
		if not empty and info.owner_id == user_id and info.remain <= 0 then
			USER_MGR.tell_me(user_id, "资源尚未恢复")
			return
		end
		if info.troop_idx ~= 0 and info.troop_idx ~= troop:get_troop_idx() then
			local occupying = info.occupy_end and info.occupy_end > TIME.os_bj_sec()
			USER_MGR.tell_me(user_id, occupying and "已有部队在占领" or (empty and "已有部队驻守" or "已有部队在采集"))
			return
		end
		ex, ey = info.x, info.y
		target_id = packet.targetId
	elseif packet.targetType == DATA_COMMON.TARGET_TYPE.RETURN_CITY then
		ex, ey = user:get_birth_x(), user:get_birth_y()
		target_id = 0
	elseif packet.targetType == DATA_COMMON.TARGET_TYPE.MOVE then
		local pos = packet.targetPos
		if not pos or not pos.x or not pos.y then
			USER_MGR.tell_me(user_id, "目标无法到达")
			return
		end
		ex, ey = pos.x, pos.y
		target_id = 0
	else
		return
	end
	if not begin_march(user, troop, packet.targetType, target_id, ex, ey) then
		USER_MGR.tell_me(user_id, "目标无法到达")
		return
	end
	for_caller.s2c_march(fd, {marchInfo = troop:get_march_pto()})
	if not was_moving and packet.targetType ~= DATA_COMMON.TARGET_TYPE.RETURN_CITY then
		EVENT.dispatch(CONST.EVENT.ON_MARCH, user_id, 1)
	end
end

local function on_cancel_march(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local troop = TROOP_MGR.get_troop(user:get_user_id(), packet.troopIdx)
	if not troop or troop:get_march_state() ~= CONST.MARCH_STATE.MOVING then
		return
	end
	if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.RETURN_CITY then
		return
	end
	if not begin_return(user, troop) then
		return
	end
	for_caller.s2c_cancel_march(fd, {
		troopIdx = packet.troopIdx,
		marchInfo = troop:get_march_pto(),
	})
end

local function on_req_march_list(fd)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local march_list = {}
	for _, troop in pairs(TROOP_MGR.get_user_troops(user_id)) do
		if troop:get_march_state() ~= 0 then
			march_list[#march_list + 1] = troop:get_march_pto()
		end
	end
	for_caller.s2c_req_march_list(fd, {marchList = march_list})
end

local function on_aoi_focus(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id or not packet.pos then
		return
	end
	local diff = world_call("aoi_focus", user_id, packet.pos.x, packet.pos.y)
	if not diff then
		return
	end
	on_aoi_push(fd, diff)
end

function __init__()
	for_maker.c2s_march = on_march
	for_maker.c2s_cancel_march = on_cancel_march
	for_maker.c2s_req_march_list = on_req_march_list
	for_maker.c2s_aoi_focus = on_aoi_focus
	EVENT.listen(CONST.EVENT.ON_USER_LOGIN)
end
