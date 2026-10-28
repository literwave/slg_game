local skynet = require "skynet"

-- 同一个目标固定进同一个战斗服务，多支部队打同一个目标时按顺序结算
local function battle_call(target_id, cmd, ...)
	local cnt = tonumber(skynet.getenv("battle_cnt")) or 1
	return skynet.call(".battle" .. (target_id % cnt + 1), "lua", cmd, ...)
end

local function troop_side(user, troop)
	local user_id = user:get_user_id()
	local units = {}
	for pos, info in pairs(troop:get_pos_tbl()) do
		local hero = HERO_MGR.get_hero_by_type(user_id, info._hero_idx)
		if hero then
			local skills = hero:get_battle_skills()
			table.sort(skills, function(a, b)
				return a.id < b.id
			end)
			units[#units + 1] = {
				pos = pos,
				kind = CONST.BATTLE_UNIT.HERO,
				cfg_id = info._hero_idx,
				level = hero:get_level(),
				soldier = info._soldier_cnt - info._hurt_cnt,
				count = info._soldier_cnt,
				hurt = info._hurt_cnt,
				skills = skills,
			}
		end
	end
	return {owner_id = user_id, name = user:get_name(), power = user:get_power(), units = units}
end

local function monster_side(group)
	local units = {}
	for _, m in ipairs(group.Monsters) do
		local conf = DATA_COMMON.get_monster_conf(m.mid)
		if conf then
			units[#units + 1] = {
				pos = m.pos,
				kind = CONST.BATTLE_UNIT.MONSTER,
				cfg_id = m.mid,
				level = conf.Level,
				soldier = conf.Soldier,
				count = conf.Soldier,
				hurt = 0,
			}
		end
	end
	return {owner_id = 0, name = group.Name, power = group.Power, units = units}
end

-- 损失的兵按 BATTLE_HURT_RATE 转伤兵，其余阵亡；返回各站位战后的 {count, hurt}
local function apply_troop_loss(troop, atk_left)
	local after = {}
	local changes = {}
	for pos, info in pairs(troop:get_pos_tbl()) do
		local left = atk_left[pos]
		if left then
			local lost = info._soldier_cnt - info._hurt_cnt - left
			local wounded = math.floor(lost * CONST.BATTLE_HURT_RATE / 100)
			changes[#changes + 1] = {
				pos = pos,
				hero_idx = info._hero_idx,
				count = info._soldier_cnt - (lost - wounded),
				hurt = info._hurt_cnt + wounded,
			}
		end
	end
	for _, c in ipairs(changes) do
		troop:set_pos(c.pos, c.hero_idx, c.count, c.hurt)
		after[c.pos] = {count = c.count, hurt = c.hurt}
	end
	return after
end

local function report_side(side, after)
	local units = {}
	for _, u in ipairs(side.units) do
		local a = after[u.pos] or {count = u.count, hurt = u.hurt}
		units[#units + 1] = {
			_pos = u.pos,
			_cfg_id = u.cfg_id,
			_level = u.level,
			_before_count = u.count,
			_before_hurt = u.hurt,
			_after_count = a.count,
			_after_hurt = a.hurt,
		}
	end
	return {_owner_id = side.owner_id, _name = side.name, _power = side.power, _units = units}
end

local function report_actions(actions)
	local list = {}
	for _, act in ipairs(actions) do
		local effects = {}
		for _, eff in ipairs(act.effects) do
			effects[#effects + 1] = {
				_target_side = eff.target_side,
				_target_pos = eff.target_pos,
				_value = eff.value,
				_after_soldier = eff.after_soldier,
				_flags = eff.flags,
			}
		end
		list[#list + 1] = {
			_round = act.round,
			_act_type = act.act_type,
			_from_side = act.from_side,
			_from_pos = act.from_pos,
			_skill_id = act.skill_id,
			_effects = effects,
		}
	end
	return list
end

