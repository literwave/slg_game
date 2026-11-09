local skynet = require "skynet"

-- 世界实体与视野索引必须一起保留：热更只替换函数，不能清空正在行军的部队。
-- 否则客户端走到了终点，而世界帧已找不到实体，永远不会发送到达通知。
runtime = runtime or {entities = {}, focus_tbl = {}, entity_buckets = {}, focus_buckets = {}, active_movers = {}}
local entities = runtime.entities
local focus_tbl = runtime.focus_tbl
local active_movers = runtime.active_movers
local function track_mover(e)
    if entities[e.id] == e and e.moving and not e.fighting and not e.waiting and not e.hidden then
        active_movers[e.id] = e
    elseif active_movers[e.id] == e then
        active_movers[e.id] = nil
    end
end
-- 桶边长等于视野半径。距离不超过半径时，横竖最多隔一个桶，查周围 3×3 即可
local BUCKET = CONST.AOI_RADIUS
local BUCKET_KEY = 1024
local RADIUS2 = CONST.AOI_RADIUS * CONST.AOI_RADIUS
local entity_buckets = runtime.entity_buckets
local focus_buckets = runtime.focus_buckets
-- 这一拍里同一个人的进出合并成一条 aoi_push。帧外的状态变化马上发
local batching = false
local pending
-- 热更留在模块上。帧里只读这份缓存，不能 skynet.call
agent_list = agent_list

local function bucket_key(x, y)
	return math.floor(x / BUCKET) * BUCKET_KEY + math.floor(y / BUCKET)
end

local function unbucket(buckets, obj, id)
	local old = obj.aoi_bucket
	if not old then
		return
	end
	local b = buckets[old]
	if b then
		b[id] = nil
		if not next(b) then
			buckets[old] = nil
		end
	end
	obj.aoi_bucket = nil
end

local function put_bucket(buckets, obj, id, x, y)
	local k = bucket_key(x, y)
	if obj.aoi_bucket == k then
		return
	end
	unbucket(buckets, obj, id)
	local b = buckets[k]
	if not b then
		b = {}
		buckets[k] = b
	end
	b[id] = obj
	obj.aoi_bucket = k
end

local function each_near(buckets, x, y, fn)
	local bx = math.floor(x / BUCKET)
	local by = math.floor(y / BUCKET)
	for ox = -1, 1 do
		for oy = -1, 1 do
			local b = buckets[(bx + ox) * BUCKET_KEY + (by + oy)]
			if b then
				for id, obj in pairs(b) do
					fn(id, obj)
				end
			end
		end
	end
end

-- 帧里只查缓存。拉列表会 skynet.call，不能放在帧里
local function load_agent_list()
	agent_list = skynet.call(".gated", "lua", "get_agent_list")
end

local function agent_of(user_id)
	local n = agent_list and #agent_list or 0
	if n < 1 then
		return
	end
	return agent_list[user_id % n + 1]
end

local function entity_pto(e)
	local pto = {
		entityId = e.id,
		entityType = e.entity_type,
		pos = {x = math.floor(e.x), y = math.floor(e.y)},
		ownerId = e.owner_id or 0,
		cfgId = e.cfg_id or 0,
	}
    if e.entity_type == DATA_COMMON.ENTITY_TYPE.TROOP then
        pto.troopIdx = e.troop_idx
        pto.troopState = e.troop_state or (e.moving and DATA_COMMON.TROOP_STATE.MARCH or DATA_COMMON.TROOP_STATE.STAY)
        pto.targetId = e.deployed_city or e.siege_target or 0
        pto.targetPos = e.siege_pos
    end
    if e.troop_state == DATA_COMMON.TROOP_STATE.SIEGE then
        pto.startTime, pto.endTime = e.start_time, e.end_time
	elseif e.moving then
		pto.path = MARCH_PATH.to_pto(e.path)
		pto.startTime = e.start_time
		pto.endTime = e.end_time
	elseif e.occupy_end and e.occupy_end > 0 then
		pto.startTime = e.occupy_start
		pto.endTime = e.occupy_end
	end
	if e.entity_type == DATA_COMMON.ENTITY_TYPE.CITY or e.entity_type == DATA_COMMON.ENTITY_TYPE.ALLIANCE_CITY then
		pto.name = e.name
		pto.level = e.level
		pto.allianceId = e.alliance_id or 0
	end
	return pto
end

local function in_view(f, e)
	if e.hidden then
		return false
	end
	local dx = e.x - f.x
	local dy = e.y - f.y
	return dx * dx + dy * dy <= RADIUS2
