-- 战斗结算：只吃双方快照，不读玩家数据、不改地图；输出胜负、双方剩余兵力和回放
-- 快照 side = {owner_id, name, power, units = {{pos, kind, cfg_id, level, soldier, skills = {{id, lv}}}}}
--   kind 见 CONST.BATTLE_UNIT，soldier 是能上场的兵（不含伤兵）
-- rand(n) 返回 1..n，由调用方传入，测试里可以固定

local BUFF_ATTR = {
	[CONST.SKILL_EFFECT.ATTACK] = "attack",
	[CONST.SKILL_EFFECT.DEFENSE] = "defense",
	[CONST.SKILL_EFFECT.INTEL] = "intel",
	[CONST.SKILL_EFFECT.SPEED] = "speed",
}

local TRIGGER_ACT = {
	[CONST.SKILL_TRIGGER.ACTIVE] = CONST.BATTLE_ACT.ACTIVE,
	[CONST.SKILL_TRIGGER.PASSIVE] = CONST.BATTLE_ACT.PASSIVE,
	[CONST.SKILL_TRIGGER.PURSUE] = CONST.BATTLE_ACT.PURSUE,
	[CONST.SKILL_TRIGGER.COMMAND] = CONST.BATTLE_ACT.COMMAND,
}

local function hero_stats(cfg_id, level)
	local conf = DATA_COMMON.get_hero_info_by_type(cfg_id)
	if not conf then
		return
	end
	local grow = 1 + (level - 1) * CONST.BATTLE_HERO_LV_GROWTH / 100
	-- Hero：Attack 武力、Hp 谋略、Defense 防御、Speed 速度、Crit 破坏
	return {
		attack = (conf.Attack or 0) * grow,
		intel = (conf.Hp or 0) * grow,
		defense = (conf.Defense or 0) * grow,
		speed = conf.Speed or 0,
		crit = conf.Crit or 0,
		magic = conf.Class == "法师",
	}
end

local function monster_stats(cfg_id)
	local conf = DATA_COMMON.get_monster_conf(cfg_id)
	if not conf then
		return
	end
	return {
		attack = conf.Attack or 0,
		intel = conf.Hp or 0,
		defense = conf.Defense or 0,
		speed = conf.Speed or 0,
		crit = conf.Crit or 0,
		magic = false,
	}
end

