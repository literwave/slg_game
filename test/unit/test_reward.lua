-- 已拥有的武将奖励按 Hero.Convert 换成碎片

local MGR_FILE = "logic/service/agent/module/reward/mgr.lua"

if not table.deepcopy then
	function table.deepcopy(t)
		local copy = {}
		for k, v in pairs(t) do
			copy[k] = v
		end
		return copy
	end
end

local function setup(owned)
	local env = setmetatable({}, {__index = _G})
	local heroes = {}
	for hero_id in pairs(owned or {}) do
		heroes[hero_id] = true
	end
	local items = {}
	env.CONST = {
		REWARD_TYPE_ITEM = 1,
		REWARD_TYPE_RES = 2,
		REWARD_TYPE_HERO = 3,
		REWARD_TYPE_SOLDIER = 4,
		EVENT = {ON_CALC_ITEM_REWARD = "on_calc_item_reward"},
	}
	env.EVENT = {dispatch = function() end}
	env.GLOBAL_FUNC = {
		gen_reward_info = function(reward_type, item_id, item_count)
			return {reward_type = reward_type, item_id = item_id, item_count = item_count}
		end,
	}
	env.DATA_COMMON = {
		get_hero_info_by_type = function(hero_id)
			if hero_id ~= 1001 then
				return nil
			end
			return {Convert = {{reward_type = 1, item_id = 11001, item_count = 50}}}
		end,
	}
	env.HERO_MGR = {
		get_hero_by_type = function(_, hero_id) return heroes[hero_id] end,
		add_hero = function(_, hero_id)
			heroes[hero_id] = true
			return true
		end,
	}
	env.ITEM_MGR = {
		get_item_max_add_cnt = function() return nil end,
		add_item = function(_, item_id, cnt)
			items[item_id] = (items[item_id] or 0) + cnt
		end,
	}
	assert(loadfile(MGR_FILE, "t", env))()
	return env, heroes, items
end

local T = {}

function T.new_hero_is_granted()
	local M, heroes, items = setup()
	local got = M.reward_user(1, {{reward_type = 3, item_id = 1001, item_count = 1}}, {})
	assert(heroes[1001])
	assert(not items[11001])
	assert(#got == 1 and got[1].reward_type == 3 and got[1].item_id == 1001)
end

function T.owned_hero_becomes_fragments()
	local M, heroes, items = setup({[1001] = true})
	local got = M.reward_user(1, {{reward_type = 3, item_id = 1001, item_count = 1}}, {})
	assert(heroes[1001])
	assert(items[11001] == 50)
	assert(#got == 1 and got[1].reward_type == 1 and got[1].item_id == 11001 and got[1].item_count == 50)
end

function T.same_batch_second_copy_converts()
	local M, _, items = setup()
	local got = M.reward_user(1, {
		{reward_type = 3, item_id = 1001, item_count = 1},
		{reward_type = 3, item_id = 1001, item_count = 1},
	}, {})
	assert(items[11001] == 50)
	assert(got[1].reward_type == 3 and got[2].item_id == 11001)
end

function T.mixed_types_keep_input_order()
	local M = setup()
	local got = M.reward_user(1, {
		{reward_type = 1, item_id = 1, item_count = 10},
		{reward_type = 3, item_id = 1001, item_count = 1},
		{reward_type = 1, item_id = 2, item_count = 20},
	}, {})
	assert(got[1].reward_type == 1 and got[1].item_id == 1 and got[1].item_count == 10)
	assert(got[2].reward_type == 3 and got[2].item_id == 1001)
	assert(got[3].reward_type == 1 and got[3].item_id == 2 and got[3].item_count == 20)
end

return T
