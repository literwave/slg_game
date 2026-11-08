-- 用真实 master 导表检查加载入口、枚举、公开查询和首占奖励。
local T = {}
local indexed = require("config_table").index_by_id

local function data_env()
	local tables = {}
	local share = {query = function(name)
		if not tables[name] then
			local dir = name:match("Enum$") and "enum" or "res"
			local path = name == "innerCity" and "res/innerCity.lua" or "game_common/server/" .. dir .. "/" .. name .. ".lua"
			tables[name] = indexed(dofile(path))
		end
		return tables[name]
	end}
	local env = setmetatable({require = function(n) assert(n == "skynet.sharedata"); return share end}, {__index = _G})
	assert(loadfile("logic/define/data.lua", "t", env))()
	env.__init__()
	return env
end

function T.generated_enums_and_new_tables_load()
	local D = data_env()
	assert(D.TARGET_TYPE.MOVE == 4 and D.RES_LAND_TYPE.STONE == 4)
	assert(D.RANK_TYPE.KILL == 3 and D.RANK_TYPE.ALLIANCE_POWER == 4)
	assert(D.get_rank_max(4) == 50 and D.get_rank_max(1) == 100)
	assert(D.get_res_land_first_conf(4, 1).Reward[1].item_count > 0)
	assert(D.get_item_conf(4).Kind == 4 and D.get_item_conf(11050).Kind == 8)
	assert(D.get_hero_info_by_type(1050) and D.get_skill_conf(1050))
	assert(D.get_head_icon_info(1050).HeroId == 1050 and not D.get_head_icon_info(1051))
	assert(D.get_chat_channel_conf(1) and not D.get_chat_channel_conf(999))
	assert(D.get_alliance_join_type_conf(1) and D.get_mail_kind_conf(1))
	assert(HEAD_ICON == 1 and CREATE_ALLIANCE == 2)
end

function T.loader_references_only_existing_tables()
	local cache = {}
	local sky = {cache={mode=function()end},start=function(fn)fn()end,dispatch=function()end,register=function()end}
	local env = setmetatable({
		require=function(n) if n=="skynet" then return sky elseif n=="skynet.manager" then return {} elseif n=="config_table" then return require(n) end
			return {new=function(n,t)cache[n]=t end} end,
		loadfile=function(p) return loadfile((p:gsub("^%.%./", ""))) end,
		LOG={_debug=function()end},
	}, {__index=_G})
	assert(loadfile("logic/service/load_xls/load_xls.lua", "t", env))()
	assert(cache.EntityTypeEnum.TROOP == 2 and cache.Rank[4].RankMax == 50)
	assert(cache.ResLandFirst and not cache.EntityType)
end

local function user_env()
	local rows = {user={_user_id=123,_name="公开名",_head_icon=1001,_sex=1,_level=7,_offline_time=999,_real_diamond=888},
		hero={_heroes={["1001"]={_hero_type=1001,_level=2}}},build={_builds={["1"]={_level=8}}}}
	local env = setmetatable({require=function()return {} end,
		MONGO_SLAVE={COL={USER_INFO="user",USER_HERO="hero",USER_BUILD="build"},common_load_single=function(col,id)if id==123 then return rows[col] end end},
		DATA_COMMON={get_hero_info_by_type=function()return {Attack=10,Hp=20,Defense=30,Speed=40,Crit=50}end,get_main_city_bid=function()return 1 end},
	}, {__index=_G})
	assert(loadfile("logic/service/agent/module/user/mgr.lua", "t", env))()
	return env
end

function T.public_profile_offline_does_not_create_user_or_leak_private_fields()
	local U = user_env()
	local p = U.get_public_profile(123)
	assert(p.uid==123 and p.name=="公开名" and p.power==300 and p.cityLevel==8 and p.offlineTime==999)
	assert(not next(U.all_user_tbl), "只读查询不创建幽灵玩家")
	assert(p._real_diamond==nil and p.soldierInfo==nil and p.exp==nil)
	assert(U.get_public_profile(999)==nil)
end

