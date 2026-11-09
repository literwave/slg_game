local skynet = require "skynet"

all_user_tbl = {
	-- [userId] = userObj
}
fd_to_user_id = {
	-- [vfd] = userId
}
user_id_to_fd = {
	-- [userId] = vfd
}

function tell_me_by_language_id(user_id, ...)
	local fd = get_fd_by_user_id(user_id)
	if fd then
		local tbl = table.val_to_number({...})
		for_caller.s2c_sys_notify_by_lanid(fd, {tbl = tbl})
	end
end

function tell_me(user_id, msg)
	local fd = get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	if type(msg) == "string" then
		msg = { msg = msg }
	end
	for_caller.s2c_tell_me(fd, msg)
end

function get_user_by_id(user_id)
	return all_user_tbl[user_id]
end

function get_user_id_by_vfd(fd)
	return fd_to_user_id[fd]
end

function del_user_id_by_vfd(fd)
	fd_to_user_id[fd] = nil
end

function get_fd_by_user_id(user_id)
	return user_id_to_fd[user_id]
end

function get_user_by_fd(fd)
	local user_id = fd_to_user_id[fd]
	return all_user_tbl[user_id]
end

function get_user_id_by_fd(fd)
	return fd_to_user_id[fd]
end

function get_gate_srv_by_fd(fd)
	local user = get_user_by_fd(fd)
	local gate_srv = user:get_gate_srv()
	return gate_srv
end

kicking_user = {}
ignore_heart_beat = {}

function disconnect(fd, user_id)
    local user = get_user_by_id(user_id)
    if not user or get_fd_by_user_id(user_id) ~= fd then return false end
    user:on_logout()
    ACTIVITY_MGR.on_user_logout(user_id)
    -- No module may release its cache until the final persistence ACK succeeds.
    local ok, result = pcall(MONGO_SLAVE.flush_snapshot)
    if not ok or result ~= true then
        kicking_user[user_id] = nil
        error(ok and "logout persistence was not acknowledged" or result, 0)
    end
    -- A suspended save must never release a replacement session's objects.
    if get_user_by_id(user_id) ~= user or get_fd_by_user_id(user_id) ~= fd then return false end
    -- Local logout listeners only release caches; this phase must not yield.
    EVENT.dispatch(CONST.EVENT.ON_USER_LOGOUT, user_id, fd)
    ORM.unbind(MONGO_SLAVE.COL.USER_INFO, user_id)
    all_user_tbl[user_id] = nil
    del_user_id_by_vfd(fd)
    user_id_to_fd[user_id] = nil
    kicking_user[user_id] = nil
    ignore_heart_beat[user_id] = nil
    -- Cross-service notification may yield, after local state is fully released.
    EVENT.emit(CONST.EVENT.ON_USER_LOGOUT, user_id, fd)
    return true
end

-- Offline world jobs borrow the same caches without opening a player session.
-- Release only after their final ACK, without online-time settlement or events.
function release_offline_cache(user_id)
    if get_fd_by_user_id(user_id) then return end
    local user, documents = get_user_by_id(user_id), {}
    for _, col in ipairs({MONGO_SLAVE.COL.USER_INFO, MONGO_SLAVE.COL.USER_HERO,
        MONGO_SLAVE.COL.USER_ITEM, MONGO_SLAVE.COL.USER_BUILD, MONGO_SLAVE.COL.USER_TROOP,
        MONGO_SLAVE.COL.USER_TASK, MONGO_SLAVE.COL.USER_SKILL, MONGO_SLAVE.COL.USER_REPORT}) do
        local doc = ORM.get(col, user_id)
        if doc then documents[col] = doc end
    end
    if not user and not next(documents) then return end
    ACTIVITY_MGR.on_user_logout(user_id) -- derived scores only, no logout event
    assert(MONGO_SLAVE.flush_snapshot() == true, "offline persistence was not acknowledged")
    if get_fd_by_user_id(user_id) or get_user_by_id(user_id) ~= user then return end
    for col, doc in pairs(documents) do if ORM.get(col, user_id) ~= doc then return end end
    -- These hooks only drop local document bindings/indexes and never yield.
    HERO_MGR.on_user_logout(user_id)
    ITEM_MGR.on_user_logout(user_id)
    BUILD_MGR.on_user_logout(user_id)
    TROOP_MGR.on_user_logout(user_id)
    TASK_MGR.on_user_logout(user_id)
    SKILL_MGR.on_user_logout(user_id)
    REPORT_MGR.on_user_logout(user_id)
    ORM.unbind(MONGO_SLAVE.COL.USER_INFO, user_id)
    all_user_tbl[user_id] = nil
    kicking_user[user_id], ignore_heart_beat[user_id] = nil, nil
end

