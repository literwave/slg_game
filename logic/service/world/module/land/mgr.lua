-- 资源地和空地都能占领。中立的不进实体、不落库，占下来才存盘并放进视野
-- 资源地采空后还在，过一段时间补回储量。空地没有储量，cfg_id 为 0

local skynet = require "skynet"

local DIRS = {
	{1, 0},
	{-1, 0},
	{0, 1},
	{0, -1},
}

-- [cell] = land_data。热更保留
owned = owned or {}
local gather_token = {}
local refill_token = {}
local occupy_token = {}

local function agent_of(user_id)
	local list = skynet.call(".gated", "lua", "get_agent_list")
	local n = list and #list or 0
	if n < 1 then
		return
	end
	return list[user_id % n + 1]
end

local function show(cell, doc)
	local x, y = cell % CONST.MAP_SIDE, math.floor(cell / CONST.MAP_SIDE)
	local occupy_end = doc._occupy_end or 0
	AOI_MGR.upsert_land({
		id = CONST.ENTITY_ID.RES_LAND + cell,
		x = x,
		y = y,
		cfg_id = doc._cfg_id,
		owner_id = doc._owner_id,
		troop_idx = doc._troop_idx,
		remain = doc._remain,
		occupy_start = occupy_end > 0 and occupy_end - DATA_COMMON.get_occupy_seconds() or 0,
		occupy_end = occupy_end,
	})
end

local function arm_refill(cell, doc)
	local token = {}
	refill_token[cell] = token
	local wait = math.max(0, doc._refill_at - TIME.os_bj_sec())
	skynet.timeout(math.floor(wait * 100) + 1, function()
		if refill_token[cell] ~= token or owned[cell] ~= doc then
			return
		end
		local conf = DATA_COMMON.get_res_land_conf(doc._cfg_id)
		if not conf then
			return
		end
		doc._remain = conf.Capacity
		doc._refill_at = 0
		refill_token[cell] = nil
	end)
end

local function arm_gather(cell, doc)
	local token = {}
	gather_token[cell] = token
	local user_id = doc._owner_id
	local troop_idx = doc._troop_idx
	local end_time = doc._gather_end
	local wait = math.max(0, end_time - TIME.os_bj_sec())
	skynet.timeout(math.floor(wait * 100) + 1, function()
		if gather_token[cell] ~= token or owned[cell] ~= doc then
			return
		end
		if doc._gather_end ~= end_time or doc._troop_idx ~= troop_idx then
			return
		end
		local agent = agent_of(user_id)
		if agent then
			skynet.send(agent, "lua", "gather_full", user_id, troop_idx, end_time)
		end
	end)
end

local function full_seconds(conf)
	local speed = conf.GatherSpeed
	if speed < 1 then
		speed = 1
	end
	return math.max(1, math.ceil(conf.Capacity * CONST.ONE_HOUR_SEC / speed))
end

-- 能走上去的草地。山河和系统城池不算
local function empty_cell(x, y)
	local cell_type = MAP_MGR.cell_info(x, y)
	if cell_type ~= 0 then
		return false
	end
	return not MAP_MGR.is_block(MAP_MGR.idx_of_pos(x, y))
end

function info(entity_id)
	local x, y = CONST.res_land_xy(entity_id)
	if x == nil then
		return
	end
	local cfg_id = MAP_MGR.land_id_at(x, y)
	local conf = cfg_id and DATA_COMMON.get_res_land_conf(cfg_id)
	local empty = not conf and empty_cell(x, y)
	if not conf and not empty then
		return
	end
	local cell = CONST.res_land_cell(x, y)
	local doc = owned[cell]
	if doc then
		return {
			x = x,
			y = y,
			cfg_id = doc._cfg_id,
			owner_id = doc._owner_id or 0,
			troop_idx = doc._troop_idx or 0,
			remain = doc._remain or 0,
			pending_owner = doc._pending_owner or 0,
			occupy_end = doc._occupy_end or 0,
			covered = MAP_MGR.city_of(x, y) ~= nil,
		}
	end
	return {
		x = x,
		y = y,
		cfg_id = conf and cfg_id or 0,
		owner_id = 0,
		troop_idx = 0,
		remain = conf and conf.Capacity or 0,
		pending_owner = 0,
		occupy_end = 0,
		covered = MAP_MGR.city_of(x, y) ~= nil,
	}
