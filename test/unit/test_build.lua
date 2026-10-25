-- 建造和升级：bid 是 BuildingDetail.Id，扣粮木铁石，前置看 UpgradeLimit / CreateLimit

local MGR_FILE = "logic/service/agent/module/build/mgr.lua"

local function setup()
	local env = setmetatable({}, {__index = _G})
	local tells = {}
	local syncs = {}
	local paid = {}
	local items = {[1] = 400, [2] = 400, [3] = 0, [5] = 0}
	local levels = {
		[1] = {
			[1] = {Id = 101, CostGrain = 0, CostWood = 0, CostIron = 0, CostStone = 0, UpgradeLimit = {}},
			[2] = {
				Id = 102,
				CostGrain = 400,
				CostWood = 400,
				CostIron = 0,
				CostStone = 0,
				UpgradeLimit = {{bid = 99, lev = 1}},
			},
		},
		[2] = {
			[1] = {Id = 201, CostGrain = 0, CostWood = 0, CostIron = 0, CostStone = 0, UpgradeLimit = {}},
		},
	}
	local details = {
		[1] = {Id = 1, InitLev = 1, CreateLimit = {}},
		[2] = {Id = 2, InitLev = 0, CreateLimit = {{bid = 1, lev = 2}}},
		[10] = {Id = 10, InitLev = 1, CreateLimit = {}},
	}
	env.EMPTY_TABLE = {}
	env.CONST = {
		COST_TYPE = {ITEM = 3},
		FLOW_REASON = {BUILD = 14},
		BUILD_COST_ITEM = {GRAIN = 1, WOOD = 2, IRON = 3, STONE = 5},
		EVENT = {ON_BUILD_LEVEL = "on_build_level", ON_USER_LOGIN = "login", ON_USER_LOGOUT = "logout"},
	}
	env.DATA_COMMON = {
		get_initial_build_list = function()
			return {{bid = 1, level = 1}, {bid = 10, level = 1}}
		end,
		get_build_detail = function(bid) return details[bid] end,
		get_build_type_by_id = function(bid) return details[bid] and details[bid].Id end,
		get_build_max_level = function() return 2 end,
		get_build_level_conf = function(b_type, lv)
			return levels[b_type] and levels[b_type][lv]
		end,
	}
	env.USER_MGR = {
		get_user_id_by_fd = function() return 1 end,
		get_fd_by_user_id = function() return 9 end,
		tell_me = function(_, msg) tells[#tells + 1] = msg end,
	}
	env.ITEM_MGR = {
		del_cost_list = function(_, list)
			for _, cost in ipairs(list) do
				if (items[cost.itemId] or 0) < cost.count then
					return false
				end
			end
			for _, cost in ipairs(list) do
				items[cost.itemId] = items[cost.itemId] - cost.count
				paid[#paid + 1] = cost
			end
			return true
		end,
	}
	env.EVENT = {listen = function() end, dispatch = function() end}
	local loaded = false
	env.ORM = {
		load = function()
			local first = not loaded
			loaded = true
			return {_builds = {}}, first
		end,
		get = function() return {_builds = {}} end,
		unbind = function() end,
	}
	env.MONGO_SLAVE = {COL = {USER_BUILD = "user_build"}, flush = function() end}
	env.for_maker = {}
	env.for_caller = {}
	env.BUILD_BASE = {
		cls_build = {
			New = function(_, oci)
				local build = {}
				function build:get_user_id() return oci._user_id end
				function build:get_bid() return oci._bid end
				function build:get_level() return oci._level end
				function build:set_level(level) oci._level = level end
				function build:get_build_type() return oci._bid end
				function build:get_build_pto_info()
					return {bid = oci._bid, level = oci._level}
				end
				function build:sync_to_client()
					syncs[#syncs + 1] = {bid = oci._bid, level = oci._level}
				end
				env.ref_build(build)
				return build
			end,
		},
	}
	assert(loadfile(MGR_FILE, "t", env))()
	env.__init__()
	env.on_user_login(1)
	return env, tells, syncs, items, paid
end

local T = {}

function T.req_returns_owned_buildings()
	local env = setup()
	local pack
	env.for_caller.s2c_req_build = function(_, msg)
		pack = msg
	end
	env.for_maker.c2s_req_build(9)
	local got = {}
	for _, info in ipairs(pack.buildList) do
		got[info.bid] = info.level
	end
	assert(got[1] == 1 and got[10] == 1)
	assert(got[2] == nil)
end

function T.login_gives_initial_buildings()
	local env = setup()
	assert(env.get_build_by_bid(1, 1):get_level() == 1)
	assert(env.get_build_by_bid(1, 10):get_level() == 1)
	assert(env.get_build_by_bid(1, 2) == nil)
end

function T.upgrade_needs_limit_then_pays()
	local env, tells, syncs, items, paid = setup()
	env.for_maker.c2s_up_build(9, {bid = 1})
	assert(tells[#tells] == "前置建筑不足")
	assert(env.get_build_by_bid(1, 1):get_level() == 1)
	assert(#paid == 0)

	env.DATA_COMMON.get_build_level_conf = function(_, lv)
		if lv ~= 2 then
			return {Id = 101, UpgradeLimit = {}}
		end
		return {Id = 102, CostGrain = 400, CostWood = 400, CostIron = 0, CostStone = 0, UpgradeLimit = {}}
	end
	env.for_maker.c2s_up_build(9, {bid = 1})
	assert(env.get_build_by_bid(1, 1):get_level() == 2)
	assert(items[1] == 0 and items[2] == 0)
	assert(syncs[#syncs].bid == 1 and syncs[#syncs].level == 2)
end

function T.upgrade_stops_when_short()
	local env, tells, _, items = setup()
	items[1] = 10
	env.DATA_COMMON.get_build_level_conf = function()
		return {Id = 102, CostGrain = 400, CostWood = 0, CostIron = 0, CostStone = 0, UpgradeLimit = {}}
	end
	env.for_maker.c2s_up_build(9, {bid = 1})
	assert(tells[#tells] == "资源不足")
	assert(env.get_build_by_bid(1, 1):get_level() == 1)
	assert(items[1] == 10)
end

function T.create_checks_limit_and_syncs()
	local env, tells, syncs = setup()
	env.for_maker.c2s_create_build(9, {bid = 2})
	assert(tells[#tells] == "前置建筑不足")
	assert(env.get_build_by_bid(1, 2) == nil)

	env.get_build_by_bid(1, 1):set_level(2)
	env.for_maker.c2s_create_build(9, {bid = 2})
	assert(env.get_build_by_bid(1, 2):get_level() == 1)
	assert(syncs[#syncs].bid == 2 and syncs[#syncs].level == 1)
end

return T
