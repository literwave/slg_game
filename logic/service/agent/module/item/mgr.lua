all_item_tbl = {
--[[
	[userId] = {
		[itemId] = {
			[itemUid] = item,
		},
	},
--]]
}

all_item_uid_tbl = {
--[[
	[userId] = {
		[itemUid] = item,
	}
--]]
}

all_item_kind_tbl = {
--[[
	[userId] = {
		[itemKind] = {
			[itemUid] = item,
		},
	}
--]]
}

local function ref_item(item)
	local user_id = item:get_user_id()
	local item_id = item:get_item_id()
	local item_uid = item:get_item_uid()
	local item_kind = item:get_item_kind()
	if not all_item_tbl[user_id] then
		all_item_tbl[user_id] = {}
	end
	if not all_item_tbl[user_id][item_id] then
		all_item_tbl[user_id][item_id] = {}
	end
	all_item_tbl[user_id][item_id][item_uid] = item
	if not all_item_uid_tbl[user_id] then
		all_item_uid_tbl[user_id] = {}
	end
	all_item_uid_tbl[user_id][item_uid] = item
	if not all_item_kind_tbl[user_id] then
		all_item_kind_tbl[user_id] = {}
	end
	if not all_item_kind_tbl[user_id][item_kind] then
		all_item_kind_tbl[user_id][item_kind] = {}
	end
	all_item_kind_tbl[user_id][item_kind][item_uid] = item
end

function get_item_max_add_cnt(item_id)
	return DATA_COMMON.get_item_overlap(item_id)
end

local ITEM_KIND_TO_MOD = {
	[CONST.ITEM_KIND.HERO_EQUIP] = CLS_HERO_EQUIP_ITEM,
}

local function create_item(oci)
	local item_id = oci._item_id
	assert(item_id)
	local kind = DATA_COMMON.get_item_kind(item_id)
	local mod = ITEM_KIND_TO_MOD[kind] or CLS_BASE_ITEM
	local item = mod.cls_item:New(oci)
	ref_item(item)
	return item
end

function unref_item(item)
	local user_id = item:get_user_id()
	local item_id = item:get_item_id()
	local item_uid = item:get_item_uid()
	local item_kind = item:get_item_kind()
	if all_item_tbl[user_id] and all_item_tbl[user_id][item_id] then
		all_item_tbl[user_id][item_id][item_uid] = nil
	end
	if all_item_uid_tbl[user_id] then
		all_item_uid_tbl[user_id][item_uid] = nil
	end
	if all_item_kind_tbl[user_id] and all_item_kind_tbl[user_id][item_kind] then
		all_item_kind_tbl[user_id][item_kind][item_uid] = nil
	end
end

local function try_init_user_data(user_id)
	local doc, is_loaded = ORM.load(MONGO_SLAVE.COL.USER_ITEM, user_id, ORM.CLS_USER_ITEM_DOC)
	if is_loaded then
		all_item_uid_tbl[user_id] = {}
		for _, item_data in pairs(doc._items) do
			create_item(item_data)
		end
	end
	return all_item_uid_tbl[user_id]
end

local function generate_item(user_id, item_id, cnt)
	local item_uid = get_id_by_user_id_and_timestamp(user_id)
	local oci = {
		_item_uid = item_uid,
		_item_id = item_id,
		_user_id = user_id,
		_item_cnt = cnt or 1,
	}
	try_init_user_data(user_id)
	local item = create_item(oci)
	item:after_generate()
	return item
end


local function do_add_item_cnt(user_id, item_id, cnt, need_sync, reason_list, new_item_list)
	assert(cnt > 0)
	try_init_user_data(user_id)
	local user_item_tbl = all_item_tbl[user_id] or {}
	local item_tbl = user_item_tbl[item_id] or {}
	if DATA_COMMON.can_overlap(item_id) then
		local _, item = next(item_tbl)
		if not item then
			item = generate_item(user_id, item_id, cnt)
		else
			item:add_cnt(cnt)
		end
		if need_sync then
			item:sync_to_client()
		end
	else
		assert(cnt < 10000000)
		for _ = 1, cnt do
			local item = generate_item(user_id, item_id)
			if need_sync then
				item:sync_to_client()
			end
			if new_item_list then
				table.insert(new_item_list, item)
			end
		end
	end
	LOG._flow("item", user_id, item_id, cnt, get_item_count(user_id, item_id), reason_list)
	EVENT.dispatch(CONST.EVENT.ON_ITEM_CHANGE, user_id, item_id)
end

function add_item_cnt(user_id, item_id, cnt, reason_list)
	do_add_item_cnt(user_id, item_id, cnt, true, reason_list)
end

function add_item_cnt_no_sync(user_id, item_id, cnt, reason_list, new_item_list)
	return do_add_item_cnt(user_id, item_id, cnt, false, reason_list, new_item_list)
end

local function reward_resource_base(user_id, item_id, cnt, reason_list)
	add_item_cnt(user_id, item_id, cnt, reason_list)
end

