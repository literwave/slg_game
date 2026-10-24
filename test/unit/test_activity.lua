-- 活动只回列表请求：activityId、state、startTime、endTime

local MGR_FILE = "logic/service/agent/module/activity/mgr.lua"

local function setup()
	local env = setmetatable({}, {__index = _G})
	local sent = {}
	local user = {level = 5}
	function user:get_user_id() return 1 end
	function user:get_level() return self.level end
	function user:get_fd() return 9 end
	env.CONST = {
		ACTIVITY_TYPE = {LOGIN = 1, RANK = 2, LOTTERY = 3, RES_RATE = 4, GIFT = 5, ONLINE = 6, EXCHANGE = 7},
		ACTIVITY_STATE = {CLOSED = 0, OPEN = 1, END = 2},
		ACTIVITY_TIME = {ALWAYS = 1, OPEN_DAY = 2, WEEKDAY = 3, DAILY = 4},
		ONE_DAY_SEC = 86400,
		BUILD_TYPE = {MAIN_HALL = 1},
		EVENT = {
			ON_USER_LOGIN = "on_user_login",
			ON_HERO_ADD = "on_hero_add",
			ON_BUILD_LEVEL = "on_build_level",
			ON_HEAD_ICON = "on_head_icon",
			ON_HERO_LEVEL = "on_hero_level",
			ON_CALC_ITEM_REWARD = "on_calc_item_reward",
			ON_CALC_LOTTERY_COST = "on_calc_lottery_cost",
		},
		RANK_PAGE_MAX = 50,
		RANK_PAGE_DEFAULT = 20,
	}
	env.TIME = {
		os_bj_sec = function() return 86400 * 10 end,
		get_rela_day_no = function(t) return t // 86400 end,
		day_begin = function(t) return t - t % 86400 end,
		get_weekday = function() return 1 end,
	}
	env.GAME = {get_open_time = function() return 0 end}
	env.DATA_COMMON = {
		get_all_activity = function()
			return {
				{Id = 1, Type = 1, OpenCond = {level = 1}, Time = {type = 1}},
				{Id = 2, Type = 1, OpenCond = {level = 9}, Time = {type = 1}},
			}
		end,
		RANK_TYPE = {POWER = 1, CITY_LEVEL = 2},
		get_rank_type_conf = function() return nil end,
	}
	env.USER_MGR = {
		get_user_by_fd = function() return user end,
		get_user_id_by_fd = function() return 1 end,
		try_init_user = function() return user end,
	}
	env.EVENT = {listen = function() end}
	env.for_maker = {}
	env.for_caller = {
		s2c_req_activity_list = function(_, pack) sent[#sent + 1] = pack end,
	}
	env.skynet = {localname = function() return nil end}
	package.loaded.skynet = env.skynet
	assert(loadfile(MGR_FILE, "t", env))()
	env.__init__()
	return env, sent
end

local T = {}

function T.list_only_req_fields()
	local env, sent = setup()
	env.for_maker.c2s_req_activity_list(9)
	assert(#sent == 1)
	local list = sent[1].activityList
	assert(#list == 2)
	local open_one, closed_one
	for _, info in ipairs(list) do
		assert(info.activityId and info.state ~= nil and info.startTime == 0 and info.endTime == 0)
		assert(info.progress == nil and info.gotList == nil and info.extraMap == nil)
		if info.activityId == 1 then
			open_one = info
		else
			closed_one = info
		end
	end
	assert(open_one.state == 1)
	assert(closed_one.state == 0)
end

return T
