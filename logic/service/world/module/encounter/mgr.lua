-- 同格遭遇：部队按格子进索引，只在进入某格时看这一格里有没有别的玩家
-- 一拍里可能跨多格，按路径把这段时间经过的格子摊开，按进入时间排序，不扫全图、也不两两比较
-- 同一联盟不打。没联盟的和没联盟的要打，所以联盟 id 为空不算同一边

local CELL = 1024

-- 同一时刻先进入再离开，对向穿过格子边界时也能撞上
local EV = {
	ENTER = 1,
	LEAVE = 2,
}

local cells = {}
local where = {}
local flee = {}
local battle_seq = 0
-- 热更保留。[user_id] = alliance_id，没有联盟的不在表里
alliance_of = alliance_of or {}

function set_user_alliance(user_id, alliance_id)
	local old_id = alliance_of[user_id]
	local new_id = alliance_id and alliance_id > 0 and alliance_id or nil
	if new_id then
		alliance_of[user_id] = new_id
	else
		alliance_of[user_id] = nil
	end
	if old_id ~= new_id and MAP_MGR and MAP_MGR.on_user_alliance then
		MAP_MGR.on_user_alliance(user_id, old_id, new_id)
	end
end

-- 成员表的 key 经 ORM 落库后是字符串
function load_alliances()
	alliance_of = {}
	for _, dat in pairs(MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.ALLIANCE)) do
		local alliance_id = dat._alliance_id
		if alliance_id and alliance_id > 0 then
			for uid in pairs(dat._members or {}) do
				local user_id = tonumber(uid)
				if user_id then
					alliance_of[user_id] = alliance_id
				end
			end
		end
	end
end

local function hostile(a, b)
	if a.user_id == b.user_id then
		return false
	end
	local aa = alliance_of[a.user_id]
	local bb = alliance_of[b.user_id]
	if aa and aa > 0 and aa == bb then
		return false
	end
	return true
end

local function troop_key(e)
	return e.user_id .. ":" .. e.troop_idx
end

local function cell_key(x, y)
	return x * CELL + y
end

function unindex(e)
	local k = where[e.id]
	if not k then
		return
	end
	local bucket = cells[k]
	if bucket and bucket[e.id] == e then
		bucket[e.id] = nil
		where[e.id] = nil
		if not next(bucket) then
			cells[k] = nil
		end
	end
end

function index_at(e, x, y)
	local old = where[e.id]
	if old then
		local bucket = cells[old]
		if bucket then
			bucket[e.id] = nil
			if not next(bucket) then
				cells[old] = nil
			end
		end
		where[e.id] = nil
	end
	local k = cell_key(x, y)
	local bucket = cells[k]
	if not bucket then
		bucket = {}
		cells[k] = bucket
	end
	bucket[e.id] = e
	where[e.id] = k
	e.cell_x = x
	e.cell_y = y
	local fled = flee[troop_key(e)]
	if fled and fled ~= k then
		flee[troop_key(e)] = nil
	end
end

function clear_flee(e)
	flee[troop_key(e)] = nil
end

function note_flee(e)
	local k = where[e.id]
	local bucket = k and cells[k]
	if bucket and bucket[e.id] == e then
		flee[troop_key(e)] = k
	end
end

local function remember_move(e)
	if e.was_moving == nil then
		e.was_moving = e.moving and true or false
	end
end

local function hold(e, x, y)
	remember_move(e)
	e.waiting = true
	e.moving = false
	e.hold_x = x
	e.hold_y = y
	e.x = x
	e.y = y
end

local function lock_pair(atk, def, x, y)
	remember_move(atk)
	remember_move(def)
	battle_seq = battle_seq + 1
	atk.battle_gen = battle_seq
	def.battle_gen = battle_seq
	atk.fighting = true
	def.fighting = true
	atk.waiting = false
	def.waiting = false
	atk.moving = false
	def.moving = false
	atk.hold_x, atk.hold_y = x, y
	def.hold_x, def.hold_y = x, y
	atk.x, atk.y = x, y
	def.x, def.y = x, y
	return battle_seq
end

-- 这一格里另一个玩家。刚在这格打输的先走开，不在原地再打一次。同一格多个时取 id 小的
function foe_of(e)
	local k = where[e.id]
	if not k or flee[troop_key(e)] == k then
		return
	end
	local bucket = cells[k]
	if not bucket then
		return
	end
	local foe
	for _, other in pairs(bucket) do
		if hostile(e, other) and (not foe or other.id < foe.id) then
			foe = other
		end
	end
	return foe
end

