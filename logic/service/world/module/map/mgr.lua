local skynet = require "skynet"
local navigation = require "navigation"
local world_map_package = require "world_map_package"
local city_siege = require "city_siege"

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
alliance_cities = alliance_cities or {}
-- 系统城池/关隘归属参与寻路；0 为中立，只有本盟占领后才可穿行。
alliance_city_owners = alliance_city_owners or {}

local nav_batch = 0
local dirty_nav = {}
-- Fixed-size LRU of native navigation buffers. Reuse buffers on eviction:
-- their malloc allocations are not counted by Lua's incremental GC.
local nav_limit = tonumber(skynet.getenv("world_nav_cache_limit")) or 4
assert(nav_limit >= 1 and nav_limit <= 32 and nav_limit % 1 == 0, "invalid world_nav_cache_limit")
nav_used = nav_used or {}
nav_clock = nav_clock or 0
cell_occupants = cell_occupants or {}
landmark_by_id = landmark_by_id or {}
passable_by_alliance = passable_by_alliance or {}
local navigation_busy = false

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
local function load_used_birth(all)
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
	local expected_revision = skynet.getenv("map_revision")
	local directory = MAP_DIR
	if expected_revision and expected_revision ~= "" then
		assert(#expected_revision == 64 and expected_revision:match("^[0-9a-f]+$"), "invalid configured map revision")
		directory = (skynet.getenv("map_package_root") or "../build/maps") .. "/" .. expected_revision .. "/server"
	else
		expected_revision = nil
	end
	local manifest, map_res, terrain, campaign = world_map_package.load(directory, expected_revision, "../game_common/server/res")
	alliance_cities = city_siege.placements(campaign, DATA_COMMON.get_city_configs(), DATA_COMMON.CITY_TYPE,
		CONST.ENTITY_ID.ALLIANCE_CITY, CONST.MAP_SIDE)
	local saved_users = MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.USER_INFO, {
		["dat._user_id"] = 1, ["dat._has_birth"] = 1,
		["dat._birth_x"] = 1, ["dat._birth_y"] = 1,
	})
	local stored_map = MONGO_SLAVE.common_load_single("world_map_col", "static-map")
	local legacy_revision = dofile("../config/map_legacy.lua")
	local binding = world_map_package.binding(manifest, stored_map, next(saved_users) ~= nil, legacy_revision)
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
	alliance_city_owners = {}
	rebuild_city_navigation()
	obstacles = nil
	load_used_birth(saved_users)
	if binding then
		MONGO_SLAVE.save_doc("world_map_col", "static-map", binding)
		MONGO_SLAVE.flush_sync()
	end
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

local function each_landmark_cell(city, fn)
	local w, h = map_obj:get_width(), map_obj:get_height()
	for y = city.y - city.radius, city.y + city.radius do
		for x = city.x - city.radius, city.x + city.radius do
			if x >= 0 and y >= 0 and x < w and y < h and not map_obj:is_block(idx_of_pos(x, y)) then fn(x, y) end
		end
	end
end

-- Sparse spatial index: only overlapping footprints are inspected per cell.
local function refresh_cell_permission(key, cell)
    local allowed
    for uid in pairs(cell.players) do
        local id = owner_alliance(uid) or 0
        if id == 0 or allowed and allowed ~= id then allowed = 0; break end
        allowed = id
    end
    if allowed ~= 0 then
        for id in pairs(cell.landmarks) do
            local owner = alliance_city_owners[id] or 0
            if owner == 0 or allowed and allowed ~= owner then allowed = 0; break end
            allowed = owner
        end
    end
    local old = cell.allowed
    if old and old > 0 and old ~= allowed then
        local list = passable_by_alliance[old]
        list[key] = nil
        if not next(list) then passable_by_alliance[old] = nil end
    end
    cell.allowed = allowed
    if allowed and allowed > 0 then
        local list = passable_by_alliance[allowed] or {}
        passable_by_alliance[allowed] = list
        list[key] = cell
    end
end

local function index_footprint(pos, kind, id, present, each_cell)
    each_cell(pos, function(x, y)
        local key = idx_of_pos(x, y)
        local cell = cell_occupants[key]
        if present then
            if not cell then
                cell = {x, y, x = x, y = y, players = {}, landmarks = {}}
                cell_occupants[key] = cell
            end
            cell[kind][id] = true
            refresh_cell_permission(key, cell)
        elseif cell then
            cell[kind][id] = nil
            refresh_cell_permission(key, cell)
            if not next(cell.players) and not next(cell.landmarks) then cell_occupants[key] = nil end
        end
    end)
