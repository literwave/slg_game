all_user_build_tbl = {
--[[
	[userId] = {
		[bid] = build,
	}
]]
}

function ref_build(build)
	local user_id = build:get_user_id()
	local bid = build:get_bid()
	if not all_user_build_tbl[user_id] then
		all_user_build_tbl[user_id] = {}
	end
	all_user_build_tbl[user_id][bid] = build
end

function unref_build(build)
	local user_id = build:get_user_id()
	local bid = build:get_bid()
	if all_user_build_tbl[user_id] then
		all_user_build_tbl[user_id][bid] = nil
		if table.is_empty(all_user_build_tbl[user_id]) then
			all_user_build_tbl[user_id] = nil
		end
	end
end

local function create_build(oci)
	return BUILD_BASE.cls_build:New(oci)
end

local function try_init_user_builds(user_id)
	local doc, is_loaded = ORM.load(MONGO_SLAVE.COL.USER_BUILD, user_id, ORM.CLS_USER_BUILD_DOC)
	if is_loaded then
		all_user_build_tbl[user_id] = {}
		for _, build_data in pairs(doc._builds) do
			create_build(build_data)
		end
	end
	return all_user_build_tbl[user_id]
end

function get_build_by_bid(user_id, bid)
	local build_tbl = try_init_user_builds(user_id)
	if not build_tbl then
		return
	end
	return build_tbl[bid]
end

function get_user_build_tbl(user_id)
	return try_init_user_builds(user_id)
end

local function init_user_builds(user_id)
	local build_tbl = try_init_user_builds(user_id)
	if not build_tbl or next(build_tbl) then
		return
	end
	for _, info in ipairs(DATA_COMMON.get_initial_build_list()) do
		create_build({
			_user_id = user_id,
			_bid = info.bid,
			_level = info.level,
		})
		EVENT.dispatch(CONST.EVENT.ON_BUILD_LEVEL, user_id, info.bid, info.level)
	end
end

function on_user_login(user_id)
	-- 无建筑时补初始建筑（含首次创角中途失败、未 persist 的号）
	init_user_builds(user_id)
	sync_all_build_to_client(user_id)
end

function on_user_logout(user_id)
	if ORM.get(MONGO_SLAVE.COL.USER_BUILD, user_id) then
		MONGO_SLAVE.flush()
		all_user_build_tbl[user_id] = nil
		ORM.unbind(MONGO_SLAVE.COL.USER_BUILD, user_id)
	end
end

function sync_all_build_to_client(user_id)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	local build_tbl = try_init_user_builds(user_id)
	for _, build in pairs(build_tbl) do
		build:sync_to_client()
	end
end

local function on_req_build(fd)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local build_list = {}
	for _, build in pairs(try_init_user_builds(user_id) or {}) do
		build_list[#build_list + 1] = build:get_build_pto_info()
	end
	for_caller.s2c_req_build(fd, {buildList = build_list})
end

local function tell(user_id, msg)
	USER_MGR.tell_me(user_id, msg)
end

local function limit_met(user_id, limits)
	for _, limit in ipairs(limits or EMPTY_TABLE) do
		local need = get_build_by_bid(user_id, limit.bid)
		if not need or need:get_level() < limit.lev then
			return false
		end
	end
	return true
end

-- 粮木铁是道具 1、2、3。石料是资源栏 key 5。数量为 0 的不放进消耗列表
local function cost_list_of(conf)
	local list = {}
	local function add(count, item_id, cost_type)
		if count and count > 0 then
			list[#list + 1] = {
				cost_type = cost_type or CONST.COST_TYPE.ITEM,
				itemId = item_id,
				count = count,
			}
		end
	end
	add(conf.CostGrain, CONST.BUILD_COST_ITEM.GRAIN)
	add(conf.CostWood, CONST.BUILD_COST_ITEM.WOOD)
	add(conf.CostIron, CONST.BUILD_COST_ITEM.IRON)
	add(conf.CostStone, CONST.RES_TYPE_STONE, CONST.COST_TYPE.RES)
	return list
end

local function pay_level(user_id, conf)
	local list = cost_list_of(conf)
	if #list < 1 then
		return true
	end
	return ITEM_MGR.del_cost_list(user_id, list, {CONST.FLOW_REASON.BUILD, conf.Id})
end

local function on_create_build(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	local bid = packet.bid
	if not user_id or not bid then
		return
	end
	local detail = DATA_COMMON.get_build_detail(bid)
	if not detail then
		tell(user_id, "没有这个建筑")
		return
	end
	if get_build_by_bid(user_id, bid) then
		tell(user_id, "建筑已存在")
		return
	end
	if not limit_met(user_id, detail.CreateLimit) then
		tell(user_id, "前置建筑不足")
		return
	end
	local conf = DATA_COMMON.get_build_level_conf(bid, 1)
	if not conf or not pay_level(user_id, conf) then
		tell(user_id, "资源不足")
		return
	end
	local build = create_build({
		_user_id = user_id,
		_bid = bid,
		_level = 1,
	})
	build:sync_to_client()
	EVENT.dispatch(CONST.EVENT.ON_BUILD_LEVEL, user_id, bid, 1)
end

local function on_up_build(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	local bid = packet and packet.bid
	if not user_id or not bid then
		return
	end
	local build = get_build_by_bid(user_id, bid)
	if not build then
		tell(user_id, "没有这个建筑")
		return
	end
	local b_type = build:get_build_type()
	local next_lv = build:get_level() + 1
	if next_lv > DATA_COMMON.get_build_max_level(b_type) then
		tell(user_id, "已满级")
		return
	end
	local next_conf = DATA_COMMON.get_build_level_conf(b_type, next_lv)
	if not next_conf then
		tell(user_id, "已满级")
		return
	end
	if not limit_met(user_id, next_conf.UpgradeLimit) then
		tell(user_id, "前置建筑不足")
		return
	end
	if not pay_level(user_id, next_conf) then
		tell(user_id, "资源不足")
		return
	end
	build:set_level(next_lv)
	build:sync_to_client()
	EVENT.dispatch(CONST.EVENT.ON_BUILD_LEVEL, user_id, bid, next_lv)
end

function __init__()
	for_maker.c2s_req_build = on_req_build
	for_maker.c2s_create_build = on_create_build
	for_maker.c2s_up_build = on_up_build
	EVENT.listen(CONST.EVENT.ON_USER_LOGIN)
	EVENT.listen(CONST.EVENT.ON_USER_LOGOUT)
end