function is_new_user(user_id)
	local user = all_user_tbl[user_id]
	local is_new_user = false
	if not user then
		local save_tbl = MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.USER_INFO, user_id) or {}
		if table.is_empty(save_tbl) then
			is_new_user = true
		end
	end
	return is_new_user
end

function try_init_user(user_id)
	local user = all_user_tbl[user_id]
	if not user then
		local save_tbl = MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.USER_INFO, user_id) or {}
		user = USER_BASE.cls_user:New(save_tbl)
		all_user_tbl[user_id] = user
	end
	return user
end

-- 主城进视野时带玩家名和主城建筑等级。没有主城坐标则不推
function sync_city_aoi(user)
	if not user or not user:has_birth_pos() then
		return
	end
	local world = skynet.localname(".world")
	if not world then
		return
	end
	local build = BUILD_MGR.get_build_by_bid(user:get_user_id(), DATA_COMMON.get_main_city_bid())
	skynet.call(world, "lua", "upsert_city", user:get_user_id(), user:get_birth_x(), user:get_birth_y(), {
		name = user:get_name(),
		level = build:get_level(),
	})
end

function ref_login(user_id, fd, user)
	user_id_to_fd[user_id] = fd
	fd_to_user_id[fd] = user_id
	all_user_tbl[user_id] = user
	user:set_heart_beat_time(TIME.os_bj_sec())
end

function get_game_user_id()
	return MONGO_SLAVE.fetch_user_id()
end

function create_new_user(gate_srv, fd, user_id, server_id)
	local oci = {
		_user_id = user_id,
		_birth_time = TIME.os_bj_sec(),
		_born_server_id = server_id,
		_name = CONST.NO_NAME,
		_sex = CONST.SEX_NONE,
		_head_icon = DATA_COMMON.get_value_by_key(2),
	}
	local user = USER_BASE.cls_user:New(oci)
	ref_login(user_id, fd, user)
	-- user:setFd(fd)
	-- print("gateSrv", gateSrv)
	-- user:setGateSrv(gateSrv)
	-- local userName = RANDOM_NAME.genNewUserName()
	-- user:setName(userName)
	ORM.touch(user._data)
	user:set_fd(fd)
	user:set_gate_srv(gate_srv)
	-- WORK_QUEUE_MGR.initUserWorkQueue(userId)
	REWARD_MGR.reward_user(user_id, DATA_COMMON.get_value_by_key(1))
	return user
	-- USER_MGR.updateUserPower(userId, CONST.POWER_TYPE.HERO)
end

-- 玩家自己的登录数据先记好，其它模块在 ON_USER_LOGIN 里处理。返回 user:on_login 的跨周期结果
function module_on_user_login(user, is_first_login)
	return user:on_login()
end

-- 离线跨过多天也只发一次
function dispatch_cross(user_id, cross)
	if not cross then
		return
	end
	EVENT.dispatch(CONST.EVENT.ON_NEW_DAY, user_id)
	if cross.week then
		EVENT.dispatch(CONST.EVENT.ON_NEW_WEEK, user_id)
	end
	if cross.month then
		EVENT.dispatch(CONST.EVENT.ON_NEW_MONTH, user_id)
	end
end

function kick_user(fd, user_id, from_heart_beat)
    -- Event callbacks run outside the client queue; route kicks through it too.
    skynet.send(skynet.self(), "lua", "kick_user", fd, user_id, from_heart_beat)
end

function kick_user_in_queue(fd, user_id, from_heart_beat)
	local user = get_user_by_id(user_id)
	if not user or get_fd_by_user_id(user_id) ~= fd then
		kicking_user[user_id] = nil
		return
	end
	if from_heart_beat then
		local last_heart_beat_time = user:get_heart_beat_time()
		local now = TIME.os_bj_sec()
		if not last_heart_beat_time or now - last_heart_beat_time < CONST.USER_HEART_BEAT_TIMEOUT then
			kicking_user[user_id] = nil
			return
		end
	end
	local gate_srv = user:get_gate_srv()
	local disconnected = disconnect(fd, user_id)
	if disconnected and gate_srv and fd then
		skynet.send(gate_srv, "lua", "kick", fd)
	end
end

local function check_heart_beat()
	local now = TIME.os_bj_sec()
	for user_id, user in pairs(all_user_tbl) do
		local last_heart_beat_time = user:get_heart_beat_time()
		if last_heart_beat_time and not kicking_user[user_id]
			and now - last_heart_beat_time >= CONST.USER_HEART_BEAT_TIMEOUT then
			kicking_user[user_id] = true
			local fd = get_fd_by_user_id(user_id)
			skynet.send(skynet.self(), "lua", "kick_user", fd, user_id, true)
		end
	end
	skynet.timeout(CONST.USER_HEART_BEAT_CHECK_INTERVAL * 100, check_heart_beat)