end

-- 上下左右挨着自己的主城九格，或自己已经占的地。斜角不算
function connected(user_id, x, y)
	x, y = math.floor(x), math.floor(y)
	for _, d in ipairs(DIRS) do
		local nx, ny = x + d[1], y + d[2]
		if nx >= 0 and ny >= 0 and nx < CONST.MAP_SIDE and ny < CONST.MAP_SIDE then
			if MAP_MGR.city_of(nx, ny) == user_id then
				return true
			end
			local doc = owned[CONST.res_land_cell(nx, ny)]
			if doc and doc._owner_id == user_id then
				return true
			end
		end
	end
	return false
end

local function start_gather(cell, doc)
	local conf = DATA_COMMON.get_res_land_conf(doc._cfg_id)
	if not conf then
		return 0
	end
	local cost = math.ceil(doc._remain * CONST.ONE_HOUR_SEC / math.max(1, conf.GatherSpeed))
	local end_time = TIME.os_bj_sec() + math.max(1, cost)
	doc._gather_end = end_time
	arm_gather(cell, doc)
	return end_time
end

local function finish_occupy(cell, doc)
	local user_id = doc._pending_owner
	local troop_idx = doc._troop_idx
	if not user_id or user_id == 0 or not troop_idx or troop_idx == 0 then
		return
	end
	doc._owner_id = user_id
	doc._pending_owner = 0
	doc._occupy_end = 0
	occupy_token[cell] = nil
	local gather_end = 0
	if doc._cfg_id ~= 0 then
		gather_end = start_gather(cell, doc)
	end
	show(cell, doc)
	local agent = agent_of(user_id)
	if agent then
		skynet.send(agent, "lua", "occupy_done", user_id, troop_idx, gather_end)
	end
end

local function arm_occupy(cell, doc)
	local token = {}
	occupy_token[cell] = token
	local user_id = doc._pending_owner
	local troop_idx = doc._troop_idx
	local end_time = doc._occupy_end
	local wait = math.max(0, end_time - TIME.os_bj_sec())
	skynet.timeout(math.floor(wait * 100) + 1, function()
		if occupy_token[cell] ~= token or owned[cell] ~= doc then
			return
		end
		if doc._occupy_end ~= end_time or doc._troop_idx ~= troop_idx or doc._pending_owner ~= user_id then
			return
		end
		finish_occupy(cell, doc)
	end)
end

local function drop_pending(cell, doc)
	occupy_token[cell] = nil
	owned[cell] = nil
	ORM.unbind(MONGO_SLAVE.COL.LAND, cell)
	MONGO_SLAVE.del_doc(MONGO_SLAVE.COL.LAND, cell)
	AOI_MGR.remove_land(CONST.ENTITY_ID.RES_LAND + cell)
	doc._troop_idx = 0
end

