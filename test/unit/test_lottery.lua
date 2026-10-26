-- 点将：按道具消耗扣费，普通池/武将池按权重选池，奖励带普通弹窗

local FILE = "logic/service/agent/module/lottery/lottery.lua"

local function setup(opt)
	opt = opt or {}
	local env = setmetatable({}, {__index = _G})
	local user = {id = 7, times = opt.times or 3, fd = 9}
	function user:get_user_id() return self.id end
	function user:get_lottery_times() return self.times end
	function user:set_lottery_times(n) self.times = n end

	local conf = {
		CostList = opt.cost or {{item_id = 103, count = 1}},
		CommonPools = opt.common or {{reward_type = 1, item_id = 1, item_count = 500, weight = 10}},
		HeroPools = opt.hero or {{reward_type = 3, item_id = 1001, item_count = 1, weight = 0}},
	}
	local shown, sent, events, enough = nil, nil, {}, opt.enough ~= false
	env.EMPTY_TABLE = {}
	env.CONST = {
		COST_TYPE = {ITEM = 3},
		FLOW_REASON = {LOTTERY = 4},
		REWARD_SHOW_TYPE = {NONE = 0, WINDOW = 1},
		EVENT = {ON_CALC_LOTTERY_COST = "cost", ON_LOTTERY = "lottery"},
	}
	env.EVENT = {
		dispatch = function(name, _, ctx)
			events[#events + 1] = name
			if name == "cost" and opt.rate then
				ctx.rate = opt.rate
			end
		end,
	}
	env.DATA_COMMON = {get_lottery_conf = function(n) return n == (opt.id or 1) and conf or nil end}
	env.USER_MGR = {get_user_by_fd = function() return user end}
	env.ITEM_MGR = {
		check_cost_enough = function(_, list)
			user.checked = list
			return enough
		end,
		del_cost_list = function()
			user.paid = true
			return true
		end,
	}
	env.GLOBAL_FUNC = {
		gen_reward_info = function(reward_type, item_id, item_count)
			return {reward_type = reward_type, item_id = item_id, item_count = item_count}
		end,
	}
	env.REWARD_MGR = {
		reward_user = function(_, list) return list end,
		show_reward = function(_, list, show_type_list) shown = {list, show_type_list} end,
	}
	env.LOG = {_error = function(...) user.err = {...} end}
	env.for_maker = {}
	env.for_caller = {s2c_user_lottery = function(_, packet) sent = packet end}
	env.rand_item_by_weight = function(list)
		for _, row in ipairs(list) do
			if row[2] > 0 then
				return row[1]
			end
		end
	end
	assert(loadfile(FILE, "t", env))()
	env.__init__()
	return env, user, function() return shown, sent, events end
end

local T = {}

function T.single_draw_shows_window()
	local M, user, result = setup()
	M.for_maker.c2s_user_lottery(9, {useLotteryTimes = 1})
	local shown, sent = result()
	assert(user.paid)
	assert(user.checked[1].cost_type == 3 and user.checked[1].itemId == 103 and user.checked[1].count == 1)
	assert(user.times == 4)
	assert(shown[2][1] == 1, "普通弹窗")
	assert(shown[1][1].item_id == 1)
	assert(sent.useLotteryTimes == 1 and sent.lotteryTimes == 4)
	assert(sent.rewardList[1].rewardType == 1 and sent.rewardList[1].itemId == 1 and sent.rewardList[1].itemCount == 500)
end

function T.short_cost_sends_nothing()
	local M, user, result = setup({enough = false})
	M.for_maker.c2s_user_lottery(9, {useLotteryTimes = 1})
	local shown, sent = result()
	assert(not user.paid and user.times == 3 and not shown and not sent)
end

function T.discount_keeps_at_least_one()
	local M, user = setup({rate = 50})
	M.for_maker.c2s_user_lottery(9, {useLotteryTimes = 1})
	assert(user.checked[1].count == 1)
end

function T.ten_draw_uses_hero_pool_and_half_cost()
	local M, user, result = setup({
		id = 10,
		rate = 50,
		cost = {{item_id = 103, count = 10}},
		common = {{reward_type = 1, item_id = 1, item_count = 1, weight = 0}},
		hero = {{reward_type = 3, item_id = 1001, item_count = 1, weight = 9}},
	})
	M.for_maker.c2s_user_lottery(9, {useLotteryTimes = 10})
	local shown, sent = result()
	assert(user.checked[1].count == 5)
	assert(user.times == 13)
	assert(#shown[1] == 10 and shown[1][1].reward_type == 3 and shown[1][1].item_id == 1001)
	assert(sent.lotteryTimes == 13 and #sent.rewardList == 10 and sent.rewardList[1].rewardType == 3)
end

function T.converted_hero_keeps_draw_order()
	local M, _, result = setup({
		id = 2,
		cost = {{item_id = 103, count = 2}},
		common = {{reward_type = 3, item_id = 1001, item_count = 1, weight = 1}},
		hero = {},
	})
	local seen = false
	M.REWARD_MGR.reward_user = function(_, list)
		local out = {}
		for _, one in ipairs(list) do
			if one.reward_type == 3 and seen then
				out[#out + 1] = {reward_type = 1, item_id = 11001, item_count = 50}
			else
				if one.reward_type == 3 then
					seen = true
				end
				out[#out + 1] = one
			end
		end
		return out
	end
	M.for_maker.c2s_user_lottery(9, {useLotteryTimes = 2})
	local _, sent = result()
	assert(sent.rewardList[1].rewardType == 3 and sent.rewardList[1].itemId == 1001)
	assert(sent.rewardList[2].rewardType == 1 and sent.rewardList[2].itemId == 11001 and sent.rewardList[2].itemCount == 50)
end

return T
