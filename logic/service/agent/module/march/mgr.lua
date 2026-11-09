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
		REWARD_MGR.reward_user_and_show(user_id, {
			GLOBAL_FUNC.gen_reward_info(CONST.REWARD_TYPE_ITEM, conf.OutputItem, gathered),
		}, {CONST.FLOW_REASON.GATHER, info.cfg_id}, {CONST.REWARD_SHOW_TYPE.NONE})
	end
end

local function ack_siege(troop)
	if troop._data._siege_city <= 0 or (troop:get_target_type() == DATA_COMMON.TARGET_TYPE.ATTACK_CITY
		and troop._data._march_serial == troop._data._siege_seq) then return end
	local ok, acknowledged = pcall(function()
		MONGO_SLAVE.flush_snapshot()
		return world_call("ack_city_attack", troop._data._siege_city, troop:get_user_id(),
			troop:get_troop_idx(), troop._data._siege_seq)
	end)
	if ok and acknowledged then
		troop._data._siege_city, troop._data._siege_seq = 0, 0
	elseif not ok then
		skynet.error("city acknowledgement retained for next arrival/login", acknowledged)
	end
end

local function march_origin(user, troop, now)
    local state = troop:get_march_state()
    if state == 0 then
        return user:get_birth_x(), user:get_birth_y()
    elseif state == CONST.MARCH_STATE.ARRIVED then
        return troop:get_end_pos()
    end
    return troop:calc_pos(now)
end

local function return_path(sx, sy, ex, ey)
    return {{_x = sx, _y = sy}, {_x = ex, _y = ey}}
end

local function begin_march(user, troop, target_type, target_id, ex, ey, ox, oy, city_round)
	local now = TIME.now()
	local sx, sy
	if ox ~= nil then
		sx, sy = ox, oy
	else
		sx, sy = march_origin(user, troop, now)
	end
	local path
	if target_type == DATA_COMMON.TARGET_TYPE.RETURN_CITY then
        -- 回城直接返回主城，不受山河、关口或其他主城阻挡。
        path = return_path(sx, sy, ex, ey)
	elseif target_type == DATA_COMMON.TARGET_TYPE.ATTACK_CITY then
		path = world_call("find_city_march_path", user:get_user_id(), sx, sy, target_id)
    elseif target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY then
        path = world_call("find_redeploy_path", user:get_user_id(), sx, sy, target_id, city_round)
	else
		path = world_call("find_march_path", user:get_user_id(), sx, sy, ex, ey)
	end
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
	local previous = troop:get_march_info()
	previous.state = troop:get_march_state()
	local previous_troop_state, previous_serial = troop:get_troop_state(), troop._data._march_serial
	troop:set_march({
		state = CONST.MARCH_STATE.MOVING,
		target_type = target_type,
		target_id = target_id,
		siege_round = target_type == DATA_COMMON.TARGET_TYPE.ATTACK_CITY and city_round or 0,
		redeploy_round = target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY and city_round or 0,
		path = path,
		start_time = now,
		end_time = now + cost,
	})
    -- 调动的部队状态先落盘，world 再变更驻留账本；崩溃恢复有明确的行军流水号。
    local deployment = target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY or previous.target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY
    local persisted, persist_error = true, nil
    if deployment then persisted, persist_error = pcall(MONGO_SLAVE.flush_snapshot) end
    local called, ok = false, false
    if persisted then called, ok = pcall(world_call, "start_march", troop:get_march_info())
    else skynet.error("redeploy state could not be saved", persist_error) end
	if not called or not ok then
        troop:set_march(previous)
        troop:set_troop_state(previous_troop_state)
        troop._data._march_serial = previous_serial
        if deployment then MONGO_SLAVE.flush_snapshot() end
		return false
	end
	ack_siege(troop)
	return true
end

local function begin_return(user, troop)
	if not user:has_birth_pos() then
		return false
	end
	return begin_march(user, troop, DATA_COMMON.TARGET_TYPE.RETURN_CITY, 0, user:get_birth_x(), user:get_birth_y())