end

function hold_heart_beat(user_id)
	ignore_heart_beat[user_id] = true
end

local function on_heart_beat(fd)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local user_id = user:get_user_id()
	if ignore_heart_beat[user_id] then
		return
	end
	kicking_user[user_id] = nil
	local now = TIME.os_bj_sec()
	user:set_and_sync_heart_beat_time(now)
	local cross, minute_changed = user:tick_online(now)
	dispatch_cross(user_id, cross)
	if minute_changed then
		EVENT.dispatch(CONST.EVENT.ON_ONLINE_MINUTE, user_id)
	end
end

local function on_user_baseinfo(fd)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	user:sync_user_base_info()
end

local function on_client_load_ok(fd)
	local user = get_user_by_fd(fd)
	if not user then
		return
	end
	user:set_client_load_ok()
	for_caller.s2c_client_load_ok(fd, {})
end

-- 协议约定 0 只表示在线。旧存档可能尚无离线时间，不能因 Lua 的 0 为真而误报在线。
local function public_offline_time(raw)
	local time = tonumber(raw._offline_time) or 0
	if time <= 0 then time = tonumber(raw._login_time) or 0 end
	if time <= 0 then time = tonumber(raw._birth_time) or 1 end
	return math.max(1, math.floor(time))
end

-- 在目标玩家所属的 agent 读取。离线查询只读原始快照，不创建或绑定玩家对象。
function get_public_profile(user_id)
    -- Public reads never acquire the target player's queue: two players can
    -- inspect each other. They also never call getters that lazy-bind data.
    for _ = 1, 3 do
        local user, fd = get_user_by_id(user_id), get_fd_by_user_id(user_id)
        local raw = user and user._data or MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.USER_INFO, user_id)
        if not raw or not raw._user_id then return end
        local heroes = user and ORM.get(MONGO_SLAVE.COL.USER_HERO, user_id)
        local builds = user and ORM.get(MONGO_SLAVE.COL.USER_BUILD, user_id)
        heroes = heroes or MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.USER_HERO, user_id) or {}
        builds = builds or MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.USER_BUILD, user_id) or {}
        if get_user_by_id(user_id) == user and get_fd_by_user_id(user_id) == fd then
            -- A module may have loaded/updated its cache during a database wait.
            if user then
                heroes = ORM.get(MONGO_SLAVE.COL.USER_HERO, user_id) or heroes
                builds = ORM.get(MONGO_SLAVE.COL.USER_BUILD, user_id) or builds
            end
            local power = 0
            for key, hero in pairs(heroes._heroes or {}) do
                local conf = DATA_COMMON.get_hero_info_by_type(hero._hero_type or tonumber(key))
                if conf then
                    power = power + ((conf.Attack or 0) + (conf.Hp or 0) + (conf.Defense or 0)
                        + (conf.Speed or 0) + (conf.Crit or 0)) * (hero._level or 0)
                end
            end
            local bid, bag = DATA_COMMON.get_main_city_bid(), builds._builds or {}
            local city = bag[bid] or bag[tostring(bid)]
            return {
                uid = user_id, name = user and user:get_name() or raw._name or "",
                headIcon = user and user:get_head_icon() or raw._head_icon or 0,
                sex = user and user:get_sex() or raw._sex or 0,
                level = user and user:get_level() or raw._level or 0, power = power,
                cityLevel = city and city._level or 0, offlineTime = fd and 0 or public_offline_time(raw),
            }
        end
    end
    -- Repeated session churn is retried by a later request, never a stale reply.
end

