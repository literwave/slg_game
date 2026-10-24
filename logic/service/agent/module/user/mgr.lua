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
	if not user then
		return
	end
	user:on_logout()
	-- 各模块在这里存盘解绑自己的数据，所以要在玩家对象释放前发
	EVENT.fire(CONST.EVENT.ON_USER_LOGOUT, user_id, fd)
	MONGO_SLAVE.flush()
	ORM.unbind(MONGO_SLAVE.COL.USER_INFO, user_id)
	all_user_tbl[user_id] = nil
	del_user_id_by_vfd(fd)
	user_id_to_fd[user_id] = nil
	kicking_user[user_id] = nil
	ignore_heart_beat[user_id] = nil
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
	local user = get_user_by_id(user_id)
	if not user then
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
	disconnect(fd, user_id)
	if gate_srv and fd then
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
			EVENT.emit(CONST.EVENT.KICK_USER, fd, user_id, true)
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
	local world = skynet.localname(".world")
	if world then
		skynet.call(world, "lua", "upsert_city", user:get_user_id(), pos.x, pos.y)
	end
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

local function place_idle_troops(user)
	if not user:has_birth_pos() then
		return
	end
	local user_id = user:get_user_id()
	for _, troop in pairs(TROOP_MGR.get_user_troops(user_id) or {}) do
		if troop:get_march_state() == 0 and troop:has_hero() then
			skynet.call(".world", "lua", "park_troop", user_id, troop:get_troop_idx(), user:get_birth_x(), user:get_birth_y())
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
	if not skynet.call(".world", "lua", "move_city", user_id, x, y, old_x, old_y) then
		return false, "目标无法迁入"
	end
	if cost_list and not ITEM_MGR.del_cost_list(user_id, cost_list, {CONST.FLOW_REASON.MOVE_CITY, x, y}) then
		if skynet.call(".world", "lua", "move_city", user_id, old_x, old_y, x, y) then
			return false, "迁城令不足"
		end
		user:set_birth_pos(x, y)
		place_idle_troops(user)
		return true
	end
	user:set_birth_pos(x, y)
	place_idle_troops(user)
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
	for_maker.c2s_heart_beat = on_heart_beat
	for_maker.c2s_user_base_info = on_user_baseinfo
	for_maker.c2s_user_create = on_user_create
	for_maker.c2s_move_city = on_move_city
	for_maker.c2s_change_head_icon = on_change_head_icon
	for_maker.c2s_client_load_ok = on_client_load_ok
	EVENT.register(CONST.EVENT.KICK_USER)
	skynet.timeout(CONST.USER_HEART_BEAT_CHECK_INTERVAL * 100, check_heart_beat)
end