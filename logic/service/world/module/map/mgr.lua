local skynet = require "skynet"
local navigation = require "navigation"

local MAP_DIR = "../res/map/"

map_obj = nil
nav_obj = nil
map_revision = nil
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

	nav_obj = navigation.new(w, h, obstacles)
	obstacles = nil
	load_used_birth()
	collectgarbage("collect")
	skynet.error(string.format(
		"world map init %d %d rev %s block %d birth %d land %d mem %.0fKb",
		w, h, map_revision, block_cnt, birth_cnt, land_cnt, collectgarbage("count")))
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

-- 行军拐点（JPS + 平滑），含起点和终点。不可达返回 nil
function find_march_path(sx, sy, ex, ey)
	local w, h = map_obj:get_width(), map_obj:get_height()
	if ex < 0 or ey < 0 or ex >= w or ey >= h then
		return
	end
	local path = nav_obj:find_path({x = sx, y = sy}, {x = ex, y = ey})
	if #path < 2 then
		return
	end
	local ret = {}
	for i, pos in ipairs(path) do
		ret[i] = {_x = pos.x, _y = pos.y}
	end
	return ret
end