end

local function push(user_id, enter, leave, update)
	if #enter == 0 and #leave == 0 and #update == 0 then
		return
	end
	local agent = agent_of(user_id)
	if not agent then
		return
	end
	skynet.send(agent, "lua", "aoi_push", user_id, {
		enter = enter,
		leave = leave,
		update = update,
	})
end

local function list_del(list, index, id, id_of)
	local i = index[id]
	if not i then
		return
	end
	local n = #list
	index[id] = nil
	if i ~= n then
		local last = list[n]
		list[i] = last
		index[id_of(last)] = i
	end
	list[n] = nil
end

local function pack_of(user_id)
	if not pending then
		pending = {}
	end
	local p = pending[user_id]
	if not p then
		p = {enter = {}, leave = {}, update = {}, enter_i = {}, leave_i = {}, update_i = {}}
		pending[user_id] = p
	end
	return p
end

local function note_update(user_id, pto)
	local p = pack_of(user_id)
	local id = pto.entityId
	local i = p.enter_i[id]
	if i then
		p.enter[i] = pto
		return
	end
	if p.leave_i[id] then
		list_del(p.leave, p.leave_i, id, function(v)
			return v
		end)
	end
	i = p.update_i[id]
	if i then
		p.update[i] = pto
		return
	end
	local n = #p.update + 1
	p.update[n] = pto
	p.update_i[id] = n
end

local function note_enter(user_id, pto)
	local p = pack_of(user_id)
	local id = pto.entityId
	if p.leave_i[id] then
		list_del(p.leave, p.leave_i, id, function(v)
			return v
		end)
		note_update(user_id, pto)
		return
	end
	local i = p.enter_i[id]
	if i then
		p.enter[i] = pto
		return
	end
	local n = #p.enter + 1
	p.enter[n] = pto
	p.enter_i[id] = n
end

local function note_leave(user_id, id)
	local p = pack_of(user_id)
	if p.enter_i[id] then
		list_del(p.enter, p.enter_i, id, function(v)
			return v.entityId
		end)
		return
	end
	if p.update_i[id] then
		list_del(p.update, p.update_i, id, function(v)
			return v.entityId
		end)
	end
	if p.leave_i[id] then
		return
	end
	local n = #p.leave + 1
	p.leave[n] = id
	p.leave_i[id] = n
end

local function emit_enter(user_id, pto)
	if batching then
		note_enter(user_id, pto)
		return
	end
	push(user_id, {pto}, {}, {})
end

local function emit_leave(user_id, id)
	if batching then
		note_leave(user_id, id)
		return
	end
	push(user_id, {}, {id}, {})
end

local function emit_update(user_id, pto)
	if batching then
		note_update(user_id, pto)
		return
	end
	push(user_id, {}, {}, {pto})
end

local function flush_pending()
	local pack = pending
	pending = nil
	if not pack then
		return
	end
	for user_id, p in pairs(pack) do
		push(user_id, p.enter, p.leave, p.update)
	end
end

local function watch(e, user_id, on)
	local w = e.watchers
	if on then
		if not w then
			w = {}
			e.watchers = w
		end
		w[user_id] = true
		return
	end
	if w then
		w[user_id] = nil
	end
end