end

local function cell_blocked(alliance_id, x, y)
    local cell = cell_occupants[idx_of_pos(x, y)]
    return cell ~= nil and (not alliance_id or cell.allowed ~= alliance_id)
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

local function sync_landmark(nav, city, alliance_id)
	each_landmark_cell(city, function(x, y)
		if cell_blocked(alliance_id, x, y) then nav:set_obstacle({x = x, y = y})
		else nav:unset_obstacle({x = x, y = y}) end
	end)
	mark_nav(nav)
end

-- 起服与热更重建派生寻路缓存，不修改地形、玩家位置或城池归属。
function rebuild_city_navigation()
    nav_of_alliance, nav_used, nav_clock = {}, {}, 0
    dirty_nav, cell_occupants, landmark_by_id, passable_by_alliance = {}, {}, {}, {}
    for uid, pos in pairs(city_pos) do index_footprint(pos, "players", uid, true, each_city_cell) end
    for _, city in ipairs(alliance_cities) do
        landmark_by_id[city.id] = city
        index_footprint(city, "landmarks", city.id, true, each_landmark_cell)
    end
    nav_alone = navigation.new(map_obj:get_width(), map_obj:get_height(), terrain_obstacles)
    for _, cell in pairs(cell_occupants) do nav_alone:set_obstacle(cell) end
    nav_alone:update_areas()
end

-- 占领/失守持久化成功后更新所有已缓存联盟视图，不能继续沿用旧的通行权限。
function set_alliance_city_owner(city_id, alliance_id)
    alliance_id = alliance_id or 0
    if (alliance_city_owners[city_id] or 0) == alliance_id then return end
    alliance_city_owners[city_id] = alliance_id
    local city = landmark_by_id[city_id]
    if city then
        index_footprint(city, "landmarks", city_id, true, each_landmark_cell)
        for id, nav in pairs(nav_of_alliance) do sync_landmark(nav, city, id) end
    end
    flush_nav()
end