end

-- 攻下城池（或同盟先完成最后一击）后转入同一套调动驻留账本。
-- 先持久化新的流水号和城池轮次，再登记驻留；失败重试不会重复扣兵/发战报。
local function stay_in_allied_city(user, troop)
    local city_id, serial = troop:get_target_id(), troop._data._march_serial
    local target, err = world_call("redeploy_target", city_id, user:get_user_id())
    if troop._data._march_serial ~= serial then return true end
    if not target then
        if not err then error("city deployment service unavailable") end
        return false
    end
    local now = TIME.now()
    troop:set_march({state = CONST.MARCH_STATE.ARRIVED, target_type = DATA_COMMON.TARGET_TYPE.REDEPLOY,
        target_id = city_id, redeploy_round = target.round,
        path = {{_x = target.x, _y = target.y}}, start_time = now, end_time = now})
    troop:set_arrived()
    local arrival_serial = troop._data._march_serial
    MONGO_SLAVE.flush_snapshot()
    local arrived = world_call("arrive_redeploy", troop:get_march_info())
    if troop._data._march_serial ~= arrival_serial then return true end
    if arrived == nil then error("city deployment arrival unavailable") end
    ack_siege(troop)
    return arrived
end

-- 同格战打输，从遭遇的那一格回城
function return_from(user, troop, x, y)
	if not user:has_birth_pos() then
		return false
	end
	return begin_march(user, troop, DATA_COMMON.TARGET_TYPE.RETURN_CITY, 0, user:get_birth_x(), user:get_birth_y(), x, y)
end

local function sync_troop_state(user, troop)
    local fd = user:get_fd()
    if fd then
        for_caller.s2c_sync_troop(fd, {troopInfo = troop:get_pto_info()})
        for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
    end
end

local function siege_timer(user_id, troop_idx, end_time, delay)
    skynet.timeout(math.max(1, math.ceil(delay * 100)), function()
        skynet.send(skynet.self(), "lua", "march_arrive", user_id, troop_idx, end_time)
    end)
end