-- with_update：停步、改路、开打这类状态变化才推 update。沿原路径过格只推走进和走出
local function sync_entity(e, with_update)
	put_bucket(entity_buckets, e, e.id, e.x, e.y)
	local pto
	local function snap()
		if not pto then
			pto = entity_pto(e)
		end
		return pto
	end
	local seen_now = {}
	each_near(focus_buckets, e.x, e.y, function(user_id, f)
		seen_now[user_id] = true
		local was = f.seen[e.id]
		local inside = in_view(f, e)
		if inside and not was then
			f.seen[e.id] = true
			watch(e, user_id, true)
			emit_enter(user_id, snap())
		elseif inside and was and with_update then
			emit_update(user_id, snap())
		elseif was and not inside then
			f.seen[e.id] = nil
			watch(e, user_id, false)
			emit_leave(user_id, e.id)
		end
	end)
	local w = e.watchers
	if not w then
		return
	end
	local gone = {}
	for user_id in pairs(w) do
		if not seen_now[user_id] then
			gone[#gone + 1] = user_id
		end
	end
	for _, user_id in ipairs(gone) do
		w[user_id] = nil
		local f = focus_tbl[user_id]
		if f then
			f.seen[e.id] = nil
		end
		emit_leave(user_id, e.id)
	end
end

local function refresh_entity(e)
    track_mover(e)
	sync_entity(e, true)
end

local function sync_cross(e)
	sync_entity(e, false)
end

local function leave_all(e)
    if active_movers[e.id] == e then active_movers[e.id] = nil end
	unbucket(entity_buckets, e, e.id)
	local w = e.watchers
	e.watchers = nil
	if not w then
		return
	end
	for user_id in pairs(w) do
		local f = focus_tbl[user_id]
		if f then
			f.seen[e.id] = nil
		end
		emit_leave(user_id, e.id)
	end
end

local function place_group(group_id)
	local conf = DATA_COMMON.get_monster_group(group_id)
	if not conf then
		return
	end
	local eid = CONST.monster_entity_id(group_id)
	if entities[eid] then
		return
	end
	local idx = MAP_MGR.alloc_wild_idx()
	if not idx then
		skynet.timeout(6000, function()
			place_group(group_id)
		end)
		return
	end
	local pos = MAP_MGR.pos_of_idx(idx)
	local e = {
		id = eid,
		entity_type = DATA_COMMON.ENTITY_TYPE.MONSTER_GROUP,
		x = pos.x,
		y = pos.y,
		owner_id = 0,
		cfg_id = group_id,
		birth_idx = idx,
	}
	entities[eid] = e
	refresh_entity(e)
end

-- 已被占领的地块才进视野。中立地没有实体
function upsert_alliance_city(info)
	local e = entities[info.entityId] or {id = info.entityId,
		entity_type = DATA_COMMON.ENTITY_TYPE.ALLIANCE_CITY, owner_id = 0}
	entities[e.id] = e
	e.cfg_id, e.level = info.cityType * 100 + info.level, info.level
	e.x, e.y = info.pos.x, info.pos.y
	e.name, e.alliance_id = info.allianceName, info.allianceId
	refresh_entity(e)
end

function city_watchers(id)
	local out = {}
	for uid in pairs(entities[id] and entities[id].watchers or {}) do out[uid] = true end
	return out
end

function upsert_land(info)
	local e = entities[info.id]
	if not e then
		e = {
			id = info.id,
			entity_type = DATA_COMMON.ENTITY_TYPE.RES_LAND,
			cfg_id = info.cfg_id,
			user_id = info.owner_id,
		}
		entities[info.id] = e
	end
	e.owner_id = info.owner_id
	e.cfg_id = info.cfg_id
	e.x = info.x
	e.y = info.y
	e.troop_idx = info.troop_idx
	e.remain = info.remain
	e.occupy_start = info.occupy_start or 0
	e.occupy_end = info.occupy_end or 0
	refresh_entity(e)
end

function remove_land(entity_id)
	local e = entities[entity_id]
	if not e or e.entity_type ~= DATA_COMMON.ENTITY_TYPE.RES_LAND then
		return
	end
	entities[entity_id] = nil
	leave_all(e)
end

function upsert_city(user_id, x, y, info)
	local id = CONST.city_entity_id(user_id)
	local e = entities[id]
	if not e then
		e = {
			id = id,
			entity_type = DATA_COMMON.ENTITY_TYPE.CITY,
			owner_id = user_id,
			cfg_id = 0,
			user_id = user_id,
		}
		entities[id] = e
	end
	e.name = info.name
	e.level = info.level
	e.x = x
	e.y = y
	refresh_entity(e)
	if MAP_MGR then
		MAP_MGR.set_city(user_id, x, y)
	end
end

local function restore_move(e, gen)
	if e.battle_gen ~= gen then
		return
	end
	e.battle_gen = nil
	e.fighting = false
	if entities[e.id] ~= e then
		return
	end
	if e.was_moving then
		e.moving = true
		e.was_moving = nil
	end
    track_mover(e)
end

local function abort_encounter(atk, def, gen, x, y)
	restore_move(atk, gen)
	restore_move(def, gen)
	for _, e in ipairs(ENCOUNTER_MGR.release_cell(x, y)) do
		if entities[e.id] == e and e.was_moving then
			e.moving = true
			e.was_moving = nil
		end
        track_mover(e)
	end
end

local function send_encounter(e, role, atk_pack, def_pack, res, x, y, plan)
	local agent = agent_of(e.user_id)
	if not agent then
		return
	end
	local snap = role == CONST.BATTLE_SIDE.ATK and atk_pack or def_pack
	skynet.send(agent, "lua", "encounter_result", e.user_id, e.troop_idx, {
		role = role,
		result = res.result,
		atk_side = atk_pack.side,
		def_side = def_pack.side,
		atk_left = res.atk_left,
		def_left = res.def_left,
		actions = res.actions,
		max_round = res.max_round,
		x = x,
		y = y,
		stamp = snap.end_time,
		state = snap.state,
		resume = plan and plan.resume or nil,
		go_home = plan and plan.go_home or false,
	})
end

-- 赢的一方接着走。已经站在终点上就等结算包先落地再按到达处理，这里只返回计划
local function winner_plan(e)
	if entities[e.id] ~= e then
		return
	end
	e.fighting = false
	if not e.was_moving then
		e.was_moving = nil
		refresh_entity(e)
		return
	end
	local ex, ey = MARCH_PATH.last_pos(e.path)
	local dx, dy = math.floor(ex), math.floor(ey)
	if dx == e.hold_x and dy == e.hold_y then
		e.was_moving = nil
		e.moving = false
		e.x, e.y = ex, ey
		refresh_entity(e)
		return {arrive = true, end_time = e.end_time}
	end
	local path = MAP_MGR.find_march_path(e.user_id, e.hold_x, e.hold_y, dx, dy)
	if not path then
		e.was_moving = nil
		ENCOUNTER_MGR.note_flee(e)
		refresh_entity(e)
		return {go_home = true}
	end
	local now = TIME.now()
	local cost = MARCH_PATH.march_seconds(path, DATA_COMMON.get_march_speed(e.target_type))
	e.path = path
	e.start_time = now
	e.end_time = now + cost
	e.moving = true
	e.was_moving = nil
	e.scan_time = now
	e.x, e.y = path[1]._x, path[1]._y
	ENCOUNTER_MGR.index_at(e, e.hold_x, e.hold_y)
	refresh_entity(e)
	return {resume = {path = path, start_time = now, end_time = e.end_time}}
end

local function launch_encounter(f)
	local atk, def, gen, x, y = f.atk, f.def, f.gen, f.x, f.y
	skynet.fork(function()
		local atk_agent = agent_of(atk.user_id)
		local def_agent = agent_of(def.user_id)
		if not atk_agent or not def_agent then
			abort_encounter(atk, def, gen, x, y)
			return
		end
		local ok1, atk_pack = pcall(skynet.call, atk_agent, "lua", "encounter_snap", atk.user_id, atk.troop_idx)
		local ok2, def_pack = pcall(skynet.call, def_agent, "lua", "encounter_snap", def.user_id, def.troop_idx)
		if not ok1 or not ok2 or not atk_pack or not def_pack or not atk_pack.side or not def_pack.side then
			if ok1 and not atk_pack and entities[atk.id] == atk then
				remove_troop(atk.user_id, atk.troop_idx)
			end
			if ok2 and not def_pack and entities[def.id] == def then
				remove_troop(def.user_id, def.troop_idx)
			end
			abort_encounter(atk, def, gen, x, y)
			return
		end
		if atk.battle_gen ~= gen or def.battle_gen ~= gen then
			return
		end
		local cnt = tonumber(skynet.getenv("battle_cnt")) or 1
		local slot = (x * 1024 + y) % cnt + 1
		local ok3, res = pcall(skynet.call, ".battle" .. slot, "lua", "fight_batch", def_pack.side, {atk_pack.side})
		if atk.battle_gen ~= gen or def.battle_gen ~= gen then
			return
		end
		if not ok3 or not res or not res[1] then
			abort_encounter(atk, def, gen, x, y)
			return
		end
		local one = res[1]
		local atk_here = entities[atk.id] == atk
		local def_here = entities[def.id] == def
		if not atk_here or not def_here then
			send_encounter(atk, CONST.BATTLE_SIDE.ATK, atk_pack, def_pack, one, x, y, nil)
			send_encounter(def, CONST.BATTLE_SIDE.DEF, atk_pack, def_pack, one, x, y, nil)
			abort_encounter(atk, def, gen, x, y)
			return
		end
		local atk_win = one.result == CONST.BATTLE_RESULT.WIN
		local ret = ENCOUNTER_MGR.conclude(atk, def, gen, atk_win)
		local winner = atk_win and atk or def
		local loser = atk_win and def or atk
		refresh_entity(loser)
		local plan
		if not ret or not ret.chain then
			plan = winner_plan(winner)
		end
		send_encounter(loser, atk_win and CONST.BATTLE_SIDE.DEF or CONST.BATTLE_SIDE.ATK, atk_pack, def_pack, one, x, y, {go_home = true})
		send_encounter(winner, atk_win and CONST.BATTLE_SIDE.ATK or CONST.BATTLE_SIDE.DEF, atk_pack, def_pack, one, x, y, plan)
		if plan and plan.arrive then
			local agent = agent_of(winner.user_id)
			if agent then
				skynet.send(agent, "lua", "march_arrive", winner.user_id, winner.troop_idx, plan.end_time)
			end
		end
		if ret and ret.chain then
			refresh_entity(ret.chain.atk)
			refresh_entity(ret.chain.def)
			if ret.stops then
				for _, stopped in ipairs(ret.stops) do
					refresh_entity(stopped)
				end
			end
			-- 另开一轮，避免这场结算还卡在玩家进程里时再 call 回去
			local chain = ret.chain
			skynet.fork(function()
				launch_encounter(chain)
			end)
		end
	end)
end

function apply_encounter(fights, stops)
	for _, e in ipairs(stops) do
		refresh_entity(e)
	end
	for _, f in ipairs(fights) do
		refresh_entity(f.atk)
		refresh_entity(f.def)
		launch_encounter(f)
	end
end

function start_march(info)
	local id = CONST.troop_entity_id(info.user_id, info.troop_idx)
	local old = entities[id]
	if old then
		ENCOUNTER_MGR.unindex(old)
		unbucket(entity_buckets, old, old.id)
	end
	local now = TIME.now()
	local x, y = MARCH_PATH.pos_at(info.path, info.start_time, info.end_time, now)
	local e = {
		id = id,
		entity_type = DATA_COMMON.ENTITY_TYPE.TROOP,
		owner_id = info.user_id,
		cfg_id = 0,
		user_id = info.user_id,
		troop_idx = info.troop_idx,
		target_type = info.target_type,
		march_serial = info.serial,
		troop_state = DATA_COMMON.TROOP_STATE.MARCH,
		moving = true,
		path = info.path,
		start_time = info.start_time,
		end_time = info.end_time,
		x = x,
		y = y,
		scan_time = now,
	}
	if old then
		e.watchers = old.watchers
		old.watchers = nil
	end
	entities[id] = e
    track_mover(e)
	ENCOUNTER_MGR.index_at(e, math.floor(x), math.floor(y))
	local fight, extra = ENCOUNTER_MGR.touch(e)
	if fight or (extra and extra[1]) then
		apply_encounter(fight and {fight} or {}, extra or {})
	end
	refresh_entity(e)
	return true
end

-- 攻城保持真实城外落脚点，退出同格遭遇索引，攻城状态及目标广播给视野内玩家。
function siege_troop(info, target_pos)
    local x, y = MARCH_PATH.last_pos(info.path)
    if not x or not target_pos then return false end
    local id = CONST.troop_entity_id(info.user_id, info.troop_idx)
    local e = entities[id] or {id = id, entity_type = DATA_COMMON.ENTITY_TYPE.TROOP,
        owner_id = info.user_id, cfg_id = 0, user_id = info.user_id, troop_idx = info.troop_idx}
    entities[id] = e
    ENCOUNTER_MGR.unindex(e)
    ENCOUNTER_MGR.clear_flee(e)
    e.moving, e.hidden, e.path = false, false, nil
    e.x, e.y = x, y
    e.troop_state = DATA_COMMON.TROOP_STATE.SIEGE
    e.march_serial, e.deployed_city = info.serial or e.march_serial, nil
    e.siege_target, e.siege_pos = info.target_id, target_pos
    e.start_time, e.end_time = info.start_time, info.end_time
    refresh_entity(e)
    return true
end

-- 停在城外的部队留在到达点上。回到主城的不进这里，主城本身就是那个实体
function park_troop(user_id, troop_idx, x, y, arrival_serial, city_id)
	city_id = city_id or (arrival_serial and CITY_MGR and CITY_MGR.deployed_city
        and CITY_MGR.deployed_city(user_id, troop_idx, arrival_serial))
	local id = CONST.troop_entity_id(user_id, troop_idx)
	local e = entities[id]
	if e and arrival_serial and e.march_serial and e.march_serial ~= arrival_serial
        and (not city_id or e.march_serial > arrival_serial) then return end
	if e and e.moving and not arrival_serial then
		return
	end
	if not e then
		e = {
			id = id,
			entity_type = DATA_COMMON.ENTITY_TYPE.TROOP,
			owner_id = user_id,
			cfg_id = 0,
			user_id = user_id,
			troop_idx = troop_idx,
		}
		entities[id] = e
	end
	ENCOUNTER_MGR.unindex(e)
	ENCOUNTER_MGR.clear_flee(e)
	e.moving, e.hidden = false, false
	e.path = nil
	e.troop_state = DATA_COMMON.TROOP_STATE.STAY
	e.march_serial = arrival_serial or e.march_serial
	e.deployed_city = city_id
	e.siege_target, e.siege_pos = nil, nil
	e.start_time = nil
	e.end_time = nil
	e.x = x
	e.y = y
	refresh_entity(e)
end

-- 回到主城：实体留着，退出视野，也不再参与同格遭遇
function hide_troop(user_id, troop_idx)
	local id = CONST.troop_entity_id(user_id, troop_idx)
	local e = entities[id]
	if not e then
		return
	end
	ENCOUNTER_MGR.unindex(e)
	ENCOUNTER_MGR.clear_flee(e)
	e.hidden = true
	e.moving = false
	leave_all(e)
end

function remove_troop(user_id, troop_idx)
	local id = CONST.troop_entity_id(user_id, troop_idx)
	local e = entities[id]
	if not e then
		return
	end
	ENCOUNTER_MGR.unindex(e)
	ENCOUNTER_MGR.clear_flee(e)
	entities[id] = nil
	leave_all(e)
end

function monster_pos(entity_id)
	local e = entities[entity_id]
	if not e or e.entity_type ~= DATA_COMMON.ENTITY_TYPE.MONSTER_GROUP then
		return
	end
	return {x = e.x, y = e.y, cfg_id = e.cfg_id}
end

-- 仅本人部队或当前视野内的部队可补查；不向客户端泄漏全图行军路线。
function get_march_path(user_id, entity_id)
	local e = entities[entity_id]
	if not e or e.hidden or not e.moving or e.entity_type ~= DATA_COMMON.ENTITY_TYPE.TROOP then return {} end
	local f = focus_tbl[user_id]
	if e.owner_id ~= user_id and (not f or not f.seen[entity_id] or not in_view(f, e)) then return {} end
	return MARCH_PATH.to_pto(e.path)
end

function kill_monster(entity_id)
	local e = entities[entity_id]
	if not e or e.entity_type ~= DATA_COMMON.ENTITY_TYPE.MONSTER_GROUP then
		return
	end
	local cfg_id = e.cfg_id
	entities[entity_id] = nil
	if e.birth_idx then
		MAP_MGR.get_map():release_birth_idx(e.birth_idx)
	end
	leave_all(e)
	local conf = DATA_COMMON.get_monster_group(cfg_id)
	local wait = 60
	if conf and conf.Refresh and conf.Refresh > 0 then
		wait = conf.Refresh
	end
	skynet.timeout(wait * 100, function()
		place_group(cfg_id)
	end)
	return cfg_id
end

function focus(user_id, x, y)
	local f = focus_tbl[user_id]
    -- Entity movement and lifecycle updates already maintain this observer's
    -- seen set. A repeated focus does not need to rescan the spatial buckets.
    if f and f.initialized and f.x == x and f.y == y then return {enter = {}, leave = {}} end
	if not f then
		f = {seen = {}}
		focus_tbl[user_id] = f
	end
    f.initialized = false
	f.x = x
	f.y = y
	put_bucket(focus_buckets, f, user_id, x, y)
	local now_seen = {}
	local enter = {}
	local leave = {}
	each_near(entity_buckets, x, y, function(id, e)
		if in_view(f, e) then
			now_seen[id] = true
			if not f.seen[id] then
				enter[#enter + 1] = entity_pto(e)
				watch(e, user_id, true)
			end
		end
	end)
	for id in pairs(f.seen) do
		if not now_seen[id] then
			leave[#leave + 1] = id
			local e = entities[id]
			if e then
				watch(e, user_id, false)
			end
		end
	end
	f.seen = now_seen
    f.initialized = true
	return {enter = enter, leave = leave}
end

function clear_focus(user_id)
	local f = focus_tbl[user_id]
	if not f then
		return
	end
	for id in pairs(f.seen) do
		local e = entities[id]
		if e then
			watch(e, user_id, false)
		end
	end
	unbucket(focus_buckets, f, user_id)
	focus_tbl[user_id] = nil
end

-- 到达并在终点再看一眼同格。只 send，不 call
local function finish_arrive(e)
	if not e.moving or e.fighting or e.waiting or entities[e.id] ~= e then
		return
	end
	e.x, e.y = MARCH_PATH.last_pos(e.path)
	ENCOUNTER_MGR.index_at(e, math.floor(e.x), math.floor(e.y))
	local fight, extra = ENCOUNTER_MGR.touch(e)
	if fight or (extra and extra[1]) then
		apply_encounter(fight and {fight} or {}, extra or {})
		return
	end
	e.moving = false
	refresh_entity(e)
	local agent = agent_of(e.user_id)
	if agent then
		skynet.send(agent, "lua", "march_arrive", e.user_id, e.troop_idx, e.end_time)
	end
end

-- 推进到真实时间 now。now 和上一拍的差不一定是 WORLD_TICK_SEC，晚到的时间在这一拍里补上
-- 这里不能 skynet.call / sleep，否则补帧的耗时对不上
-- 沿路径过格只做走进/走出；停步和开打走 refresh_entity。这一拍的推送在结束时合成一条
local function do_step(now)
	local movers = {}
	for id, e in pairs(active_movers) do
        if entities[id] == e and e.moving and not e.fighting and not e.waiting and not e.hidden then
            movers[#movers + 1] = e
        else
            active_movers[id] = nil
        end
	end
	local fights, stops = ENCOUNTER_MGR.advance(movers, now)
	apply_encounter(fights, stops)
	for _, e in ipairs(movers) do
		if e.moving and now >= e.end_time then
			finish_arrive(e)
		elseif e.moving then
			local x, y = MARCH_PATH.pos_at(e.path, e.start_time, e.end_time, now)
			local cx, cy = math.floor(x), math.floor(y)
			local moved = cx ~= math.floor(e.x) or cy ~= math.floor(e.y)
			e.x, e.y = x, y
			if moved then
				sync_cross(e)
			end
		end
	end
end

local stepping = false
local YIELD_FUNC = {"call", "rawcall", "sleep", "wait"}
local function without_yield(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    if coroutine.status(co) ~= "dead" then
        local closed, close_err = coroutine.close(co)
        return false, closed and "world step cannot yield" or close_err
    end
    if not ok then
        err = debug.traceback(co, tostring(err))
        coroutine.close(co)
    end
    return ok, err
end

local function step_body(now)
    batching = true
    local ok, err = xpcall(do_step, debug.traceback, now)
    batching = false
    flush_pending()
    if not ok then error(err, 0) end
end

function step(now)
    assert(not stepping, "world step reentry")
    stepping = true
    local saved = {}
    for _, name in ipairs(YIELD_FUNC) do
        saved[#saved + 1] = {name=name, value=skynet[name]}
        skynet[name] = function() error("world step cannot yield", 2) end
    end
    -- A private coroutine catches direct yields as well as guarded Skynet calls.
    -- It is resumed once only; a failed frame never leaves a suspended writer.
    local ok, err = without_yield(step_body, now)
    batching = false
    if pending then
        local flushed, flush_err = without_yield(flush_pending)
        if not flushed and ok then ok, err = false, flush_err end
    end
    for _, entry in ipairs(saved) do skynet[entry.name] = entry.value end
    stepping = false
    if not ok then error(err, 0) end
end

local metrics_enabled = skynet.getenv("performance_metrics") == "1"
local metric_bounds = {0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 250, 500, 1000, 5000}
local metrics = metrics_enabled and {ticks = 0, errors = 0, step_ms = {count=0,sum=0,max=0,buckets={}},
    late_ms = {count=0,sum=0,max=0,buckets={}}} or nil
local expected_tick
local function observe(metric, value)
    metric.count, metric.sum, metric.max = metric.count + 1, metric.sum + value, math.max(metric.max, value)
    local index = #metric_bounds + 1
    for i, bound in ipairs(metric_bounds) do if value <= bound then index = i; break end end
    metric.buckets[index] = (metric.buckets[index] or 0) + 1
end

function performance_stats()
    if not metrics then return {enabled = false} end
    local out = {enabled = true, ticks = metrics.ticks, errors = metrics.errors, late_resolution_ms = 10}
    for _, name in ipairs({"step_ms", "late_ms"}) do
        local value = metrics[name]
        local summary = {count=value.count, sum=value.sum, max=value.max, buckets={}}
        for i, bound in ipairs(metric_bounds) do
            summary.buckets[i] = {upper_ms=bound, count=value.buckets[i] or 0}
        end
        summary.overflow = value.buckets[#metric_bounds + 1] or 0
        out[name] = summary
    end
    return out
end

local function tick()
	local t0 = TIME.now()
    local step_started = metrics and skynet.hpc()
    if metrics then
        metrics.ticks = metrics.ticks + 1
        observe(metrics.late_ms, math.max(0, t0 - (expected_tick or t0)) * 1000)
    end
	local ok, err = xpcall(step, debug.traceback, t0)
    if metrics then
        observe(metrics.step_ms, (skynet.hpc() - step_started) / 1000000)
        if not ok then metrics.errors = metrics.errors + 1 end
    end
	if not ok then
		skynet.error("世界帧执行出错\n" .. tostring(err))
	end
	local wait = CONST.WORLD_TICK_SEC - (TIME.now() - t0)
	if wait < 0.01 then
		wait = 0.01
	end
    local ticks = math.floor(wait * 100 + 0.5)
    expected_tick = TIME.now() + ticks / 100
	skynet.timeout(ticks, tick)
end

local function troop_has_hero(troop)
	return type(troop._pos_tbl) == "table" and next(troop._pos_tbl) ~= nil
end

local function restore_marches()
	local troops = MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.USER_TROOP)
	local now = TIME.os_bj_sec()
	for _, doc in pairs(troops) do
		for _, troop in pairs(doc._troops or {}) do
			local march = troop._march
			if troop._user_id and troop._troop_idx and march then
				if march._state == CONST.MARCH_STATE.MOVING then
					if march._end_time and now >= march._end_time then
						local agent = agent_of(troop._user_id)
						if agent then
							skynet.send(agent, "lua", "march_arrive", troop._user_id, troop._troop_idx, march._end_time)
						end
					else
						start_march({
							user_id = troop._user_id,
							troop_idx = troop._troop_idx,
							target_type = march._target_type,
							serial = troop._march_serial,
							target_id = march._target_id,
							path = march._path or {},
							start_time = march._start_time,
							end_time = march._end_time,
						})
					end
                elseif march._state == CONST.MARCH_STATE.ARRIVED and (march._target_type == DATA_COMMON.TARGET_TYPE.ATTACK_CITY
                    or march._target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY) then
                    -- 包括攻城阶段和战后返程失败；即便玩家离线，也恢复同一流水号的结算。
                    local agent = agent_of(troop._user_id)
                    if agent then skynet.send(agent, "lua", "march_arrive", troop._user_id, troop._troop_idx, march._end_time) end
				elseif march._state == CONST.MARCH_STATE.ARRIVED and troop_has_hero(troop) then
					local tail = march._path and march._path[#march._path]
					local occupy_stay = march._target_type == DATA_COMMON.TARGET_TYPE.OCCUPY_RES_LAND
						and troop._troop_state == DATA_COMMON.TROOP_STATE.STAY
					if tail and (march._target_type == DATA_COMMON.TARGET_TYPE.MOVE or occupy_stay) then
						park_troop(troop._user_id, troop._troop_idx, tail._x, tail._y)
					end
				end
			end
		end
	end
end

function init()
	for group_id in pairs(DATA_COMMON.get_monster_group_tbl()) do
		place_group(group_id)
	end
	-- 资源地在 mapRes 快照里，按格子类型和等级读，不再随机铺到空地上
	local users = MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.USER_INFO, {
		["dat._user_id"] = 1, ["dat._name"] = 1, ["dat._has_birth"] = 1,
		["dat._birth_x"] = 1, ["dat._birth_y"] = 1,
	})
	local city_level = {}
	local main_bid = DATA_COMMON.get_main_city_bid()
	for _, doc in pairs(MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.USER_BUILD)) do
		for _, build in pairs(doc._builds or {}) do
			if build._bid == main_bid and build._user_id then
				city_level[build._user_id] = build._level
			end
		end
	end
	local birth = {}
	ENCOUNTER_MGR.load_alliances()
	MAP_MGR.begin_nav_batch()
	for _, dat in pairs(users) do
		if dat._has_birth and dat._user_id then
			birth[dat._user_id] = {x = dat._birth_x, y = dat._birth_y}
			upsert_city(dat._user_id, dat._birth_x, dat._birth_y, {
				name = dat._name,
				level = city_level[dat._user_id],
			})
		end
	end
	MAP_MGR.end_nav_batch()
	load_agent_list()
	LAND_MGR.init()
	CITY_MGR.init()
	restore_marches()
	skynet.timeout(1, tick)
end