-- 本联盟的主城九格都不挡。其它联盟、没联盟的主城九格都挡
local function build_alliance_nav(alliance_id)
    local count, oldest, oldest_used = 0, nil, math.huge
    for id in pairs(nav_of_alliance) do
        count = count + 1
        if nav_used[id] < oldest_used then oldest, oldest_used = id, nav_used[id] end
    end
    local nav
    if count >= nav_limit then
        nav = nav_of_alliance[oldest]
        nav_of_alliance[oldest], nav_used[oldest] = nil, nil
        dirty_nav[nav] = nil
        -- Only cells permitted to the previous/new alliance can differ.
        -- All other occupied cells and static terrain stay blocked in both views.
        for _, cell in pairs(passable_by_alliance[oldest] or {}) do nav:set_obstacle(cell) end
        for _, cell in pairs(passable_by_alliance[alliance_id] or {}) do nav:unset_obstacle(cell) end
        nav:update_areas()
    else
        -- Build the native buffer once with its final obstacle list. This avoids
        -- a second full connectivity pass and one Lua-to-C call per occupied cell.
        local obstacles = {}
        for _, pos in ipairs(terrain_obstacles) do obstacles[#obstacles + 1] = pos end
        for _, cell in pairs(cell_occupants) do
            if cell.allowed ~= alliance_id then obstacles[#obstacles + 1] = cell end
        end
        nav = navigation.new(map_obj:get_width(), map_obj:get_height(), obstacles)
    end
    nav_of_alliance[alliance_id] = nav
    return nav
end

-- 这一格落在谁的主城 3×3 里
function city_of(x, y)
    x, y = math.floor(x), math.floor(y)
    if x < 0 or y < 0 or x >= map_obj:get_width() or y >= map_obj:get_height() then return end
    local cell = cell_occupants[idx_of_pos(x, y)]
    return cell and next(cell.players)
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
    if old then index_footprint(old, "players", user_id, false, each_city_cell) end
    index_footprint(pos, "players", user_id, true, each_city_cell)
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
    index_footprint(pos, "players", user_id, true, each_city_cell)
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
        nav_clock = nav_clock + 1
        nav_used[alliance_id] = nav_clock
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
	-- 已在失守城内的部队允许撤离；城外部队不能借此放开任何关口。
	-- 城池可能连着两个独立区域，必须临时重算连通性，不能随机借用邻格区域号。
	local opened, ignored_blocked = {}, {}
    for _, pos in ipairs(ignore or {}) do
        if nav:is_obstacle(pos) then ignored_blocked[#ignored_blocked + 1] = pos end
    end
    local origin = {x = sx, y = sy}
    if nav:is_obstacle(origin) then ignored_blocked[#ignored_blocked + 1] = origin end
    local restore <close> = setmetatable({}, {__close = function()
        local changed = #opened > 0
        for _, pos in ipairs(opened) do nav:set_obstacle(pos) end
        -- The library also temporarily opens own-city/start cells. If its setup
        -- fails before its internal cleanup, restore those cells here as well.
        for _, pos in ipairs(ignored_blocked) do
            if not nav:is_obstacle(pos) then nav:set_obstacle(pos); changed = true end
        end
        if changed then nav:update_areas() end
    end})
	for _, city in ipairs(alliance_cities) do
		if math.abs(math.floor(sx) - city.x) <= city.radius and math.abs(math.floor(sy) - city.y) <= city.radius then
			each_landmark_cell(city, function(x, y)
				local pos = {x = x, y = y}
				if nav:is_obstacle(pos) then
					opened[#opened + 1] = pos
					nav:unset_obstacle(pos)
				end
			end)
		end
	end
	if #opened > 0 then nav:update_areas() end
	local ok, path = xpcall(function()
		return nav:find_path({x = sx, y = sy}, {x = ex, y = ey}, nil, ignore)
	end, debug.traceback)
	if not ok then error(path) end
	if not path or #path < 2 then
		return
	end
	local ret = {}
	for i, pos in ipairs(path) do
		ret[i] = {_x = pos.x, _y = pos.y}
	end
	return ret
end

-- 城池中心可能是不可行走的建筑格，攻城停在可达的外沿，不改变地形障碍。
function find_city_approach(user_id, sx, sy, city)
	local candidates, radius = {}, city.radius + 1
	for dy = -radius, radius do
		for dx = -radius, radius do
			if math.abs(dx) == radius or math.abs(dy) == radius then
				local x, y = city.x + dx, city.y + dy
				candidates[#candidates + 1] = {x = x, y = y, d = (sx - x)^2 + (sy - y)^2}
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.d ~= b.d then return a.d < b.d end
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	local best, best_length = nil, math.huge
	for _, pos in ipairs(candidates) do
		if pos.d > best_length * best_length then break end -- 直线距离是剩余候选的下界。
		local path = find_march_path(user_id, sx, sy, pos.x, pos.y)
		if path then
			local length = 0
			for i = 2, #path do length = length + math.sqrt((path[i]._x - path[i-1]._x)^2 + (path[i]._y - path[i-1]._y)^2) end
			if length < best_length then best, best_length = path, length end
		end
	end
	return best
end

-- All shared-native navigation mutations are synchronous. Reject an accidental
-- RPC/sleep before it registers a waiter, and reject direct coroutine yields.
-- Closing the suspended coroutine runs the departure gate's <close> rollback.
local function atomic_navigation(fn)
    return function(...)
        assert(not navigation_busy, "world navigation reentry")
        navigation_busy = true
        local saved = {}
        for _, name in ipairs({"call", "rawcall", "sleep", "wait"}) do
            saved[#saved + 1] = {name = name, value = skynet[name]}
            skynet[name] = function() error("world navigation cannot yield", 2) end
        end
        local co = coroutine.create(fn)
        local result = table.pack(coroutine.resume(co, ...))
        if coroutine.status(co) ~= "dead" then
            local closed, close_err = coroutine.close(co)
            result = {false, closed and "world navigation cannot yield" or close_err, n = 2}
        elseif not result[1] then
            result[2] = debug.traceback(co, tostring(result[2]))
            coroutine.close(co)
        end
        for _, entry in ipairs(saved) do skynet[entry.name] = entry.value end
        navigation_busy = false
        if not result[1] then error(result[2], 0) end
        return table.unpack(result, 2, result.n)
    end
end

rebuild_city_navigation = atomic_navigation(rebuild_city_navigation)
set_alliance_city_owner = atomic_navigation(set_alliance_city_owner)
set_city = atomic_navigation(set_city)
on_user_alliance = atomic_navigation(on_user_alliance)
begin_nav_batch = atomic_navigation(begin_nav_batch)
end_nav_batch = atomic_navigation(end_nav_batch)
find_march_path = atomic_navigation(find_march_path)

function navigation_stats()
    local count = 0
    for _ in pairs(nav_of_alliance) do count = count + 1 end
    return {cache_limit = nav_limit, cache_size = count}
end