function on_arrive(user_id, troop_idx, end_time)
	local user = USER_MGR.try_init_user(user_id)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if troop then ack_siege(troop) end
	if not troop or (troop:get_march_state() ~= CONST.MARCH_STATE.MOVING
		and not (troop:get_march_state() == CONST.MARCH_STATE.ARRIVED
			and (troop:get_target_type() == DATA_COMMON.TARGET_TYPE.ATTACK_CITY
                or troop:get_target_type() == DATA_COMMON.TARGET_TYPE.REDEPLOY))) then
		return
	end
	if end_time and end_time ~= troop:get_end_time() then
		return
	end
	if troop:get_march_state() == CONST.MARCH_STATE.MOVING and TIME.os_bj_sec() + 1 < troop:get_end_time() then
		return
	end
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.ATTACK_CITY then
        local ok, err = pcall(function()
            if troop:get_march_state() == CONST.MARCH_STATE.MOVING then
                local now = TIME.now()
                troop:set_siege(now, now + CONST.CITY_SIEGE_SECONDS)
                MONGO_SLAVE.flush_snapshot()
            else
                -- 兼容旧存档中已结算但返程失败的攻城，不重新延长计时或更换流水号。
                troop:set_troop_state(DATA_COMMON.TROOP_STATE.SIEGE)
            end
            MONGO_SLAVE.flush_snapshot()
            assert(world_call("siege_troop", troop:get_march_info()), "siege presentation unavailable")
            sync_troop_state(user, troop)
            local left = troop:get_end_time() - TIME.now()
            if left > 0 then
                siege_timer(user_id, troop_idx, troop:get_end_time(), left)
                return
            end
            local attack_serial = troop._data._march_serial
            local receipt = BATTLE_MGR.attack_city(user, troop)
            if troop._data._march_serial ~= attack_serial then return end
            if receipt and receipt.continue_siege then
                local now = TIME.now()
                troop:next_siege_round(now, now + CONST.CITY_SIEGE_SECONDS, receipt.city_round)
                -- 兵力和下一轮编号先持久化，才能清理上一轮回执。
                MONGO_SLAVE.flush_snapshot()
                ack_siege(troop)
                assert(world_call("siege_troop", troop:get_march_info()), "siege presentation unavailable")
                sync_troop_state(user, troop)
                siege_timer(user_id, troop_idx, troop:get_end_time(), CONST.CITY_SIEGE_SECONDS)
                return
            end
            if (not receipt or receipt.result.result == CONST.BATTLE_RESULT.WIN)
                and stay_in_allied_city(user, troop) then
                sync_troop_state(user, troop)
                return
            end
            if not begin_return(user, troop) then error("siege return path temporarily unavailable") end
            MONGO_SLAVE.flush_snapshot()
            sync_troop_state(user, troop)
        end)
        if not ok then
            skynet.error("city arrival retained for retry", user_id, troop_idx, err)
            siege_timer(user_id, troop_idx, troop:get_end_time(), 5)
        end
        return
    end
    if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.REDEPLOY then
        local arrival_serial = troop._data._march_serial
        local ok, err = pcall(function()
            troop:set_arrived()
            MONGO_SLAVE.flush_snapshot()
            local arrived = world_call("arrive_redeploy", troop:get_march_info())
            if troop._data._march_serial ~= arrival_serial then return end
            if arrived == nil then error("redeploy service unavailable") end
            if not arrived then
                -- 中途退盟、易主或旧到达通知，不能入驻，也不转为攻城。
                if not begin_return(user, troop) then error("redeploy return path unavailable") end
                MONGO_SLAVE.flush_snapshot()
            end
            sync_troop_state(user, troop)
        end)
        if not ok then
            skynet.error("redeploy arrival retained for retry", user_id, troop_idx, err)
            siege_timer(user_id, troop_idx, troop:get_end_time(), 5)
        end
        return
    end
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
	pto.troopState = DATA_COMMON.TROOP_STATE.IN_CITY
	troop:clear_march()
	world_call("hide_troop", user_id, troop_idx)
	if fd then
		for_caller.s2c_sync_troop(fd, {troopInfo = troop:get_pto_info()})
		for_caller.s2c_sync_march(fd, {marchInfo = pto})
	end
end

-- 资源地采满，世界服务通知回城
-- 地块被抢走：驻军还停在原地时强制回城
-- 世界服务里还是这支部队占着就继续采。倒计时没结束时归属还没写上，也要留在原地
-- 必须写在 on_occupy_done 前面：local function 对上面的全局函数不可见，会变成调 nil
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

function on_land_displaced(user_id, troop_idx, entity_id)
	local user = USER_MGR.try_init_user(user_id)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if not user or not troop then
		return
	end
	if troop:get_target_type() ~= DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND then
		return
	end
	if troop:get_target_id() ~= entity_id then
		return
	end
	if troop:get_march_state() ~= CONST.MARCH_STATE.ARRIVED then
		return
	end
	local fd = user:get_fd()
	if begin_return(user, troop) and fd then
		for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
	end
end

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
	reward_first_occupy(user, troop:get_target_id())
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

