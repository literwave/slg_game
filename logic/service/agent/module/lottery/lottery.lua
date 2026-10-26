local function on_req_user_lottery_info(fd)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	for_caller.s2c_req_user_lottery_info(fd, {lotteryTimes = user:get_lottery_times()})
end

local function draw(pool)
	local weight_list = {}
	for _, entry in ipairs(pool or EMPTY_TABLE) do
		table.insert(weight_list, {entry, entry.weight or 0})
	end
	return rand_item_by_weight(weight_list)
end

local function pool_weight(pool)
	local sum = 0
	for _, entry in ipairs(pool or EMPTY_TABLE) do
		sum = sum + (entry.weight or 0)
	end
	return sum
end

-- 两个池先按权重总和决定进哪个池，再在池内抽一条
local function draw_once(conf)
	local common_weight = pool_weight(conf.CommonPools)
	local hero_weight = pool_weight(conf.HeroPools)
	local pool = conf.CommonPools
	if hero_weight > 0 and (common_weight <= 0 or math.random(common_weight + hero_weight) > common_weight) then
		pool = conf.HeroPools
	end
	return draw(pool)
end

-- Lottery.CostList 是 {item_id, count}，扣费接口要 cost_type 和 itemId
local function item_cost_list(cost_list, rate)
	local list = {}
	for _, cost in ipairs(cost_list or EMPTY_TABLE) do
		local count = cost.count or 0
		if rate < 100 then
			count = math.floor(count * rate / 100)
			if count < 1 then
				count = 1
			end
		end
		list[#list + 1] = {
			cost_type = CONST.COST_TYPE.ITEM,
			itemId = cost.item_id,
			count = count,
		}
	end
	return list
end

-- 先把每一发都抽完、确认奖池可用，再扣消耗；中途失败不会白扣
local function on_user_lottery(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local use_lottery_times = packet.useLotteryTimes
	local conf = DATA_COMMON.get_lottery_conf(use_lottery_times)
	if not conf or not conf.CostList then
		return
	end
	local user_id = user:get_user_id()
	local ctx = {lottery_id = use_lottery_times, rate = 100}
	EVENT.dispatch(CONST.EVENT.ON_CALC_LOTTERY_COST, user_id, ctx)
	local cost_list = item_cost_list(conf.CostList, ctx.rate)
	if not ITEM_MGR.check_cost_enough(user_id, cost_list) then
		return
	end
	local lottery_times = user:get_lottery_times()
	local reward_list = {}
	for _ = 1, use_lottery_times do
		local entry = draw_once(conf)
		if not entry then
			LOG._error("lottery pool empty: %s", use_lottery_times)
			return
		end
		reward_list[#reward_list + 1] = GLOBAL_FUNC.gen_reward_info(entry.reward_type, entry.item_id, entry.item_count)
	end
	local reason_list = {CONST.FLOW_REASON.LOTTERY, use_lottery_times}
	assert(ITEM_MGR.del_cost_list(user_id, cost_list, reason_list))
	lottery_times = lottery_times + use_lottery_times
	user:set_lottery_times(lottery_times)
	local actual_list = REWARD_MGR.reward_user(user_id, reward_list, reason_list)
	local reward_pto_list = {}
	for _, info in ipairs(actual_list) do
		reward_pto_list[#reward_pto_list + 1] = {
			rewardType = info.reward_type,
			itemId = info.item_id,
			itemCount = info.item_count,
		}
	end
	for_caller.s2c_user_lottery(fd, {
		useLotteryTimes = use_lottery_times,
		lotteryTimes = lottery_times,
		rewardList = reward_pto_list,
	})
	EVENT.dispatch(CONST.EVENT.ON_LOTTERY, user_id, use_lottery_times)
end

function __init__()
	for_maker.c2s_req_user_lottery_info = on_req_user_lottery_info
	for_maker.c2s_user_lottery = on_user_lottery
end
