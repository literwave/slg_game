local function add_res_and_sync(user_id, res_type, cnt, reason_list)
	local user = USER_MGR.try_init_user(user_id)
	user:add_res(res_type, cnt, reason_list)
	user:sync_res({res_type})
end

local function reward_item(ret, user_id, reward_info_list, reason_list)
	local over_limit_item_tbl = {}
	for _, reward_info in ipairs(reward_info_list) do
		local item_id = reward_info.item_id
		local item_count = reward_info.item_count
		local item_max_add_cnt = ITEM_MGR.get_item_max_add_cnt(item_id)
		if item_max_add_cnt and item_count > item_max_add_cnt then
			over_limit_item_tbl[item_id] = (over_limit_item_tbl[item_id] or 0) + item_count - item_max_add_cnt
			reward_info.item_count = item_max_add_cnt
		end
		local new_item_count = reward_info.item_count
		if new_item_count > 0 then
			ITEM_MGR.add_item(user_id, item_id, new_item_count, reason_list)
			table.insert(ret, GLOBAL_FUNC.gen_reward_info(reward_info.reward_type, item_id, new_item_count))
		end
	end
	-- 超过单次可加上限的部分走补发邮件
	local reissue_list = {}
	for item_id, cnt in pairs(over_limit_item_tbl) do
		table.insert(reissue_list, GLOBAL_FUNC.gen_reward_info(CONST.REWARD_TYPE_ITEM, item_id, cnt))
	end
	if #reissue_list > 0 then
		MAIL.send_user_mail(user_id, CONST.MAIL_ID.REWARD_REISSUE, nil, reissue_list)
	end
end

local function reward_resource(ret, user_id, reward_info_list, reason_list)
	for _, reward_info in pairs(reward_info_list) do
		local res_type = reward_info.item_id
		local cnt = reward_info.item_count
		add_res_and_sync(user_id, res_type, cnt, reason_list)
		table.insert(ret, reward_info)
	end
end

local function reward_hero(ret, user_id, reward_info_list, reason_list)
	for _, reward_info in pairs(reward_info_list) do
		local hero_type = reward_info.item_id
		HERO_MGR.add_hero(user_id, hero_type, reason_list)
		table.insert(ret, reward_info)
	end
end

local function reward_soldier(ret, user_id, reward_info_list, reason_list)
	local user = USER_MGR.try_init_user(user_id)
	for _, reward_info in pairs(reward_info_list) do
		local cnt = user:add_soldier(reward_info.item_count or 0)
		if cnt > 0 then
			LOG._flow("soldier", user_id, 0, cnt, user:get_soldier_cnt(), reason_list)
			table.insert(ret, GLOBAL_FUNC.gen_reward_info(reward_info.reward_type, 0, cnt))
		end
	end
	user:sync_soldier()
end

local GIVE_REWARD_FUNC = {
	[CONST.REWARD_TYPE_ITEM] = reward_item,
	[CONST.REWARD_TYPE_RES] = reward_resource,
	[CONST.REWARD_TYPE_HERO] = reward_hero,
	[CONST.REWARD_TYPE_SOLDIER] = reward_soldier,
}

local function give_reward(ret, user_id, reward_type, reward_info_list, reason_list)
	local give_reward_func = GIVE_REWARD_FUNC[reward_type]
	assert(give_reward_func, "invalid reward_type!")
	return give_reward_func(ret, user_id, reward_info_list, reason_list)
end

function reward_user(user_id, reward_list, reason_list)
	local reward_tbl = {}
	for _, reward_info in pairs(reward_list) do
		local reward_type = reward_info.reward_type
		if not reward_tbl[reward_type] then
			reward_tbl[reward_type] = {}
		end
		local info = table.deepcopy(reward_info)
		if (reward_type == CONST.REWARD_TYPE_ITEM or reward_type == CONST.REWARD_TYPE_RES) and info.item_count > 0 then
			local ctx = {item_id = info.item_id, rate = 1}
			EVENT.dispatch(CONST.EVENT.ON_CALC_ITEM_REWARD, user_id, ctx)
			info.item_count = math.floor(info.item_count * ctx.rate)
		end
		table.insert(reward_tbl[reward_type], info)
	end
	local actual_rwd_list = {}
	for reward_type, reward_info_list in pairs(reward_tbl) do
		give_reward(actual_rwd_list, user_id, reward_type, reward_info_list, reason_list)
	end
	return actual_rwd_list
end

function show_reward(user_id, reward_list, show_type_list)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	if not show_type_list then
		show_type_list = {}
	end
	local list = {}
	for _, info in ipairs(reward_list) do
		table.insert(list, {
			rewardType = info.rewardType or info.reward_type,
			itemId = info.itemId or info.item_id,
			itemCount = info.itemCount or info.item_count,
		})
	end
	for_caller.s2c_show_reward(fd, {
		rewardList = list,
		showTypeList = show_type_list,
	})
end

function reward_user_and_show(user_id, reward_list, reason_list, show_type_list)
	local actual_rwd_list = reward_user(user_id, reward_list, reason_list)
	show_reward(user_id, actual_rwd_list, show_type_list)
end