local function battle_side_pto(side)
	local units = {}
	for _, u in ipairs(side.units) do
		units[#units + 1] = {
			pos = u.pos,
			cfgId = u.cfg_id,
			level = u.level,
			soldier = {count = u.soldier, hurtCount = u.hurt},
		}
	end
	return {ownerId = side.owner_id, name = side.name, power = side.power, units = units}
end

-- 部队打一组怪：结算损兵、赢了调 on_win 拿奖励（返回 nil 表示不发）、存战报并推给客户端
-- ctx = {entity_id, group, report_type, target_type, target_id, x, y, on_win}
local function fight_group(user, troop, ctx)
	local user_id = user:get_user_id()
	local atk = troop_side(user, troop)
	local def = monster_side(ctx.group)
	local res = battle_call(ctx.entity_id, "fight_batch", def, {atk})[1]
	local atk_after = apply_troop_loss(troop, res.atk_left)
	local def_after = {}
	for p, left in pairs(res.def_left) do
		def_after[p] = {count = left, hurt = 0}
	end
	local rewards = {}
	local reward_list = res.result == CONST.BATTLE_RESULT.WIN and ctx.on_win()
	if reward_list then
		for _, rw in ipairs(REWARD_MGR.reward_user(user_id, reward_list, {CONST.FLOW_REASON.BATTLE, ctx.target_id})) do
			rewards[#rewards + 1] = {_reward_type = rw.reward_type, _item_id = rw.item_id, _item_count = rw.item_count}
		end
	end
	local report = REPORT_MGR.add_report(user_id, {
		_report_type = ctx.report_type,
		_target_type = ctx.target_type,
		_target_id = ctx.target_id,
		_result = res.result,
		_time = TIME.os_bj_sec(),
		_is_read = false,
		_x = ctx.x,
		_y = ctx.y,
		_atk_side = report_side(atk, atk_after),
		_def_side = report_side(def, def_after),
		_rewards = rewards,
		_max_round = res.max_round,
		_actions = report_actions(res.actions),
	})
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	for_caller.s2c_sync_troop(fd, {troopInfo = troop:get_pto_info()})
	local battle_id = report._report_id
	for_caller.s2c_battle_start(fd, {
		battleId = battle_id,
		reportType = report._report_type,
		targetType = report._target_type,
		targetId = report._target_id,
		pos = {x = ctx.x, y = ctx.y},
		atkSide = battle_side_pto(atk),
		defSide = battle_side_pto(def),
	})
	for_caller.s2c_battle_result(fd, {
		battleId = battle_id,
		result = res.result,
		reportId = report._report_id,
		rewardList = REPORT_MGR.reward_pto_list(report._rewards),
	})
end

-- 部队到达野怪：打一场，赢了才击杀并发奖。部队状态已置为到达，回城由调用方处理
function attack_monster(user, troop)
	local entity_id = troop:get_target_id()
	local pos = MARCH_MGR.world_call("monster_pos", entity_id)
	if not pos then
		USER_MGR.tell_me(user:get_user_id(), "目标已消失")
		return
	end
	local group = DATA_COMMON.get_monster_group(pos.cfg_id)
	if not group then
		return
	end
	fight_group(user, troop, {
		entity_id = entity_id,
		group = group,
		report_type = DATA_COMMON.REPORT_TYPE.ATTACK_MONSTER,
		target_type = DATA_COMMON.TARGET_TYPE.ATTACK_MONSTER,
		target_id = pos.cfg_id,
		x = pos.x,
		y = pos.y,
		on_win = function()
			if MARCH_MGR.world_call("kill_monster", entity_id) then
				return group.Reward
			end
		end,
	})
end

local function land_holder(info)
	if (info.owner_id or 0) ~= 0 then
		return info.owner_id
	end
	return info.pending_owner or 0
end

local function begin_land_countdown(user_id, troop, entity_id)
	local gather_end, held, occupy_end = MARCH_MGR.world_call("occupy_res_land", entity_id, user_id, troop:get_troop_idx())
	if not held and not occupy_end and not gather_end then
		USER_MGR.tell_me(user_id, "无法占领")
		return
	end
	return gather_end, held, occupy_end
end

-- 部队到达地块。中立资源地打守军；别人的地打赢驻军（同格战）或无人防守后直接倒计时；自己的地接着采/驻
function occupy_res_land(user, troop)
	local user_id = user:get_user_id()
	local entity_id = troop:get_target_id()
	local info = MARCH_MGR.world_call("res_land_info", entity_id)
	if not info then
		USER_MGR.tell_me(user_id, "目标已消失")
		return
	end
	if info.covered then
		USER_MGR.tell_me(user_id, "城池范围内不能占领")
		return
	end
	local empty = info.cfg_id == 0
	local holder = land_holder(info)
	if holder ~= 0 and holder ~= user_id then
		-- 有驻军时同格战先打；赢了到达这里，世界侧会踢走还没撤的驻军并开倒计时
		return begin_land_countdown(user_id, troop, entity_id)
	end
	if empty then
		if info.troop_idx ~= 0 and info.troop_idx ~= troop:get_troop_idx() then
			USER_MGR.tell_me(user_id, "已有部队驻守")
			return
		end
		return begin_land_countdown(user_id, troop, entity_id)
	end
	if info.owner_id == user_id then
		if info.remain <= 0 then
			USER_MGR.tell_me(user_id, "资源尚未恢复")
			return
		end
		if info.troop_idx ~= 0 and info.troop_idx ~= troop:get_troop_idx() then
			USER_MGR.tell_me(user_id, "已有部队在采集")
			return
		end
		return MARCH_MGR.world_call("occupy_res_land", entity_id, user_id, troop:get_troop_idx())
	end
	local conf = DATA_COMMON.get_res_land_conf(info.cfg_id)
	if not conf then
		return
	end
	local group = DATA_COMMON.get_monster_group(conf.MonsterGroups[math.random(#conf.MonsterGroups)])
	if not group then
		return
	end
	local gather_end, held, occupy_end
	fight_group(user, troop, {
		entity_id = entity_id,
		group = group,
		report_type = DATA_COMMON.REPORT_TYPE.OCCUPY_RES_LAND,
		target_type = DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND,
		target_id = info.cfg_id,
		x = info.x,
		y = info.y,
		on_win = function()
			gather_end, held, occupy_end = MARCH_MGR.world_call("occupy_res_land", entity_id, user_id, troop:get_troop_idx())
			if gather_end or occupy_end then
				return conf.Reward
			end
		end,
	})
	return gather_end, held, occupy_end
end

-- 结算在到达时已经做完，跳过只是告诉客户端不用播了
local function on_battle_skip(fd, packet)
	if not USER_MGR.get_user_id_by_fd(fd) then
		return
	end
	for_caller.s2c_battle_skip(fd, {battleId = packet.battleId})
end

function snap_troop(user_id, troop_idx)
	local user = USER_MGR.try_init_user(user_id)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if not user or not troop or not troop:has_hero() then
		return
	end
	return {
		side = troop_side(user, troop),
		end_time = troop:get_end_time(),
		state = troop:get_march_state(),
	}
end

local function healthy_after(unit, remain)
	local hurt = unit.hurt or 0
	local count = unit.count or unit.soldier
	local lost = count - hurt - remain
	if lost < 0 then
		lost = 0
	end
	local wounded = math.floor(lost * CONST.BATTLE_HURT_RATE / 100)
	return {count = count - (lost - wounded), hurt = hurt + wounded}
end

local function after_map(side, left)
	local after = {}
	for _, unit in ipairs(side.units) do
		local remain = left and left[unit.pos]
		if remain then
			after[unit.pos] = healthy_after(unit, remain)
		end
	end
	return after
end

local function push_battle(fd, troop, report, atk, def)
	for_caller.s2c_sync_troop(fd, {troopInfo = troop:get_pto_info()})
	local battle_id = report._report_id
	for_caller.s2c_battle_start(fd, {
		battleId = battle_id,
		reportType = report._report_type,
		targetType = report._target_type,
		targetId = report._target_id,
		pos = {x = report._x, y = report._y},
		atkSide = battle_side_pto(atk),
		defSide = battle_side_pto(def),
	})
	for_caller.s2c_battle_result(fd, {
		battleId = battle_id,
		result = report._result,
		reportId = report._report_id,
		rewardList = {},
	})
end

-- 同格遭遇。伤害先扣；行军还是这一支时，输的回城，赢的按世界服务给出的新路径继续走
-- 回城要再叫世界服务，返回一个延迟函数，避免和世界服务互相 call
function on_encounter(user_id, troop_idx, pack)
	local user = USER_MGR.try_init_user(user_id)
	local troop = TROOP_MGR.get_troop(user_id, troop_idx)
	if not user or not troop or not pack or not pack.atk_side or not pack.def_side then
		return
	end
	local mine = pack.role == CONST.BATTLE_SIDE.ATK and pack.atk_left or pack.def_left
	apply_troop_loss(troop, mine or {})
	local result = pack.result
	if pack.role ~= CONST.BATTLE_SIDE.ATK then
		if pack.result == CONST.BATTLE_RESULT.WIN then
			result = CONST.BATTLE_RESULT.LOSE
		else
			result = CONST.BATTLE_RESULT.WIN
		end
	end
	local opponent = pack.role == CONST.BATTLE_SIDE.ATK and pack.def_side or pack.atk_side
	local report = REPORT_MGR.add_report(user_id, {
		_report_type = pack.role == CONST.BATTLE_SIDE.ATK and DATA_COMMON.REPORT_TYPE.ATTACK_PLAYER or DATA_COMMON.REPORT_TYPE.DEFEND,
		_target_type = 0,
		_target_id = opponent.owner_id,
		_result = result,
		_time = TIME.os_bj_sec(),
		_is_read = false,
		_x = pack.x,
		_y = pack.y,
		_atk_side = report_side(pack.atk_side, after_map(pack.atk_side, pack.atk_left)),
		_def_side = report_side(pack.def_side, after_map(pack.def_side, pack.def_left)),
		_rewards = {},
		_max_round = pack.max_round or 0,
		_actions = report_actions(pack.actions or {}),
	})
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if fd then
		push_battle(fd, troop, report, pack.atk_side, pack.def_side)
	end
	if troop:get_end_time() ~= pack.stamp or troop:get_march_state() ~= pack.state then
		return
	end
	if pack.go_home then
		local x, y = pack.x, pack.y
		local stamp, state = pack.stamp, pack.state
		return function()
			local now_user = USER_MGR.try_init_user(user_id)
			local now_troop = TROOP_MGR.get_troop(user_id, troop_idx)
			if not now_user or not now_troop or now_troop:get_end_time() ~= stamp or now_troop:get_march_state() ~= state then
				return
			end
			if MARCH_MGR.return_from(now_user, now_troop, x, y) then
				local now_fd = USER_MGR.get_fd_by_user_id(user_id)
				if now_fd then
					for_caller.s2c_sync_march(now_fd, {marchInfo = now_troop:get_march_pto()})
				end
			end
		end
	end
	if pack.resume then
		troop:set_march({
			state = CONST.MARCH_STATE.MOVING,
			target_type = troop:get_target_type(),
			target_id = troop:get_target_id(),
			path = pack.resume.path,
			start_time = pack.resume.start_time,
			end_time = pack.resume.end_time,
		})
		if fd then
			for_caller.s2c_sync_march(fd, {marchInfo = troop:get_march_pto()})
		end
	end
end

function __init__()
	for_maker.c2s_battle_skip = on_battle_skip
end