local function pin_others(atk, def, x, y, stops)
	local bucket = cells[where[atk.id]]
	if not bucket then
		return
	end
	local extra = {}
	for _, other in pairs(bucket) do
		extra[#extra + 1] = other
	end
	for _, other in ipairs(extra) do
		if other ~= atk and other ~= def and (hostile(other, atk) or hostile(other, def)) and not other.fighting and not other.waiting then
			hold(other, x, y)
			stops[#stops + 1] = other
		end
	end
end

local function meet(e, foe, x, y, fights, stops)
	if foe.fighting or foe.waiting then
		hold(e, x, y)
		stops[#stops + 1] = e
		return
	end
	local gen = lock_pair(e, foe, x, y)
	pin_others(e, foe, x, y, stops)
	fights[#fights + 1] = {atk = e, def = foe, x = x, y = y, gen = gen}
end

-- 出发或重进地图时，脚下这格已经有人就立刻打
function touch(e)
	local foe = foe_of(e)
	if not foe then
		return
	end
	local fights, stops = {}, {}
	meet(e, foe, e.cell_x, e.cell_y, fights, stops)
	return fights[1], stops
end

-- 这场没打成时，把堵在格子里的部队放走。格子上还有人在打就先不动
function release_cell(x, y)
	local bucket = cells[cell_key(x, y)]
	if not bucket then
		return {}
	end
	for _, e in pairs(bucket) do
		if e.fighting then
			return {}
		end
	end
	local freed = {}
	for _, e in pairs(bucket) do
		if e.waiting then
			e.waiting = false
			freed[#freed + 1] = e
		end
	end
	return freed
end

-- 这一拍里还在走的部队。返回要开打的一对，以及被堵住、先停下来的部队
function advance(list, now)
	local events = {}
	for _, e in ipairs(list) do
		if e.moving and not e.fighting and not e.waiting and e.path and e.start_time and e.end_time then
			local from = e.scan_time or e.start_time
			if now > from then
				local crossed = MARCH_PATH.cells_crossed(e.path, e.start_time, e.end_time, from, now)
				e.scan_time = now
				if crossed[1] and (e.cell_x ~= crossed[1].x or e.cell_y ~= crossed[1].y) then
					if e.cell_x then
						events[#events + 1] = {t = crossed[1].enter, kind = EV.LEAVE, e = e, x = e.cell_x, y = e.cell_y}
					end
					events[#events + 1] = {t = crossed[1].enter, kind = EV.ENTER, e = e, x = crossed[1].x, y = crossed[1].y}
				end
				for i = 2, #crossed do
					local prev = crossed[i - 1]
					events[#events + 1] = {t = prev.leave, kind = EV.LEAVE, e = e, x = prev.x, y = prev.y}
					events[#events + 1] = {t = crossed[i].enter, kind = EV.ENTER, e = e, x = crossed[i].x, y = crossed[i].y}
				end
			end
		end
	end
	table.sort(events, function(a, b)
		if a.t ~= b.t then
			return a.t < b.t
		end
		if a.kind ~= b.kind then
			return a.kind < b.kind
		end
		return a.e.id < b.e.id
	end)
	local fights, stops = {}, {}
	for _, ev in ipairs(events) do
		local e = ev.e
		if not e.fighting and not e.waiting then
			if ev.kind == EV.LEAVE then
				if e.cell_x == ev.x and e.cell_y == ev.y then
					unindex(e)
				end
			else
				index_at(e, ev.x, ev.y)
				local foe = foe_of(e)
				if foe then
					meet(e, foe, ev.x, ev.y, fights, stops)
				end
			end
		end
	end
	return fights, stops
end

-- 这一场打完。输的离开格子；格子里还有别的玩家就接着打，返回下一场
function conclude(atk, def, gen, atk_win)
	if atk.battle_gen ~= gen or def.battle_gen ~= gen then
		return
	end
	atk.battle_gen = nil
	def.battle_gen = nil
	atk.fighting = false
	def.fighting = false
	local winner = atk_win and atk or def
	local loser = atk_win and def or atk
	note_flee(loser)
	unindex(loser)
	local foe = foe_of(winner)
	if foe and not foe.fighting then
		local stops = {}
		local chain_gen = lock_pair(winner, foe, winner.hold_x, winner.hold_y)
		pin_others(winner, foe, winner.hold_x, winner.hold_y, stops)
		return {
			chain = {atk = winner, def = foe, x = winner.hold_x, y = winner.hold_y, gen = chain_gen},
			stops = stops,
		}
	end
	return {}
end
