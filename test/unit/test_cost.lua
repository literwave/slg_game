-- item/mgr.lua 的消耗逻辑：合并同类消耗、先整体校验再扣、扣到 0 的道具删除
-- 依赖都换成假的，只加载 mgr.lua 本身

local MGR_FILE = "logic/service/agent/module/item/mgr.lua"

local function setup()
	local env = setmetatable({}, {__index = _G})
	local user = {diamond = 100, res = {[1] = 50}, synced = 0, flow = {}}
	function user:get_diamond() return self.diamond end
	function user:sub_diamond_and_sync(c) self.diamond = self.diamond - c end
	function user:get_res_num(t) return self.res[t] or 0 end
	function user:add_res(t, n) self.res[t] = self:get_res_num(t) + n end
	function user:sync_res() self.synced = self.synced + 1 end

	local released = {}
	local item_cls = {}
	item_cls.__index = item_cls
	function item_cls:New(oci) return setmetatable({d = oci}, item_cls) end
	function item_cls:get_user_id() return self.d._user_id end
	function item_cls:get_item_id() return self.d._item_id end
	function item_cls:get_item_uid() return self.d._item_uid end
	function item_cls:get_item_kind() return 1 end
	function item_cls:get_cnt() return self.d._item_cnt end
	function item_cls:sub_cnt(c) self.d._item_cnt = self.d._item_cnt - c end
	function item_cls:sync_to_client() end
	function item_cls:release()
		released[#released + 1] = self:get_item_uid()
		env.unref_item(self)
	end

	env.EMPTY_TABLE = {}
	env.CONST = {
		COST_TYPE = {DIAMOND = 1, RES = 2, ITEM = 3},
		ITEM_KIND = {RES = 1, HERO_CHIP = 2, GIFT = 3, HERO_EQUIP = 4, RANDOM_REWARD = 5, SOLDIER = 6, VIP = 7},
		EVENT = {ON_ITEM_CHANGE = "on_item_change"},
	}
	user.events = {}
	env.EVENT = {dispatch = function(...) user.events[#user.events + 1] = {...} end}
	env.USER_MGR = {try_init_user = function() return user end}
	env.DATA_COMMON = {get_item_kind = function() return 1 end, can_overlap = function() return true end}
	env.ORM = {load = function() return {_items = {}}, false end, CLS_USER_ITEM_DOC = "x"}
	env.MONGO_SLAVE = {COL = {}}
	env.LOG = {_flow = function(...) user.flow[#user.flow + 1] = {...} end}
	env.CLS_BASE_ITEM = {cls_item = item_cls}
	env.CLS_HERO_EQUIP_ITEM = {cls_item = item_cls}
	assert(loadfile(MGR_FILE, "t", env))()

	local uid = 0
	local function seed(user_id, item_id, cnt)
		uid = uid + 1
		local it = item_cls:New({_user_id = user_id, _item_id = item_id, _item_uid = uid, _item_cnt = cnt})
		env.all_item_tbl[user_id] = env.all_item_tbl[user_id] or {}
		env.all_item_tbl[user_id][item_id] = env.all_item_tbl[user_id][item_id] or {}
		env.all_item_tbl[user_id][item_id][uid] = it
		env.all_item_uid_tbl[user_id] = env.all_item_uid_tbl[user_id] or {}
		env.all_item_uid_tbl[user_id][uid] = it
		env.all_item_kind_tbl[user_id] = env.all_item_kind_tbl[user_id] or {}
		env.all_item_kind_tbl[user_id][1] = env.all_item_kind_tbl[user_id][1] or {}
		env.all_item_kind_tbl[user_id][1][uid] = it
	end
	seed(1, 7, 3)
	seed(1, 7, 4)
	return env, user, released
end

local T = {}

function T.item_count_sums_stacks()
	local M = setup()
	assert(M.get_item_count(1, 7) == 7)
	assert(M.get_item_count(1, 8) == 0)
end

function T.duplicate_costs_merged()
	local M = setup()
	local c = {cost_type = 3, itemId = 7, count = 4}
	assert(not M.check_cost_enough(1, {c, c}), "4 + 4 > 7")
end

function T.nothing_deducted_when_short()
	local M, user = setup()
	assert(not M.del_cost_list(1, {{cost_type = 3, itemId = 7, count = 4}, {cost_type = 3, itemId = 7, count = 4}, {cost_type = 1, count = 10}}))
	assert(M.get_item_count(1, 7) == 7)
	assert(user.diamond == 100)
end

function T.mixed_costs_deducted()
	local M, user, released = setup()
	local reason = {6}
	assert(M.del_cost_list(1, {
		{cost_type = 3, itemId = 7, count = 5},
		{cost_type = 1, count = 10},
		{cost_type = 2, itemId = 1, count = 20},
	}, reason))
	assert(M.get_item_count(1, 7) == 2)
	assert(user.diamond == 90)
	assert(user.res[1] == 30 and user.synced == 1)
	assert(#released == 1, "stack that reaches 0 should be released")
	local item_flow
	for _, f in ipairs(user.flow) do
		if f[1] == "item" then
			item_flow = f
		end
	end
	assert(item_flow and item_flow[4] == -5 and item_flow[5] == 2 and item_flow[6] == reason, "item flow log")
	local ev = user.events[#user.events]
	assert(ev and ev[1] == "on_item_change" and ev[2] == 1 and ev[3] == 7, "item change event")
end

function T.all_item_data_lists_stacks()
	local M = setup()
	local sent
	M.for_maker = {}
	M.for_caller = {s2c_req_all_item_data = function(_, packet) sent = packet end}
	M.USER_MGR.get_user_id_by_fd = function(fd) return fd == 9 and 1 or nil end
	M.__init__()
	M.for_maker.c2s_req_all_item_data(9, {})
	assert(sent and #sent.itemList == 2)
	local cnt = 0
	for _, info in ipairs(sent.itemList) do
		assert(info.itemId == 7 and info.itemUid and info.itemCnt > 0)
		cnt = cnt + info.itemCnt
	end
	assert(cnt == 7)
	local protobuf = require "protobuf"
	protobuf.register_file("game_common/pb/item.pb")
	local back = protobuf.decode("Item.s2c_req_all_item_data", protobuf.encode("Item.s2c_req_all_item_data", sent))
	assert(#back.itemList == 2 and back.itemList[1].itemId == 7)
	sent = nil
	M.for_maker.c2s_req_all_item_data(0, {})
	assert(sent == nil)
end

function T.invalid_costs_rejected()
	local M = setup()
	assert(not M.check_cost_enough(1, {{cost_type = 9, count = 1}}))
	assert(not M.check_cost_enough(1, {{cost_type = 1, count = -5}}))
	assert(not M.check_cost_enough(1, {{cost_type = 1}}))
	assert(M.check_cost_enough(1, {}))
end

return T