-- 已经是自己的地：资源地接着采，空地留在原地。中立地只进入倒计时，到点才写入归属
function occupy(entity_id, user_id, troop_idx)
	local view = info(entity_id)
	local empty = view and view.cfg_id == 0
	if not view or view.covered or (not empty and view.remain <= 0) then
		return
	end
	if view.owner_id ~= 0 and view.owner_id ~= user_id then
		return
	end
	if view.owner_id == 0 and not connected(user_id, view.x, view.y) then
		return
	end
	if view.troop_idx ~= 0 and view.troop_idx ~= troop_idx then
		return
	end
	local conf = not empty and DATA_COMMON.get_res_land_conf(view.cfg_id)
	if not empty and not conf then
		return
	end
	local cell = CONST.res_land_cell(view.x, view.y)
	local doc = owned[cell]
	if view.owner_id == user_id then
		if not doc then
			return
		end
		doc._troop_idx = troop_idx
		doc._pending_owner = 0
		doc._occupy_end = 0
		doc._refill_at = 0
		refill_token[cell] = nil
		occupy_token[cell] = nil
		if empty then
			doc._gather_end = 0
			gather_token[cell] = nil
			show(cell, doc)
			return nil, true
		end
		local end_time = start_gather(cell, doc)
		show(cell, doc)
		return end_time
	end
	if (view.pending_owner or 0) ~= 0 and view.pending_owner ~= user_id then
		return
	end
	if not doc then
		doc = ORM.new(ORM.CLS_LAND_DATA, {
			_owner_id = 0,
			_cfg_id = view.cfg_id,
			_remain = view.remain,
			_troop_idx = troop_idx,
			_gather_end = 0,
			_refill_at = 0,
			_pending_owner = user_id,
			_occupy_end = 0,
		})
		ORM.bind(doc, MONGO_SLAVE.COL.LAND, cell)
		ORM.touch(doc)
		owned[cell] = doc
	end
	local occupy_end = TIME.os_bj_sec() + DATA_COMMON.get_occupy_seconds()
	doc._owner_id = 0
	doc._pending_owner = user_id
	doc._troop_idx = troop_idx
	doc._occupy_end = occupy_end
	doc._gather_end = 0
	doc._refill_at = 0
	gather_token[cell] = nil
	refill_token[cell] = nil
	if empty then
		doc._cfg_id = 0
		doc._remain = 0
	end
	arm_occupy(cell, doc)
	show(cell, doc)
	return nil, true, occupy_end
end

-- 部队离开：扣储量，归属留下。采空后按采满一整块的时间补回
function leave(entity_id, user_id, troop_idx, gathered)
	local x, y = CONST.res_land_xy(entity_id)
	if not x then
		return
	end
	local cell = CONST.res_land_cell(x, y)
	local doc = owned[cell]
	if not doc or doc._troop_idx ~= troop_idx then
		return
	end
	if (doc._owner_id or 0) == 0 and (doc._pending_owner or 0) == user_id then
		drop_pending(cell, doc)
		return 0
	end
	if doc._owner_id ~= user_id then
		return
	end
	local real = math.min(math.max(0, gathered), doc._remain)
	doc._remain = doc._remain - real
	doc._troop_idx = 0
	doc._gather_end = 0
	gather_token[cell] = nil
	if doc._cfg_id ~= 0 and doc._remain <= 0 then
		local conf = DATA_COMMON.get_res_land_conf(doc._cfg_id)
		doc._remain = 0
		doc._refill_at = TIME.os_bj_sec() + (conf and full_seconds(conf) or CONST.ONE_HOUR_SEC)
		arm_refill(cell, doc)
	end
	show(cell, doc)
	return real
end

function init()
	local now = TIME.os_bj_sec()
	for key, dat in pairs(MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.LAND)) do
		local cell = tonumber(key)
		if cell and dat then
			local doc = ORM.get(MONGO_SLAVE.COL.LAND, cell)
			if not doc then
				doc = ORM.new(ORM.CLS_LAND_DATA, dat)
				ORM.bind(doc, MONGO_SLAVE.COL.LAND, cell)
			end
			owned[cell] = doc
			show(cell, doc)
			local occupy_end = doc._occupy_end or 0
			if occupy_end > now and (doc._pending_owner or 0) ~= 0 then
				arm_occupy(cell, doc)
			elseif occupy_end > 0 and (doc._pending_owner or 0) ~= 0 then
				finish_occupy(cell, doc)
			end
			if doc._refill_at > now then
				arm_refill(cell, doc)
			elseif doc._refill_at > 0 then
				local conf = DATA_COMMON.get_res_land_conf(doc._cfg_id)
				if conf then
					doc._remain = conf.Capacity
				end
				doc._refill_at = 0
			end
			if doc._troop_idx > 0 and doc._gather_end > now then
				arm_gather(cell, doc)
			elseif doc._troop_idx > 0 and doc._gather_end > 0 and doc._gather_end <= now then
				local agent = agent_of(doc._owner_id)
				if agent then
					skynet.send(agent, "lua", "gather_full", doc._owner_id, doc._troop_idx, doc._gather_end)
				end
			end
		end
	end
end
