-- 公开资料请求链路、在线/离线快照与请求者连接隔离。
local T = {}
local function fixture()
	local rows = {user = {_user_id = 123, _name = "同袍", _head_icon = 1043,
		_sex = 1, _level = 7, _offline_time = 0, _login_time = 900, _birth_time = 800,
		_real_diamond = 999, _soldier_cnt = 1000},
		hero = {_heroes = {["1001"] = {_hero_type = 1001, _level = 2}}},
		build = {_builds = {["1"] = {_level = 8}}}}
	local sent, calls, timers = {}, {}, {}
	local env, during_read
	local sky = {timeout = function(delay, callback) timers[#timers + 1] = {delay, callback} end}
	sky.call = function(service, _, method, uid)
		calls[#calls + 1] = {service = service, method = method, uid = uid}
		if method == "get_agent_list" then return {11, 12, 13} end
		if method == "public_user_profile" then
			if during_read then during_read() end
			return env.get_public_profile(uid)
		end
		if method == "public_user_alliance" then return {id = 77, name = "山河"} end
		error("unexpected call " .. tostring(method))
	end
	env = setmetatable({require = function(n) assert(n == "skynet"); return sky end,
		MONGO_SLAVE = {COL = {USER_INFO = "user", USER_HERO = "hero", USER_BUILD = "build"},
			common_load_single = function(col, uid) if uid == 123 then return rows[col] end end},
		DATA_COMMON = {get_hero_info_by_type = function() return {Attack=10, Hp=20, Defense=30, Speed=40, Crit=50} end,
			get_main_city_bid = function() return 1 end},
		CONST = {EVENT = {KICK_USER = "kick"}, USER_HEART_BEAT_CHECK_INTERVAL = 30},
		EVENT = {register = function() end}, for_maker = {},
		for_caller = {s2c_req_other_user = function(fd, packet) sent[#sent + 1] = {fd = fd, packet = packet} end},
	}, {__index = _G})
	assert(loadfile("logic/service/agent/module/user/mgr.lua", "t", env))()
	env.__init__()
	env.fd_to_user_id[7] = 55
	return env, rows, sent, calls, function(fn) during_read = fn end, timers
end

function T.profile_hot_reload_rebinds_handler_without_duplicate_heartbeat()
	local U, _, sent, _, _, timers = fixture()
	assert(#timers == 1 and timers[1][1] == 3000)
	U.for_maker.c2s_req_other_user = function() error("stale handler") end
	U.__init__()
	U.__init__()
	assert(#timers == 1, "热更不能重复启动心跳检查")
	assert(U.fd_to_user_id[7] == 55)
	U.for_maker.c2s_req_other_user(7, {uid = 123})
	assert(#sent == 1 and sent[1].packet.uid == 123)
end

function T.offline_legacy_zero_is_never_online()
	local U, rows = fixture()
	local p = U.get_public_profile(123)
	assert(p.offlineTime == 900 and p.power == 300 and p.cityLevel == 8)
	rows.user._offline_time = 950
	assert(U.get_public_profile(123).offlineTime == 950)
	rows.user._offline_time, rows.user._login_time = 0, 0
	assert(U.get_public_profile(123).offlineTime == 800)
	rows.user._birth_time = 0
	assert(U.get_public_profile(123).offlineTime == 1)
	assert(not next(U.all_user_tbl), "离线查询不能创建或绑定玩家对象")
	assert(p._real_diamond == nil and p.soldierInfo == nil and p.exp == nil)
end

function T.online_uses_live_values_and_zero_only_for_connected_user()
	local U = fixture()
	U.all_user_tbl[123] = {_data = {_offline_time = 0, _login_time = 910},
		get_name = function() return "在线主公" end, get_head_icon = function() return 1044 end,
		get_sex = function() return 1 end, get_level = function() return 20 end,
		get_power = function() return 9999 end, get_city_level = function() return 9 end}
	U.user_id_to_fd[123] = 99
	local p = U.get_public_profile(123)
	assert(p.name == "在线主公" and p.power == 9999 and p.offlineTime == 0)
	U.user_id_to_fd[123] = nil
	assert(U.get_public_profile(123).offlineTime == 910)
end

function T.request_routes_to_owner_agent_and_adds_public_alliance()
	local U, _, sent, calls = fixture()
	U.for_maker.c2s_req_other_user(7, {uid = 123})
	assert(#sent == 1 and sent[1].fd == 7)
	local p = sent[1].packet
	assert(p.uid == 123 and p.allianceId == 77 and p.allianceName == "山河")
	assert(calls[2].service == 11 and calls[2].method == "public_user_profile")
	assert(p._soldier_cnt == nil and p._real_diamond == nil)
end

function T.missing_player_echoes_uid_and_invalid_requests_are_rejected()
	local U, _, sent, calls = fixture()
	U.for_maker.c2s_req_other_user(7, {uid = 999})
	assert(#sent == 1 and sent[1].packet.uid == 999 and sent[1].packet.name == nil)
	assert(#calls == 2, "不存在的玩家不查询同盟")
	for _, uid in ipairs({0, -1, 1.5, "invalid"}) do U.for_maker.c2s_req_other_user(7, {uid = uid}) end
	U.for_maker.c2s_req_other_user(88, {uid = 123})
	assert(#sent == 1 and #calls == 2)
end

function T.disconnected_or_reused_requester_does_not_receive_late_profile()
	local U, _, sent, _, before = fixture()
	before(function() U.fd_to_user_id[7] = 66 end)
	U.for_maker.c2s_req_other_user(7, {uid = 123})
	assert(#sent == 0)
end

return T
