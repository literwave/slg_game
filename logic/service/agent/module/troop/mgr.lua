local skynet = require "skynet"

all_user_troop_tbl = {}

function ref_troop(troop)
	local user_id = troop:get_user_id()
	if not all_user_troop_tbl[user_id] then
		all_user_troop_tbl[user_id] = {}
	end
	all_user_troop_tbl[user_id][troop:get_troop_idx()] = troop
end

local function create_troop(oci)
	return TROOP_BASE.cls_troop:New(oci)
end

local function try_init_user_troops(user_id)
	local doc = ORM.load(MONGO_SLAVE.COL.USER_TROOP, user_id, ORM.CLS_USER_TROOP_DOC)
	if not all_user_troop_tbl[user_id] then
		all_user_troop_tbl[user_id] = {}
		for _, troop_data in pairs(doc._troops) do
			create_troop(troop_data)
		end
	end
	return all_user_troop_tbl[user_id]
end

function get_user_troops(user_id)
	return try_init_user_troops(user_id)
end

function get_troop(user_id, troop_idx)
	local troop_tbl = try_init_user_troops(user_id)
	return troop_tbl[troop_idx]
end

function on_user_logout(user_id)
	if ORM.get(MONGO_SLAVE.COL.USER_TROOP, user_id) then
		MONGO_SLAVE.flush()
		all_user_troop_tbl[user_id] = nil
		ORM.unbind(MONGO_SLAVE.COL.USER_TROOP, user_id)
	end
end

local function num(v)
	return tonumber(v) or 0
end

-- pbc 把 map 解成 {key, value} 数组，也兼容直接用站位当 key 的表
local function parse_pos_list(pos_map)
	local list = {}
	if not pos_map then
		return list
	end
	local function add_slot(pos, value)
		value = value or {}
		local soldier = value.soldier or {}
		list[#list + 1] = {
			pos = math.floor(num(pos)),
			hero_idx = math.floor(num(value.heroIdx)),
			healthy = math.floor(num(soldier.count)),
		}
	end
	local first = pos_map[1]
	if first and first.key ~= nil then
		for _, entry in ipairs(pos_map) do
			add_slot(entry.key, entry.value)
		end
		return list
	end
	for pos, value in pairs(pos_map) do
		add_slot(pos, value)
	end
	return list
end

local function sync_all_troop(fd, user_id)
	local troop_list = {}
	for _, troop in pairs(get_user_troops(user_id)) do
		troop_list[#troop_list + 1] = troop:get_pto_info()
	end
	for_caller.s2c_req_troop(fd, {
		troopList = troop_list,
	})
end

local function on_req_troop(fd)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	sync_all_troop(fd, user_id)
end

local function on_edit_troop(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local troop_info = packet.troopInfo
	if not troop_info then
		return
	end
	local user_id = user:get_user_id()
	local troop_idx = math.floor(num(troop_info.troopIdx))
	if troop_idx < 1 or troop_idx > DATA_COMMON.get_troop_max_cnt() then
		USER_MGR.tell_me(user_id, "部队编号无效")
		return
	end
	local pos_list = parse_pos_list(troop_info.posMap)
	local troops = get_user_troops(user_id)
	local troop = troops[troop_idx]
	if troop and troop:is_marching() then
		USER_MGR.tell_me(user_id, "部队在城外")
		return
	end
	local pos_cnt = DATA_COMMON.get_troop_pos_cnt()
	local used_hero = {}
	local used_pos = {}
	for _, info in ipairs(pos_list) do
		if info.hero_idx < 1 or not HERO_MGR.get_hero_by_type(user_id, info.hero_idx) then
			USER_MGR.tell_me(user_id, "没有这个武将")
			return
		end
		if info.pos < 1 or info.pos > pos_cnt then
			USER_MGR.tell_me(user_id, "站位无效")
			return
		end
		if used_pos[info.pos] or used_hero[info.hero_idx] then
			USER_MGR.tell_me(user_id, "武将或站位重复")
			return
		end
		if info.healthy < 0 then
			USER_MGR.tell_me(user_id, "兵力无效")
			return
		end
		used_hero[info.hero_idx] = true
		used_pos[info.pos] = true
	end
	-- 可用兵力在城池和这支部队之间调。伤兵跟着武将走，客户端传 0 也不会把伤兵清掉
	local pool = user:get_soldier_cnt()
	if troop then
		for _, info in pairs(troop:get_pos_tbl()) do
			local healthy, hurt = troop:slot_healthy(info)
			pool = pool + healthy
			if not used_hero[info._hero_idx] then
				pool = pool + hurt
			end
		end
	end
	local strips = {}
	local need = 0
	for _, info in ipairs(pos_list) do
		need = need + info.healthy
		info.hurt = 0
		for idx, other in pairs(troops) do
			local pos, pinfo = other:find_hero(info.hero_idx)
			if pos then
				local healthy, hurt = other:slot_healthy(pinfo)
				info.hurt = hurt
				if idx ~= troop_idx then
					if other:is_marching() then
						USER_MGR.tell_me(user_id, "武将正在行军")
						return
					end
					pool = pool + healthy
					strips[#strips + 1] = {troop = other, pos = pos}
				end
				break
			end
		end
	end
	if need > pool then
		USER_MGR.tell_me(user_id, "兵力不足")
		return
	end
	for _, strip in ipairs(strips) do
		strip.troop:set_pos(strip.pos, nil)
	end
	if not troop and #pos_list > 0 then
		troop = create_troop({
			_user_id = user_id,
			_troop_idx = troop_idx,
		})
	end
	if troop then
		troop:clear_pos()
		for _, info in ipairs(pos_list) do
			troop:set_pos(info.pos, info.hero_idx, info.healthy + info.hurt, info.hurt)
		end
	end
	user:set_soldier_cnt(pool - need)
	user:sync_soldier()
	if user:has_birth_pos() then
		local seen = {}
		local function sync_map(one)
			if not one or one:get_march_state() ~= 0 or seen[one:get_troop_idx()] then
				return
			end
			seen[one:get_troop_idx()] = true
			local world = skynet.localname(".world")
			skynet.call(world, "lua", "hide_troop", user_id, one:get_troop_idx())
		end
		sync_map(troop)
		for _, strip in ipairs(strips) do
			sync_map(strip.troop)
		end
	end
	local pto = troop and troop:get_pto_info() or {troopIdx = troop_idx, posMap = {}}
	for_caller.s2c_edit_troop(fd, {troopInfo = pto})
	if #strips > 0 then
		sync_all_troop(fd, user_id)
	end
end

function __init__()
	for_maker.c2s_req_troop = on_req_troop
	for_maker.c2s_edit_troop = on_edit_troop
	EVENT.listen(CONST.EVENT.ON_USER_LOGOUT)
	local world = skynet.localname(".world")
	if not world then
		return
	end
	for user_id, troops in pairs(all_user_troop_tbl) do
		for _, troop in pairs(troops) do
			if troop:get_march_state() == 0 then
				skynet.call(world, "lua", "hide_troop", user_id, troop:get_troop_idx())
			end
		end
	end
end
