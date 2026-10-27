local skynet = require "skynet"
local navigation = require "navigation"

local MAP_DIR = "../res/map/"

map_obj = nil
-- 山河障碍，给每个联盟的寻路图当底图
terrain_obstacles = nil
-- 没联盟：别人的主城都是障碍。自己的主城在寻路时临时放开，才能出城和回城
nav_alone = nil
-- [alliance_id] = 寻路图。本联盟主城不挡，其它联盟和没联盟的主城都挡
nav_of_alliance = nav_of_alliance or {}
-- [user_id] = {x, y}，主城中心。占地 3×3，热更保留
city_pos = city_pos or {}
map_revision = nil

local nav_batch = 0
local dirty_nav = {}
-- 非空地的格子：cellId -> type * 256 + level。空地和山河不放进来
cell_pack = {}
land_by_key = {}

local function idx_to_pos(idx, w)
	local linear = idx - 1
	return {
		x = linear % w,
		y = linear // w,
	}
end

local function pos_to_idx(pos, w)
	return math.floor(pos.y) * w + math.floor(pos.x) + 1
end

-- 已经落库的出生点占住，避免重启后分到同一格
local function load_used_birth()
	local all = MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.USER_INFO)
	local w = map_obj:get_width()
	for _, dat in pairs(all) do
		if dat._has_birth then
			local idx = pos_to_idx({x = dat._birth_x, y = dat._birth_y}, w)
			assert(map_obj:hold_birth_idx(idx), string.format("birth pos blocked %s %s,%s", dat._user_id, dat._birth_x, dat._birth_y))
		end
	end
end

local function cell_id_of(x, y, w)
	return y * w + x
end

local function land_type_of(cell_type)
	if cell_type == CONST.MAP_CELL_TYPE.GRAIN then
		return DATA_COMMON.RES_LAND_TYPE.GRAIN
	elseif cell_type == CONST.MAP_CELL_TYPE.WOOD then
		return DATA_COMMON.RES_LAND_TYPE.WOOD
	elseif cell_type == CONST.MAP_CELL_TYPE.IRON then
		return DATA_COMMON.RES_LAND_TYPE.IRON
	elseif cell_type == CONST.MAP_CELL_TYPE.STONE then
		return DATA_COMMON.RES_LAND_TYPE.STONE
	end
end

local function index_land_cfg()
	land_by_key = {}
	for id, conf in pairs(DATA_COMMON.get_res_land_tbl()) do
		land_by_key[conf.Type * 100 + conf.Level] = id
	end
end