local function skill_level_conf(conf, lv)
	local levels = conf.Levels or EMPTY_TABLE
	return levels[lv] or levels[#levels]
end

local function new_unit(side, snap)
	local base
	if snap.kind == CONST.BATTLE_UNIT.MONSTER then
		base = monster_stats(snap.cfg_id)
	else
		base = hero_stats(snap.cfg_id, snap.level or 1)
	end
	if not base then
		return
	end
	local skills = {}
	for _, s in ipairs(snap.skills or EMPTY_TABLE) do
		local conf = DATA_COMMON.get_skill_conf(s.id)
		local lv_conf = conf and skill_level_conf(conf, s.lv or 1)
		if lv_conf then
			skills[#skills + 1] = {conf = conf, lv = lv_conf}
		end
	end
	return {
		side = side,
		pos = snap.pos,
		soldier = math.max(0, math.floor(snap.soldier or 0)),
		base = base,
		buffs = {},
		skills = skills,
	}
end

local function stat(u, key)
	local rate = 0
	for _, buff in ipairs(u.buffs) do
		if buff.attr == key then
			rate = rate + buff.value
		end
	end
	return math.max(0, u.base[key] * (1 + rate / 100))
end

local function alive(list)
	local ret = {}
	for _, u in ipairs(list) do
		if u.soldier > 0 then
			ret[#ret + 1] = u
		end
	end
	return ret
end

local function pick(rand, list, cnt)
	local pool = {}
	for i, u in ipairs(list) do
		pool[i] = u
	end
	local ret = {}
	for _ = 1, math.min(cnt, #pool) do
		local idx = rand(#pool)
		ret[#ret + 1] = pool[idx]
		table.remove(pool, idx)
	end
	return ret
end

local function pick_targets(ctx, caster, target_type)
	local enemies = alive(ctx.units[3 - caster.side])
	local T = CONST.SKILL_TARGET
	if target_type == T.ALLY_ALL then
		return alive(ctx.units[caster.side])
	elseif target_type == T.ENEMY_ONE then
		return pick(ctx.rand, enemies, 1)
	elseif target_type == T.ENEMY_1_2 then
		return pick(ctx.rand, enemies, ctx.rand(2))
	elseif target_type == T.ENEMY_2_3 then
		return pick(ctx.rand, enemies, 1 + ctx.rand(2))
	elseif target_type == T.ENEMY_ALL then
		return enemies
	end
	return {caster}
end

local function deal_damage(ctx, caster, target, rate)
	local key = caster.base.magic and "intel" or "attack"
	local atk = stat(caster, key)
	local def = stat(target, "defense")
	local dmg = 0
	local flags = 0
	if atk + def > 0 then
		dmg = caster.soldier * rate / 100 * atk / (atk + def) * CONST.BATTLE_DAMAGE_RATE
		if ctx.rand(1000) <= caster.base.crit then
			dmg = dmg * CONST.BATTLE_CRIT_RATE / 100
			flags = flags | CONST.BATTLE_FLAG.CRIT
		end
		dmg = math.max(1, math.floor(dmg))
	end
	dmg = math.min(dmg, target.soldier)
	target.soldier = target.soldier - dmg
	return {
		target_side = target.side,
		target_pos = target.pos,
		value = dmg,
		after_soldier = target.soldier,
		flags = flags,
	}
end

local function record(ctx, act_type, caster, skill_id, effects)
	ctx.actions[#ctx.actions + 1] = {
		round = ctx.round,
		act_type = act_type,
		from_side = caster.side,
		from_pos = caster.pos,
		skill_id = skill_id,
		effects = effects,
	}
end

-- 开战时生效的技能（被动、指挥）加的状态持续整场，其余按 effect_round 算回合
local function cast_skill(ctx, caster, skill)
	local conf = skill.conf
	local targets = pick_targets(ctx, caster, conf.Target)
	if #targets == 0 then
		return
	end
	local whole_battle = conf.Trigger == CONST.SKILL_TRIGGER.PASSIVE or conf.Trigger == CONST.SKILL_TRIGGER.COMMAND
	local effects = {}
	for i, eff in ipairs(conf.IncludeEffect or EMPTY_TABLE) do
		local value = (skill.lv.effect_value or EMPTY_TABLE)[i] or 0
		if eff == CONST.SKILL_EFFECT.DAMAGE then
			for _, target in ipairs(targets) do
				if target.soldier > 0 then
					effects[#effects + 1] = deal_damage(ctx, caster, target, value)
				end
			end
		elseif BUFF_ATTR[eff] then
			local rounds = (skill.lv.effect_round or EMPTY_TABLE)[i] or 0
			for _, target in ipairs(targets) do
				local signed = target.side == caster.side and value or -value
				target.buffs[#target.buffs + 1] = {
					attr = BUFF_ATTR[eff],
					value = signed,
					rounds = (not whole_battle and rounds > 0) and rounds or nil,
				}
				effects[#effects + 1] = {
					target_side = target.side,
					target_pos = target.pos,
					value = signed,
					after_soldier = target.soldier,
					flags = 0,
				}
			end
		end
	end
	if #effects > 0 then
		record(ctx, TRIGGER_ACT[conf.Trigger] or CONST.BATTLE_ACT.STATE, caster, conf.Id, effects)
	end
end

local function try_skills(ctx, caster, trigger, roll)
	for _, skill in ipairs(caster.skills) do
		if skill.conf.Trigger == trigger and caster.soldier > 0 then
			if not roll or ctx.rand(100) <= (skill.lv.probability or 0) then
				cast_skill(ctx, caster, skill)
			end
		end
	end
end

local function normal_attack(ctx, caster)
	local target = pick(ctx.rand, alive(ctx.units[3 - caster.side]), 1)[1]
	if not target then
		return
	end
	record(ctx, CONST.BATTLE_ACT.ATTACK, caster, 0, {deal_damage(ctx, caster, target, 100)})
end

local function side_alive(ctx, side)
	return #alive(ctx.units[side]) > 0
end

local function all_units(ctx)
	local list = {}
	for side = CONST.BATTLE_SIDE.ATK, CONST.BATTLE_SIDE.DEF do
		for _, u in ipairs(ctx.units[side]) do
			list[#list + 1] = u
		end
	end
	return list
end

local function action_order(ctx)
	local list = alive(all_units(ctx))
	local speed = {}
	for _, u in ipairs(list) do
		speed[u] = stat(u, "speed")
	end
	table.sort(list, function(a, b)
		if speed[a] ~= speed[b] then
			return speed[a] > speed[b]
		end
		if a.side ~= b.side then
			return a.side < b.side
		end
		return a.pos < b.pos
	end)
	return list
end

local function tick_buffs(ctx)
	for _, u in ipairs(all_units(ctx)) do
		local keep = {}
		for _, buff in ipairs(u.buffs) do
			if buff.rounds then
				buff.rounds = buff.rounds - 1
			end
			if not buff.rounds or buff.rounds > 0 then
				keep[#keep + 1] = buff
			end
		end
		u.buffs = keep
	end
end

local function build_units(side, snap_side)
	local list = {}
	for _, snap in ipairs(snap_side.units or EMPTY_TABLE) do
		local u = new_unit(side, snap)
		if u then
			list[#list + 1] = u
		end
	end
	table.sort(list, function(a, b)
		return a.pos < b.pos
	end)
	return list
end

local function left_map(list)
	local ret = {}
	for _, u in ipairs(list) do
		ret[u.pos] = u.soldier
	end
	return ret
end

-- 返回 {result, max_round, actions, atk_left = {[pos] = 剩余兵}, def_left = {...}}
function fight(atk_side, def_side, rand)
	local ATK, DEF = CONST.BATTLE_SIDE.ATK, CONST.BATTLE_SIDE.DEF
	local ctx = {
		rand = rand,
		round = 0,
		actions = {},
		units = {
			[ATK] = build_units(ATK, atk_side),
			[DEF] = build_units(DEF, def_side),
		},
	}
	local everyone = all_units(ctx)
	for _, u in ipairs(everyone) do
		try_skills(ctx, u, CONST.SKILL_TRIGGER.COMMAND, false)
	end
	for _, u in ipairs(everyone) do
		try_skills(ctx, u, CONST.SKILL_TRIGGER.PASSIVE, false)
	end
	while ctx.round < CONST.BATTLE_MAX_ROUND and side_alive(ctx, ATK) and side_alive(ctx, DEF) do
		ctx.round = ctx.round + 1
		for _, u in ipairs(action_order(ctx)) do
			if u.soldier > 0 and side_alive(ctx, 3 - u.side) then
				try_skills(ctx, u, CONST.SKILL_TRIGGER.ACTIVE, true)
				if side_alive(ctx, 3 - u.side) then
					normal_attack(ctx, u)
					try_skills(ctx, u, CONST.SKILL_TRIGGER.PURSUE, true)
				end
			end
		end
		tick_buffs(ctx)
	end
	local result = CONST.BATTLE_RESULT.LOSE
	if not side_alive(ctx, DEF) then
		result = CONST.BATTLE_RESULT.WIN
	end
	return {
		result = result,
		max_round = ctx.round,
		actions = ctx.actions,
		atk_left = left_map(ctx.units[ATK]),
		def_left = left_map(ctx.units[DEF]),
	}
end

-- 一批进攻方按顺序打同一个目标，守方兵力在这一批里接着扣。守方打光后后面的直接算赢
function fight_batch(def_side, atk_list, rand)
	local def = {owner_id = def_side.owner_id, name = def_side.name, power = def_side.power, units = {}}
	for i, snap in ipairs(def_side.units or EMPTY_TABLE) do
		local copy = {}
		for k, v in pairs(snap) do
			copy[k] = v
		end
		def.units[i] = copy
	end
	local ret = {}
	for i, atk_side in ipairs(atk_list) do
		local res = fight(atk_side, def, rand)
		for _, snap in ipairs(def.units) do
			if res.def_left[snap.pos] then
				snap.soldier = res.def_left[snap.pos]
			end
		end
		ret[i] = res
	end
	return ret
end