-- 首占在倒计时结束且归属仍有效时结算，按资源类型和等级去重。
function reward_first_occupy(user, entity_id)
	local info = world_call("res_land_info", entity_id)
	if not info or info.owner_id ~= user:get_user_id() then return end
	local land = DATA_COMMON.get_res_land_conf(info.cfg_id)
	if not land then return end
	local conf = DATA_COMMON.get_res_land_first_conf(land.Type, land.Level)
	if not conf or not conf.Reward or #conf.Reward == 0 then return end
	local key = land.Type * 1000 + land.Level
	if user._data._land_first[key] then return end
	user._data._land_first[key] = TIME.os_bj_sec()
	-- 首占奖励随归属确认自动到账，不打断地图操作。
	REWARD_MGR.reward_user_and_show(user:get_user_id(), conf.Reward,
		{CONST.FLOW_REASON.BATTLE, info.cfg_id}, {CONST.REWARD_SHOW_TYPE.NONE})
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
		ack_siege(troop)
		local state = troop:get_march_state()
		if state == CONST.MARCH_STATE.MOVING then
			if now >= troop:get_end_time() then
				on_arrive(user_id, troop:get_troop_idx(), troop:get_end_time())
			else
				world_call("start_march", troop:get_march_info())
			end
		elseif state == CONST.MARCH_STATE.ARRIVED and (troop:get_target_type() == DATA_COMMON.TARGET_TYPE.ATTACK_CITY
            or troop:get_target_type() == DATA_COMMON.TARGET_TYPE.REDEPLOY) then
			on_arrive(user_id, troop:get_troop_idx(), troop:get_end_time())
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
	if troop:get_troop_state() == DATA_COMMON.TROOP_STATE.SIEGE
        and packet.targetType ~= DATA_COMMON.TARGET_TYPE.RETURN_CITY then
        USER_MGR.tell_me(user_id, "部队正在攻城，请先撤回")
        return
    end
    -- world 已有战果而返程失败时，先取回回执再撤军，不能绕过战损结算。
    if troop:get_troop_state() == DATA_COMMON.TROOP_STATE.SIEGE and TIME.now() >= troop:get_end_time() then
        BATTLE_MGR.attack_city(user, troop)
    end
	local was_moving = troop:get_march_state() == CONST.MARCH_STATE.MOVING
	local ex, ey, target_id, city_round
    if packet.targetType == DATA_COMMON.TARGET_TYPE.REDEPLOY then
        local target, err = world_call("redeploy_target", packet.targetId or 0, user_id)
        if not target then USER_MGR.tell_me(user_id, err or "只能调动至本盟城池"); return end
        if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.REDEPLOY and troop:get_target_id() == packet.targetId
            and troop:get_march_state() ~= 0 then USER_MGR.tell_me(user_id, "部队已在调动或驻留"); return end
        ex, ey, target_id, city_round = target.x, target.y, packet.targetId, target.round
	elseif packet.targetType == DATA_COMMON.TARGET_TYPE.ATTACK_CITY then
		local target, err = world_call("city_target", packet.targetId or 0, user_id)
		if not target then
			USER_MGR.tell_me(user_id, err or "城池不存在")
			return
		end
		ex, ey, target_id = target.x, target.y, packet.targetId
		city_round = target.round
	elseif packet.targetType == DATA_COMMON.TARGET_TYPE.ATTACK_MONSTER then
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
		local holder = (info.owner_id ~= 0 and info.owner_id) or (info.pending_owner or 0)
		if holder ~= 0 and holder ~= user_id and not world_call("land_hostile", user_id, holder) then
			USER_MGR.tell_me(user_id, "不能攻打同盟领地")
			return
		end
		if not empty and info.owner_id == user_id and info.remain <= 0 then
			USER_MGR.tell_me(user_id, "资源尚未恢复")
			return
		end
		if info.troop_idx ~= 0 and info.troop_idx ~= troop:get_troop_idx() then
			if holder == user_id or holder == 0 then
				local occupying = info.occupy_end and info.occupy_end > TIME.os_bj_sec()
				USER_MGR.tell_me(user_id, occupying and "已有部队在占领" or (empty and "已有部队驻守" or "已有部队在采集"))
				return
			end
			-- 敌方驻军：允许出征，到达后同格交战
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
	if not begin_march(user, troop, packet.targetType, target_id, ex, ey, nil, nil, city_round) then
		USER_MGR.tell_me(user_id, "目标无法到达")
		return
	end
	MONGO_SLAVE.flush_snapshot()
	for_caller.s2c_sync_troop(fd, {troopInfo = troop:get_pto_info()})
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
	if not troop or (troop:get_march_state() ~= CONST.MARCH_STATE.MOVING
        and troop:get_troop_state() ~= DATA_COMMON.TROOP_STATE.SIEGE) then
		return
	end
	if troop:get_target_type() == DATA_COMMON.TARGET_TYPE.RETURN_CITY then
		return
	end
	if troop:get_troop_state() == DATA_COMMON.TROOP_STATE.SIEGE and TIME.now() >= troop:get_end_time() then
        BATTLE_MGR.attack_city(user, troop)
    end
	if not begin_return(user, troop) then
		return
	end
    MONGO_SLAVE.flush_snapshot()
    for_caller.s2c_sync_troop(fd, {troopInfo = troop:get_pto_info()})
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