local function on_req_other_user(fd, packet)
	local requester = get_user_id_by_fd(fd)
	local uid = math.tointeger(packet and packet.uid)
	if not requester or not uid or uid <= 0 then return end
	local agents = skynet.call(".gated", "lua", "get_agent_list")
	if not agents or #agents == 0 then return end
	-- 不锁目标玩家队列，避免两人同时互查时相互等待。
	local profile = skynet.call(agents[uid % #agents + 1], "lua", "public_user_profile", uid)
	if profile then
		local alliance = skynet.call(".union", "lua", "public_user_alliance", uid)
		profile.allianceId = alliance and alliance.id or 0
		profile.allianceName = alliance and alliance.name or ""
	end
	if get_user_id_by_fd(fd) == requester then
		for_caller.s2c_req_other_user(fd, profile or {uid = uid})
	end
end

local function on_user_create(fd, packet)
	local sex = packet.sex
	local name = packet.name
	if sex < CONST.SEX_MAN or sex > CONST.SEX_WOMAN then
		return
	end
	local name_len = utf8.len(name)
	if not name_len or name_len < 1 or name_len > CONST.USER_NAME_MAX_LEN then
		return
	end
	local user = USER_MGR.get_user_by_fd(fd)
	if not user or user:get_sex() ~= CONST.SEX_NONE then
		return
	end
	local pos = skynet.call(".world", "lua", "alloc_birth_pos")
	if not pos then
		tell_me(user:get_user_id(), "没有可用的出生点")
		return
	end
	user:set_birth_pos(pos.x, pos.y)
	user:set_sex(sex)
	user:set_name(name)
	sync_city_aoi(user)
	for_caller.s2c_user_create(fd, {
		name = name,
		sex = sex,
	})
	user:sync_city_pos()
end

local function city_move_cost()
	return {
		{
			cost_type = CONST.COST_TYPE.ITEM,
			itemId = CONST.MOVE_CITY_ITEM,
			count = 1,
		},
	}
end

local function clear_home_troops(user)
	local user_id = user:get_user_id()
	local world = skynet.localname(".world")
	if not world then
		return
	end
	for _, troop in pairs(TROOP_MGR.get_user_troops(user_id) or {}) do
		if troop:get_march_state() == 0 then
			skynet.call(world, "lua", "hide_troop", user_id, troop:get_troop_idx())
		end
	end
end

local function troop_outside(user_id)
	for _, troop in pairs(TROOP_MGR.get_user_troops(user_id) or {}) do
		if troop:get_march_state() ~= 0 then
			return true
		end
	end
	return false
end

-- cost 为 true 时扣一张迁城令。成功后主城坐标已写入玩家和地图
function try_move_city(user, x, y, cost)
	if not user:has_birth_pos() then
		return false, "没有主城"
	end
	if not x or not y then
		return false, "坐标不对"
	end
	x, y = math.floor(x), math.floor(y)
	local old_x, old_y = user:get_birth_x(), user:get_birth_y()
	if x == old_x and y == old_y then
		return false, "已经在这个坐标"
	end
	local user_id = user:get_user_id()
	if troop_outside(user_id) then
		return false, "部队在城外"
	end
	local cost_list = cost and city_move_cost()
	if cost_list and not ITEM_MGR.check_cost_enough(user_id, cost_list) then
		return false, "迁城令不足"
	end
	local show = {
		name = user:get_name(),
		level = BUILD_MGR.get_build_by_bid(user_id, DATA_COMMON.get_main_city_bid()):get_level(),
	}
	if not skynet.call(".world", "lua", "move_city", user_id, x, y, old_x, old_y, show) then
		return false, "目标无法迁入"
	end
	if cost_list and not ITEM_MGR.del_cost_list(user_id, cost_list, {CONST.FLOW_REASON.MOVE_CITY, x, y}) then
		if skynet.call(".world", "lua", "move_city", user_id, old_x, old_y, x, y, show) then
			return false, "迁城令不足"
		end
		user:set_birth_pos(x, y)
		clear_home_troops(user)
		return true
	end
	user:set_birth_pos(x, y)
	clear_home_troops(user)
	return true
end

local function on_move_city(fd, packet)
	local user = get_user_by_fd(fd)
	local pos = packet and packet.pos
	if not user or not pos then
		return
	end
	local ok, msg = try_move_city(user, pos.x, pos.y, true)
	if not ok then
		tell_me(user:get_user_id(), msg)
		return
	end
	for_caller.s2c_move_city(fd, {cityPos = user:get_city_pos_pto()})
	user:sync_city_pos()
end

local function on_change_head_icon(fd, packet)
	local head_icon = packet.headIcon
	if not DATA_COMMON.get_head_icon_info(head_icon) then
		return
	end
	local user = get_user_by_fd(fd)
	if not user or not user:is_system_open(HEAD_ICON) then
		return
	end
	user:set_head_icon(head_icon)
	for_caller.s2c_change_head_icon(fd, {headIcon = head_icon})
	EVENT.dispatch(CONST.EVENT.ON_HEAD_ICON, user:get_user_id(), 1)
end

function __init__()
	-- 热更会再次注册协议；沿用已经启动的心跳检查，避免重复创建循环定时器。
	local heart_beat_registered = rawget(for_maker, "c2s_heart_beat") ~= nil
	for_maker.c2s_heart_beat = on_heart_beat
	for_maker.c2s_user_base_info = on_user_baseinfo
	for_maker.c2s_user_create = on_user_create
	for_maker.c2s_move_city = on_move_city
	for_maker.c2s_change_head_icon = on_change_head_icon
	for_maker.c2s_client_load_ok = on_client_load_ok
	for_maker.c2s_req_other_user = on_req_other_user
	EVENT.register(CONST.EVENT.KICK_USER)
	if not heart_beat_registered then
		skynet.timeout(CONST.USER_HEART_BEAT_CHECK_INTERVAL * 100, check_heart_beat)
	end
end
