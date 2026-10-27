-- battle/fight/mgr.lua：用真实的 Hero / Monster / Skill 配置算，随机数可固定

local function load_conf(name)
	local ret = {}
	for _, row in pairs(dofile("game_common/server/res/" .. name .. ".lua")) do
		if type(row) == "table" and row.Id then
			ret[row.Id] = row
		end
	end
	return ret
end

local HERO = load_conf("Hero")
local MONSTER = load_conf("Monster")
local SKILL = load_conf("Skill")
local GROUP = load_conf("MonsterGroup")

local function load_const()
	local env = setmetatable({}, {__index = _G})
	assert(loadfile("logic/define/const.lua", "t", env))()
	return env
end

local function setup()
	local env = setmetatable({}, {__index = _G})
	env.EMPTY_TABLE = {}
	env.CONST = load_const()
	env.DATA_COMMON = {
		get_hero_info_by_type = function(id) return HERO[id] end,
		get_monster_conf = function(id) return MONSTER[id] end,
		get_skill_conf = function(id) return SKILL[id] end,
	}
	assert(loadfile("logic/service/battle/module/fight/mgr.lua", "t", env))()
	return env
end

-- 线性同余，结果可复现
local function seeded(seed)
	local s = seed
	return function(n)
		s = (s * 1103515245 + 12345) % 2147483648
		return s % n + 1
	end
end

local function always(v)
	return function(n)
		return math.min(v, n)
	end
end

local function hero_unit(pos, hero_type, soldier, lv)
	local skills = {}
	if HERO[hero_type].SkillId then
		skills[1] = {id = HERO[hero_type].SkillId, lv = 1}
	end
	return {pos = pos, kind = 1, cfg_id = hero_type, level = lv or 1, soldier = soldier, skills = skills}
end

local function group_side(group_id)
	local units = {}
	for _, m in ipairs(GROUP[group_id].Monsters) do
		units[#units + 1] = {pos = m.pos, kind = 2, cfg_id = m.mid, level = MONSTER[m.mid].Level, soldier = MONSTER[m.mid].Soldier}
	end
	return {owner_id = 0, name = GROUP[group_id].Name, units = units}
end

local function sum(left)
	local total = 0
	for _, v in pairs(left) do
		total = total + v
	end
	return total
end

local T = {}

function T.strong_troop_beats_weak_group()
	local M = setup()
	local atk = {owner_id = 1, units = {hero_unit(1, 1001, 500), hero_unit(2, 1010, 500)}}
	local res = M.fight(atk, group_side(1), seeded(7))
	assert(res.result == 1, "should win")
	assert(sum(res.def_left) == 0)
	assert(sum(res.atk_left) > 0 and sum(res.atk_left) <= 1000)
	assert(res.max_round >= 1 and res.max_round <= M.CONST.BATTLE_MAX_ROUND)
	assert(#res.actions > 0)
end

function T.tiny_troop_loses_to_boss()
	local M = setup()
	local atk = {owner_id = 1, units = {hero_unit(1, 1003, 20)}}
	local res = M.fight(atk, group_side(202), seeded(3))
	assert(res.result == 2, "should lose")
	assert(sum(res.def_left) > 0)
end

function T.draw_after_max_round_is_lose()
	local M = setup()
	-- 双方都没有攻击力：打满回合，算攻方输
	local atk = {owner_id = 1, units = {{pos = 1, kind = 2, cfg_id = 1, level = 1, soldier = 0}}}
	local res = M.fight(atk, group_side(1), seeded(1))
	assert(res.result == 2)
	assert(res.max_round == 0, "attacker with no soldier never starts")
end

function T.replay_effects_match_soldier()
	local M = setup()
	local atk = {owner_id = 1, units = {hero_unit(1, 1025, 600), hero_unit(2, 1023, 600)}}
	local def = group_side(5)
	local res = M.fight(atk, def, seeded(11))
	local remain = {[1] = {}, [2] = {}}
	for _, u in ipairs(atk.units) do
		remain[1][u.pos] = u.soldier
	end
	for _, u in ipairs(def.units) do
		remain[2][u.pos] = u.soldier
	end
	for _, act in ipairs(res.actions) do
		for _, eff in ipairs(act.effects) do
			local prev = remain[eff.target_side][eff.target_pos]
			if eff.after_soldier ~= prev then
				assert(prev - eff.value == eff.after_soldier, "damage value matches soldier drop")
			end
			assert(eff.after_soldier >= 0)
			remain[eff.target_side][eff.target_pos] = eff.after_soldier
		end
	end
	for pos, left in pairs(res.atk_left) do
		assert(remain[1][pos] == left, "atk pos " .. pos .. " replay mismatch")
	end
	for pos, left in pairs(res.def_left) do
		assert(remain[2][pos] == left, "def pos " .. pos .. " replay mismatch")
	end
end

function T.passive_buff_recorded_at_round_0()
	local M = setup()
	-- 1002 汉室余晖：被动，我军全体防御 +15%
	local atk = {owner_id = 1, units = {hero_unit(1, 1002, 300), hero_unit(2, 1001, 300)}}
	local res = M.fight(atk, group_side(1), seeded(5))
	local first = res.actions[1]
	assert(first.round == 0 and first.act_type == 3 and first.skill_id == 1002)
	assert(#first.effects == 2 and first.effects[1].value == 15)
end

function T.active_skill_fires_when_roll_hits()
	local M = setup()
	-- rand 总返回 1：概率必中、暴击必中
	local atk = {owner_id = 1, units = {hero_unit(1, 1023, 300)}}
	local res = M.fight(atk, group_side(1), always(1))
	local seen_active = false
	for _, act in ipairs(res.actions) do
		if act.act_type == 2 and act.skill_id == 1023 then
			seen_active = true
			assert(act.effects[1].flags & 1 == 1, "crit flag")
		end
	end
	assert(seen_active)
end

function T.batch_carries_defender_soldier()
	local M = setup()
	local weak = {owner_id = 1, units = {hero_unit(1, 1003, 60)}}
	local strong = {owner_id = 2, units = {hero_unit(1, 1001, 800), hero_unit(2, 1010, 800)}}
	local def = group_side(3)
	local list = M.fight_batch(def, {weak, strong, weak}, seeded(9))
	assert(#list == 3)
	assert(list[1].result == 2)
	assert(sum(list[1].def_left) < 400 + 180, "first attacker chipped the defender")
	assert(list[2].result == 1)
	assert(list[3].result == 1 and #list[3].actions == 0, "defender already gone")
	assert(def.units[1].soldier == MONSTER[4].Soldier, "input snapshot untouched")
end

return T