local ITEM_KIND_REWARD_FUNC = {
	[CONST.ITEM_KIND.RES] = reward_resource_base,
	[CONST.ITEM_KIND.HERO_CHIP] = reward_resource_base,
	[CONST.ITEM_KIND.HERO_EQUIP] = reward_resource_base,
	[CONST.ITEM_KIND.RANDOM_REWARD] = reward_resource_base,
	[CONST.ITEM_KIND.SOLDIER] = reward_resource_base,
	[CONST.ITEM_KIND.VIP] = reward_resource_base,
}

function add_item(user_id, item_id, cnt, reason_list)
	local item_kind = DATA_COMMON.get_item_kind(item_id)
	local func = ITEM_KIND_REWARD_FUNC[item_kind]
	if func then
		func(user_id, item_id, cnt, reason_list)
	else
		add_item_cnt(user_id, item_id, cnt, reason_list)
	end
	if item_kind == CONST.SKILL_BOOK_KIND and SKILL_MGR then
		SKILL_MGR.on_item_add(user_id, item_id)
	end
end

function get_item_count(user_id, item_id)
	try_init_user_data(user_id)
	local cnt = 0
	for _, item in pairs((all_item_tbl[user_id] or EMPTY_TABLE)[item_id] or EMPTY_TABLE) do
		cnt = cnt + item:get_cnt()
	end
	return cnt
end

-- 调用方先确认数量足够。扣到 0 的道具同步 cnt=0 给客户端后删除
local function sub_item_cnt(user_id, item_id, cnt, reason_list)
	local sub_cnt = cnt
	local item_list = {}
	for _, item in pairs(all_item_tbl[user_id][item_id]) do
		table.insert(item_list, item)
	end
	for _, item in ipairs(item_list) do
		if cnt <= 0 then
			break
		end
		local sub = math.min(cnt, item:get_cnt())
		item:sub_cnt(sub)
		cnt = cnt - sub
		item:sync_to_client()
		if item:get_cnt() == 0 then
			item:release()
		end
	end
	assert(cnt == 0)
	LOG._flow("item", user_id, item_id, -sub_cnt, get_item_count(user_id, item_id), reason_list)
	EVENT.dispatch(CONST.EVENT.ON_ITEM_CHANGE, user_id, item_id)
end

-- cost_info: {cost_type, count, itemId}；itemId 对道具是道具 id，对资源是资源类型
local COST_FUNC = {
	[CONST.COST_TYPE.DIAMOND] = {
		has = function(user_id)
			return USER_MGR.try_init_user(user_id):get_diamond()
		end,
		sub = function(user_id, _, count, reason_list)
			USER_MGR.try_init_user(user_id):sub_diamond_and_sync(count, reason_list)
		end,
	},
	[CONST.COST_TYPE.RES] = {
		has = function(user_id, res_type)
			return USER_MGR.try_init_user(user_id):get_res_num(res_type)
		end,
		sub = function(user_id, res_type, count, reason_list)
			local user = USER_MGR.try_init_user(user_id)
			user:add_res(res_type, -count, reason_list)
			user:sync_res({res_type})
		end,
	},
	[CONST.COST_TYPE.ITEM] = {
		has = get_item_count,
		sub = sub_item_cnt,
	},
}

-- 同一种消耗配了多条时先合并，否则每条单独看都够、合起来却不够
local function merge_cost_list(cost_list)
	local merged = {}
	for _, cost_info in ipairs(cost_list) do
		if not COST_FUNC[cost_info.cost_type] or not cost_info.count or cost_info.count <= 0 then
			return
		end
		local id = cost_info.itemId or 0
		local key = cost_info.cost_type .. ":" .. id
		if not merged[key] then
			merged[key] = {cost_type = cost_info.cost_type, id = id, count = 0}
		end
		merged[key].count = merged[key].count + cost_info.count
	end
	return merged
end

function check_cost_enough(user_id, cost_list)
	local merged = merge_cost_list(cost_list)
	if not merged then
		return false
	end
	for _, cost in pairs(merged) do
		if COST_FUNC[cost.cost_type].has(user_id, cost.id) < cost.count then
			return false
		end
	end
	return true
end

local function item_pto(item)
	return {
		itemUid = item:get_item_uid(),
		itemId = item:get_item_id(),
		itemCnt = item:get_cnt(),
	}
end

local function on_req_all_item_data(fd)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local item_list = {}
	for _, item in pairs(try_init_user_data(user_id) or EMPTY_TABLE) do
		local info = item_pto(item)
		if info.itemCnt > 0 then
			item_list[#item_list + 1] = info
		end
	end
	for_caller.s2c_req_all_item_data(fd, {itemList = item_list})
end

function __init__()
	for_maker.c2s_req_all_item_data = on_req_all_item_data
end

-- 先整体校验再扣，不够就一样都不扣
function del_cost_list(user_id, cost_list, reason_list)
	if not check_cost_enough(user_id, cost_list) then
		return false
	end
	for _, cost in pairs(merge_cost_list(cost_list)) do
		COST_FUNC[cost.cost_type].sub(user_id, cost.id, cost.count, reason_list)
	end
	return true
end