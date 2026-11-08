-- 串联真实战斗结算、发奖、战报和行军模块：守军不掉落，完成占领后只结算首占奖励。
local T = {}

local function load_module(path, shared)
	local env = setmetatable({}, {__index = function(_, key)
		local value = shared[key]
		if value ~= nil then return value end
		return _G[key]
	end})
	assert(loadfile(path, "t", env))()
	return env
end

local function fixture()
	local C = load_module("logic/define/const.lua", {})
	local configs = {}
	local function config(name)
		if not configs[name] then
			configs[name] = {}
			for key, row in pairs(dofile("game_common/server/res/" .. name .. ".lua")) do
				if type(row) == "table" then configs[name][row.Id or key] = row end
			end
		end
		return configs[name]
	end
	local f = {items = {}, pushes = {}, grants = 0, fights = 0, now = 1000,
		result = C.BATTLE_RESULT.WIN, blocked = false, reports = {_reports = {}, _next_id = 0},
		land = {cfg_id = 303, owner_id = 0, pending_owner = 0, troop_idx = 0, remain = 10000, x = 5, y = 6}}
	local user = {_data = {_land_first = {}}, get_user_id = function() return 7 end,
		get_name = function() return "占地主公" end, get_power = function() return 100 end,
		get_fd = function() return 9 end, has_birth_pos = function() return true end,
		get_birth_x = function() return 0 end, get_birth_y = function() return 0 end}
	local troop = {_data = {_siege_city = 0, _siege_seq = 0, _march_serial = 1},
		positions = {[1] = {_hero_idx = 1001, _soldier_cnt = 100, _hurt_cnt = 0}},
		state = C.MARCH_STATE.ARRIVED, target_type = 3, target_id = 99, start_time = 0, end_time = 3600, gathering = false}
	function troop:get_user_id() return 7 end
	function troop:get_troop_idx() return 1 end
	function troop:get_target_id() return self.target_id end
	function troop:get_target_type() return self.target_type end
	function troop:get_pos_tbl() return self.positions end
	function troop:set_pos(pos, hero, count, hurt)
		self.positions[pos] = {_hero_idx = hero, _soldier_cnt = count, _hurt_cnt = hurt}
	end
	function troop:get_pto_info() return {troopIdx = 1} end
	function troop:get_march_state() return self.state end
	function troop:get_troop_state() return 2 end
	function troop:get_start_time() return self.start_time end
	function troop:get_end_time() return self.end_time end
	function troop:get_end_pos() return 5, 6 end
	function troop:is_gathering() return self.gathering end
	function troop:get_march_info() return {} end
	function troop:get_march_pto() return {targetType = self.target_type, state = self.state} end
	function troop:set_march(info)
		self.state, self.target_type, self.end_time = info.state, info.target_type, info.end_time
		self.gathering = false
	end
	function troop:set_gather(start_time, end_time)
		self.start_time, self.end_time, self.gathering = start_time, end_time, true
	end
	function troop:set_occupy_wait() self.gathering = false end
	local sky = {getenv = function() return "1" end, localname = function() return ".world" end}
	function sky.call(_, _, cmd, ...)
		local args = {...}
		if cmd == "res_land_info" then return f.land end
		if cmd == "fight_batch" then
			f.fights = f.fights + 1
			return {{result = f.result, atk_left = {[1] = 90}, def_left = {[1] = 0}, actions = {}, max_round = 1}}
		end
		if cmd == "occupy_res_land" then
			if f.blocked then return end
			f.land.pending_owner, f.land.occupy_end, f.land.troop_idx = 7, f.now + 30, 1
			return nil, false, f.land.occupy_end
		end
		if cmd == "leave_res_land" then return math.min(args[4], 100) end
		if cmd == "find_march_path" then return {{_x = 5, _y = 6}, {_x = 0, _y = 0}} end
		if cmd == "start_march" or cmd == "kill_monster" then return true end
		if cmd == "monster_pos" then return {cfg_id = 1, x = 5, y = 6} end
		error("unexpected service call: " .. cmd)
	end
	local local_table = setmetatable({deepcopy = function(t)
		local copy = {}; for k, v in pairs(t) do copy[k] = v end; return copy
	end}, {__index = table})
	local S = {CONST = C, table = local_table,
		require = function(name) if name == "skynet" then return sky end; return require(name) end,
		TIME = {now = function() return f.now end, os_bj_sec = function() return f.now end},
		EVENT = {dispatch = function() end},
		GLOBAL_FUNC = {gen_reward_info = function(kind, id, count)
			return {reward_type = kind, item_id = id, item_count = count} end},
		DATA_COMMON = {TARGET_TYPE = dofile("game_common/server/enum/TargetTypeEnum.lua"),
			REPORT_TYPE = dofile("game_common/server/enum/ReportTypeEnum.lua"),
			get_res_land_conf = function(id) return config("ResLand")[id] end,
			get_res_land_first_conf = function(kind, level)
				for _, row in pairs(config("ResLandFirst")) do
					if row.Type == kind and row.Level == level then return row end
				end
			end,
			get_monster_conf = function(id) return config("Monster")[id] end,
			get_monster_group = function(id) return config("MonsterGroup")[id] end,
			get_march_speed = function() return 1 end},
		HERO_MGR = {get_hero_by_type = function() return {get_battle_skills = function() return {} end,
			get_level = function() return 1 end} end},
		USER_MGR = {try_init_user = function() return user end, get_fd_by_user_id = function() return 9 end},
		TROOP_MGR = {get_troop = function() return troop end},
		ITEM_MGR = {get_item_max_add_cnt = function() return nil end,
			add_item = function(_, id, count) f.items[id] = (f.items[id] or 0) + count; f.grants = f.grants + 1 end},
		ORM = {load = function() return f.reports end}, MONGO_SLAVE = {COL = {}},
		for_caller = setmetatable({}, {__index = function(_, name) return function(_, packet)
			f.pushes[name] = f.pushes[name] or {}
			table.insert(f.pushes[name], packet)
		end end}),
	}
	S.REWARD_MGR = load_module("logic/service/agent/module/reward/mgr.lua", S)
	S.REPORT_MGR = load_module("logic/service/agent/module/report/mgr.lua", S)
	S.MARCH_PATH = load_module("common/march_path.lua", S)
	S.MARCH_MGR = load_module("logic/service/agent/module/march/mgr.lua", S)
	S.BATTLE_MGR = load_module("logic/service/agent/module/battle/mgr.lua", S)
	f.S, f.user, f.troop = S, user, troop
	return f