-- 只查询，不调用 begin_march：不离开驻地、不结算采集、不修改部队、不触发出征任务。
local function on_req_march_route(fd, packet)
    local user = USER_MGR.get_user_by_fd(fd)
    if not user then return end
    local uid = user:get_user_id()
    local idx = math.tointeger(packet.troopIdx or 0) or 0
    local target_type = math.tointeger(packet.targetType or 0) or 0
    local pos = packet.targetPos or {}
    local x, y = math.tointeger(pos.x), math.tointeger(pos.y)
    local reply = {troopIdx = idx, targetType = target_type, targetPos = packet.targetPos, path = {}, costTime = 0}
    local troop = idx > 0 and TROOP_MGR.get_troop(uid, idx)
    local speed = target_type >= 1 and target_type <= DATA_COMMON.TARGET_TYPE.REDEPLOY
        and DATA_COMMON.get_march_speed(target_type)
    if user:has_birth_pos() and troop and troop:has_hero() and speed and speed > 0
        and x and y and x >= 0 and y >= 0 and x < 1000 and y < 1000
        and (troop:get_troop_state() ~= DATA_COMMON.TROOP_STATE.SIEGE
            or target_type == DATA_COMMON.TARGET_TYPE.RETURN_CITY) then
        local sx, sy = march_origin(user, troop, TIME.now())
        local ok, path = true, nil
        if target_type == DATA_COMMON.TARGET_TYPE.RETURN_CITY then
            -- 主城坐标由服务端决定；回城预览与实际指令使用同一条直线。
            path = return_path(sx, sy, user:get_birth_x(), user:get_birth_y())
        else
            ok, path = pcall(world_call, "find_march_route", uid, sx, sy, x, y, target_type)
        end
        if ok and path and #path >= 2 then
            reply.path = MARCH_PATH.to_pto(path)
            -- 协议为精确秒数；实际出发和界面倒计时统一向上取整。
            reply.costTime = MARCH_PATH.length(path) / speed
        elseif not ok then
            skynet.error("march route preview failed", uid, idx, path)
        end
    end
    -- 寻路跨服务会让出执行；断线或换号后不能把旧查询发给新会话。
    if USER_MGR.get_user_by_fd(fd) == user then
        for_caller.s2c_req_march_route(fd, reply)
    end
end

function __init__()
	for_maker.c2s_req_march_route = on_req_march_route
	for_maker.c2s_march = on_march
	for_maker.c2s_cancel_march = on_cancel_march
	for_maker.c2s_req_march_list = on_req_march_list
	for_maker.c2s_aoi_focus = on_aoi_focus
	for_maker.c2s_req_march_path = function(fd, packet)
		local user_id = USER_MGR.get_user_id_by_fd(fd)
		local entity_id = math.tointeger(packet and packet.entityId)
		if not user_id or not entity_id or entity_id <= 0 then return end
		local path = world_call("get_march_path", user_id, entity_id) or {}
		if USER_MGR.get_user_id_by_fd(fd) == user_id then
			for_caller.s2c_req_march_path(fd, {entityId = entity_id, path = path})
		end
	end
	EVENT.listen(CONST.EVENT.ON_USER_LOGIN)
end