function init()
	local manifest = dofile(MAP_DIR .. "manifest.lua")
	local map_res = dofile(MAP_DIR .. "mapRes_0.lua")
	local terrain = dofile(MAP_DIR .. "terrain.lua")
	assert(map_res and map_res.w and map_res.h and map_res.list and map_res.emptyCells, "load mapRes_0 failed")
	assert(manifest.width == map_res.w and manifest.height == map_res.h, "map size mismatch")
	local w, h = map_res.w, map_res.h
	assert(w == CONST.MAP_SIDE and h == CONST.MAP_SIDE, "map side mismatch")
	map_obj = MAP_BASE.cls_map:New({
		_width = w,
		_height = h,
	})
	map_revision = manifest.mapRevision

	local obstacles = {}
	local block_cnt = 0
	for _, cell_id in ipairs(terrain.blockedCells) do
		if map_obj:set_block(cell_id + 1) then
			block_cnt = block_cnt + 1
			obstacles[#obstacles + 1] = { cell_id % w, cell_id // w }
		end
	end

	-- 不是山河阻挡就能落城，不再只从预置出生点里挑
	local birth_cnt = 0
	for idx = 1, w * h do
		if map_obj:allow_birth(idx) then
			birth_cnt = birth_cnt + 1
		end
	end

	index_land_cfg()
	cell_pack = {}
	local land_cnt = 0
	for cell_id, cell in pairs(map_res.list) do
		local cell_type = cell[1]
		if cell_type ~= 0 then
			cell_pack[cell_id] = cell_type * 256 + cell[2]
			local land_type = land_type_of(cell_type)
			if land_type and land_by_key[land_type * 100 + cell[2]] then
				land_cnt = land_cnt + 1
			end
		end
	end
	map_res.list = nil
	map_res = nil
	terrain = nil

	terrain_obstacles = obstacles
	nav_of_alliance = {}
	nav_alone = navigation.new(w, h, terrain_obstacles)
	obstacles = nil
	load_used_birth()
	collectgarbage("collect")
	LOG._debug("world map init %d %d rev %s block %d birth %d land %d mem %.0fKb",
		w, h, map_revision, block_cnt, birth_cnt, land_cnt, collectgarbage("count"))
end

function get_map()
	return map_obj
end

function is_block(idx)
	return map_obj:is_block(idx)
end

function pos_of_idx(idx)
	return idx_to_pos(idx, map_obj:get_width())
end

function idx_of_pos(x, y)
	return pos_to_idx({x = x, y = y}, map_obj:get_width())
end

function alloc_birth_pos()
	local idx = map_obj:alloc_birth_idx()
	if not idx then
		return
	end
	return idx_to_pos(idx, map_obj:get_width())
end

function alloc_wild_idx()
	return map_obj:alloc_wild_idx()
end

function cell_info(x, y)
	local w = map_obj:get_width()
	local h = map_obj:get_height()
	x, y = math.floor(x), math.floor(y)
	if x < 0 or y < 0 or x >= w or y >= h then
		return
	end
	local packed = cell_pack[cell_id_of(x, y, w)]
	if not packed then
		return 0, 0
	end
	return packed // 256, packed % 256
end

function land_id_at(x, y)
	local cell_type, level = cell_info(x, y)
	local land_type = cell_type and land_type_of(cell_type)
	if not land_type then
		return
	end
	return land_by_key[land_type * 100 + level]
end

-- 先占新格子，成功再放开旧格子。新格子越界、不能落城或已被占用时旧格子不动
function relocate_birth(old_x, old_y, x, y)
	x, y = math.floor(x), math.floor(y)
	old_x, old_y = math.floor(old_x), math.floor(old_y)
	return map_obj:relocate_birth(idx_of_pos(old_x, old_y), idx_of_pos(x, y))
end

local function owner_alliance(user_id)
	local alliance_id = ENCOUNTER_MGR.alliance_of[user_id]
	if alliance_id and alliance_id > 0 then
		return alliance_id
	end
end

local function mark_nav(nav)
	dirty_nav[nav] = true
end

local function flush_nav()
	if nav_batch > 0 then
		return
	end
	for nav in pairs(dirty_nav) do
		nav:update_areas()
		dirty_nav[nav] = nil
	end
end

-- 起服时主城是一批放进来的，分区只在整批结束时重算一次
function begin_nav_batch()
	nav_batch = nav_batch + 1
end

function end_nav_batch()
	if nav_batch > 0 then
		nav_batch = nav_batch - 1
	end
	flush_nav()
end

-- 主城以出生点为中心，半径 1，共 3×3。山河格子本来就挡，不再重复写
local function each_city_cell(pos, fn)
	local w, h = map_obj:get_width(), map_obj:get_height()
	for dy = -1, 1 do
		for dx = -1, 1 do
			local x, y = pos.x + dx, pos.y + dy
			if x >= 0 and y >= 0 and x < w and y < h and not map_obj:is_block(idx_of_pos(x, y)) then
				fn(x, y)
			end
		end
	end
end

-- alliance_id 为空表示没联盟的那张图：任何主城都挡。否则只有不是这个联盟的主城才挡
local function cell_blocked(alliance_id, x, y)
	for uid, pos in pairs(city_pos) do
		if math.abs(pos.x - x) <= 1 and math.abs(pos.y - y) <= 1 then
			if not alliance_id or owner_alliance(uid) ~= alliance_id then
				return true
			end
		end
	end
end

local function sync_footprint(nav, pos, alliance_id)
	each_city_cell(pos, function(x, y)
		local cell = {x = x, y = y}
		if cell_blocked(alliance_id, x, y) then
			nav:set_obstacle(cell)
		else
			nav:unset_obstacle(cell)
		end
	end)
	mark_nav(nav)
end

-- 本联盟的主城九格都不挡。其它联盟、没联盟的主城九格都挡
local function build_alliance_nav(alliance_id)
	local nav = navigation.new(map_obj:get_width(), map_obj:get_height(), terrain_obstacles)
	for _, pos in pairs(city_pos) do
		each_city_cell(pos, function(x, y)
			if cell_blocked(alliance_id, x, y) then
				nav:set_obstacle({x = x, y = y})
			end
		end)
	end
	nav:update_areas()
	nav_of_alliance[alliance_id] = nav
	return nav
end

-- 这一格落在谁的主城 3×3 里
function city_of(x, y)
	x, y = math.floor(x), math.floor(y)
	for user_id, pos in pairs(city_pos) do
		if math.abs(x - pos.x) <= 1 and math.abs(y - pos.y) <= 1 then
			return user_id
		end
	end
end

-- 主城落点或迁城
function set_city(user_id, x, y)
	if not nav_alone then
		return
	end
	x, y = math.floor(x), math.floor(y)
	local old = city_pos[user_id]
	if old and old.x == x and old.y == y then
		return
	end
	local pos = {x = x, y = y}
	city_pos[user_id] = pos
	local function sync(nav, alliance_id)
		if old then
			sync_footprint(nav, old, alliance_id)
		end
		sync_footprint(nav, pos, alliance_id)
	end
	sync(nav_alone, nil)
	for id, nav in pairs(nav_of_alliance) do
		sync(nav, id)
	end
	flush_nav()
end

-- 加入联盟后，自己的九格不再挡本联盟。离开后，九格重新挡原来的联盟
function on_user_alliance(user_id, old_id, new_id)
	local pos = city_pos[user_id]
	if not pos then
		return
	end
	if old_id and old_id > 0 and old_id ~= new_id then
		local nav = nav_of_alliance[old_id]
		if nav then
			sync_footprint(nav, pos, old_id)
		end
	end
	if new_id and new_id > 0 and new_id ~= old_id then
		local nav = nav_of_alliance[new_id]
		if nav then
			sync_footprint(nav, pos, new_id)
		end
	end
	flush_nav()
end

-- 行军拐点（JPS + 平滑），含起点和终点。不可达返回 nil
-- 有联盟：本联盟主城可过，其它主城是障碍。没联盟：除了自己的主城，别人的主城都是障碍
function find_march_path(user_id, sx, sy, ex, ey)
	local w, h = map_obj:get_width(), map_obj:get_height()
	if ex < 0 or ey < 0 or ex >= w or ey >= h then
		return
	end
	local alliance_id = owner_alliance(user_id)
	local nav
	local ignore
	if alliance_id then
		nav = nav_of_alliance[alliance_id] or build_alliance_nav(alliance_id)
	else
		nav = nav_alone
		local mine = city_pos[user_id]
		if mine then
			ignore = {}
			each_city_cell(mine, function(x, y)
				ignore[#ignore + 1] = {x = x, y = y}
			end)
		end
	end
	local path = nav:find_path({x = sx, y = sy}, {x = ex, y = ey}, nil, ignore)
	if not path or #path < 2 then
		return
	end
	local ret = {}
	for i, pos in ipairs(path) do
		ret[i] = {_x = pos.x, _y = pos.y}
	end
	return ret
end