end

local function assert_silent(f)
	local pushes = assert(f.pushes.s2c_show_reward, "必须保留发奖通知")
	for _, packet in ipairs(pushes) do
		assert(#packet.showTypeList == 1 and packet.showTypeList[1] == f.S.CONST.REWARD_SHOW_TYPE.NONE,
			"占地自动结算不能弹领奖窗口")
	end
end

function T.defeating_land_guards_only_starts_countdown_without_rewards()
	local f = fixture()
	assert(#f.S.DATA_COMMON.get_res_land_conf(303).Reward > 0, "即使资源地表仍有 Reward，也不能发守军掉落")
	local gather_end, held, occupy_end = f.S.BATTLE_MGR.occupy_res_land(f.user, f.troop)
	assert(not gather_end and not held and occupy_end == 1030 and f.land.owner_id == 0)
	assert(f.grants == 0 and next(f.items) == nil and not f.pushes.s2c_show_reward)
	assert(next(f.user._data._land_first) == nil)
	local report = f.reports._reports[1]
	assert(report._result == f.S.CONST.BATTLE_RESULT.WIN and #report._rewards == 0)
	local result = f.pushes.s2c_battle_result[1]
	assert(result.reportId == report._report_id and #result.rewardList == 0)
end

function T.defeat_or_failed_claim_does_not_grant_resources()
	for _, mode in ipairs({"defeat", "blocked"}) do
		local f = fixture()
		if mode == "defeat" then f.result = f.S.CONST.BATTLE_RESULT.LOSE else f.blocked = true end
		f.S.BATTLE_MGR.occupy_res_land(f.user, f.troop)
		assert(f.grants == 0 and not f.pushes.s2c_show_reward)
		assert(#f.reports._reports[1]._rewards == 0)
	end
end

function T.first_capture_waits_for_ownership_then_rewards_once_without_popup()
	local f = fixture()
	f.S.BATTLE_MGR.occupy_res_land(f.user, f.troop)
	f.S.MARCH_MGR.on_occupy_done(7, 1, 2000)
	assert(f.grants == 0 and not f.pushes.s2c_show_reward, "倒计时未结束不能发任何占地奖励")
	f.now = f.land.occupy_end
	f.land.owner_id, f.land.pending_owner, f.land.occupy_end = 7, 0, 0
	f.S.MARCH_MGR.on_occupy_done(7, 1, 2000)
	local rewards = f.S.DATA_COMMON.get_res_land_first_conf(3, 3).Reward
	assert(f.grants == #rewards and #f.pushes.s2c_show_reward == 1)
	local expected = {}
	for _, rw in ipairs(rewards) do expected[rw.item_id] = (expected[rw.item_id] or 0) + rw.item_count end
	for id, count in pairs(expected) do assert(f.items[id] == count) end
	f.S.MARCH_MGR.on_occupy_done(7, 1, 2000)
	assert(f.grants == #rewards and #f.pushes.s2c_show_reward == 1 and f.user._data._land_first[3003] == f.now)
	assert(f.troop:is_gathering())
	assert_silent(f)
end

function T.canceled_or_displaced_capture_does_not_reward_or_consume_first_capture()
	for _, mode in ipairs({"returning", "lost", "other_troop"}) do
		local f = fixture()
		f.S.BATTLE_MGR.occupy_res_land(f.user, f.troop)
		f.now = f.land.occupy_end
		f.land.owner_id, f.land.pending_owner, f.land.occupy_end = 7, 0, 0
		if mode == "returning" then
			f.troop.state = f.S.CONST.MARCH_STATE.MOVING
		elseif mode == "lost" then
			f.land.owner_id = 8
		else
			f.land.troop_idx = 2
		end
		f.S.MARCH_MGR.on_occupy_done(7, 1, 2000)
		assert(f.grants == 0 and not f.pushes.s2c_show_reward)
		assert(next(f.user._data._land_first) == nil, "未完成占领不能消耗首占资格")
	end
end

function T.another_land_of_same_type_and_level_does_not_reward_again()
	local f = fixture()
	for _, entity_id in ipairs({99, 100}) do
		f.troop.target_id, f.troop.gathering = entity_id, false
		f.land = {cfg_id = 303, owner_id = 0, pending_owner = 0, troop_idx = 0, remain = 10000, x = entity_id, y = 6}
		local previous = f.grants
		f.S.BATTLE_MGR.occupy_res_land(f.user, f.troop)
		assert(f.grants == previous, "再次击败守军也不能发掉落")
		f.now = f.land.occupy_end
		f.land.owner_id, f.land.pending_owner, f.land.occupy_end = 7, 0, 0
		f.S.MARCH_MGR.on_occupy_done(7, 1, 2000)
		if entity_id == 100 then assert(f.grants == previous) end
	end
	assert(f.fights == 2 and #f.pushes.s2c_show_reward == 1)
	assert(f.grants == #f.S.DATA_COMMON.get_res_land_first_conf(3, 3).Reward)
	assert_silent(f)
end

function T.gather_completion_keeps_world_capped_reward_and_does_not_popup()
	local f = fixture()
	f.land.owner_id, f.land.troop_idx, f.troop.gathering, f.now = 7, 1, true, 3600
	f.S.MARCH_MGR.on_gather_full(7, 1, 3600)
	assert(f.items[3] == 100 and f.grants == 1, "实际奖励仍使用世界服务确认的采集量")
	assert(f.troop:get_target_type() == f.S.DATA_COMMON.TARGET_TYPE.RETURN_CITY)
	f.S.MARCH_MGR.on_gather_full(7, 1, 3600)
	assert(f.grants == 1, "重复采集结束通知不能重复发奖")
	assert_silent(f)
end

function T.other_reward_sources_keep_their_original_display_mode()
	local f = fixture()
	f.S.BATTLE_MGR.attack_monster(f.user, f.troop)
	assert(f.grants > 0 and #f.pushes.s2c_show_reward[1].showTypeList == 0)
	local reward = {{reward_type = 1, item_id = 3, item_count = 10}}
	f.S.REWARD_MGR.reward_user_and_show(7, reward, {})
	f.S.REWARD_MGR.reward_user_and_show(7, reward, {}, {f.S.CONST.REWARD_SHOW_TYPE.WINDOW})
	assert(#f.pushes.s2c_show_reward[2].showTypeList == 0)
	assert(f.pushes.s2c_show_reward[3].showTypeList[1] == f.S.CONST.REWARD_SHOW_TYPE.WINDOW)
end

return T