function T.first_occupy_reward_is_once_per_type_and_level()
	local sent = 0
	local info = {owner_id=7,cfg_id=401}
	local env = setmetatable({require=function()return {localname=function()return ".world"end,call=function()return info end}end,
		DATA_COMMON={get_res_land_conf=function()return {Type=4,Level=1}end,get_res_land_first_conf=function()return {Reward={{item_id=4,item_count=100}}}end},
		TIME={os_bj_sec=function()return 100 end}, CONST={FLOW_REASON={BATTLE=10},REWARD_SHOW_TYPE={NONE=0}},
		REWARD_MGR={reward_user_and_show=function(_, _, _, show_types)
			assert(show_types and #show_types==1 and show_types[1]==0, "首占自动结算不弹窗")
			sent=sent+1
		end}}, {__index=_G})
	assert(loadfile("logic/service/agent/module/march/mgr.lua", "t", env))()
	local user={_data={_land_first={}},get_user_id=function()return 7 end}
	env.reward_first_occupy(user,99); env.reward_first_occupy(user,99)
	assert(sent==1 and user._data._land_first[4001]==100)
	info.owner_id=8;env.reward_first_occupy(user,99);assert(sent==1)
end

function T.starting_resources_are_items_and_can_be_spent_after_reload()
	local D = data_env()
	local C = setmetatable({}, {__index = _G})
	assert(loadfile("logic/define/const.lua", "t", C))()
	local doc, loaded, next_uid = {_items = {}}, false, 0
	local cls = {}
	function cls:New(row)
		doc._items[row._item_uid] = row
		return {
			get_user_id = function() return row._user_id end,
			get_item_id = function() return row._item_id end,
			get_item_uid = function() return row._item_uid end,
			get_item_kind = function() return D.get_item_kind(row._item_id) end,
			get_cnt = function() return row._item_cnt end,
			add_cnt = function(_, n) row._item_cnt = row._item_cnt + n end,
			sub_cnt = function(_, n) row._item_cnt = row._item_cnt - n end,
			after_generate = function() end,
			sync_to_client = function() end,
		}
	end
	local env = setmetatable({
		CONST = C, DATA_COMMON = D, EMPTY_TABLE = {},
		ORM = {CLS_USER_ITEM_DOC = "items", load = function()
			local first = not loaded; loaded = true; return doc, first
		end},
		MONGO_SLAVE = {COL = {USER_ITEM = "items"}},
		CLS_BASE_ITEM = {cls_item = cls},
		get_id_by_user_id_and_timestamp = function() next_uid = next_uid + 1; return next_uid end,
		LOG = {_flow = function() end}, EVENT = {dispatch = function() end},
		GLOBAL_FUNC = {gen_reward_info = function(kind, id, count)
			return {reward_type = kind, item_id = id, item_count = count}
		end},
		table = setmetatable({deepcopy = function(t)
			local copy = {}; for k, v in pairs(t) do copy[k] = v end; return copy
		end}, {__index = table}),
	}, {__index = _G})
	local item_file = "logic/service/agent/module/item/mgr.lua"
	assert(loadfile(item_file, "t", env))()
	env.ITEM_MGR = env
	assert(loadfile("logic/service/agent/module/reward/mgr.lua", "t", env))()
	local rewards, expected = {}, {}
	for _, reward in ipairs(D.get_value_by_key(1)) do
		if reward.item_id and reward.item_id >= 1 and reward.item_id <= 4 then
			assert(reward.reward_type == C.REWARD_TYPE_ITEM)
			rewards[#rewards + 1] = reward
			expected[reward.item_id] = reward.item_count
		end
	end
	assert(#rewards == 4 and expected[C.BUILD_COST_ITEM.STONE] > 0)
	env.reward_user(7, rewards, {})
	-- 重新装载已保存的道具文档，初始资源不依赖登录时转账或补发。
	loaded = false
	assert(loadfile(item_file, "t", env))()
	local costs = {}
	for id = 1, 4 do
		assert(env.get_item_count(7, id) == expected[id])
		costs[#costs + 1] = {cost_type = C.COST_TYPE.ITEM, itemId = id, count = 1}
	end
	assert(env.del_cost_list(7, costs, {}))
	for id = 1, 4 do assert(env.get_item_count(7, id) == expected[id] - 1) end
	assert(env.get_item_count(7, 5) == 0)
end

return T
