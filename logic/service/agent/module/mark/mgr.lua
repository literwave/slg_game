-- 玩家自己的地图标记。同一格子只有一条，上限是 Global.Id=18

local map_w, map_h

local function map_size()
	if map_w then
		return map_w, map_h
	end
	local path = "../res/map/manifest.lua"
	local f = io.open(path, "r")
	if f then
		f:close()
	else
		path = "res/map/manifest.lua"
	end
	local manifest = dofile(path)
	map_w = manifest.width
	map_h = manifest.height
	return map_w, map_h
end

local function cell_key(x, y)
	local w = map_size()
	return y * w + x
end

local function pos_pto(x, y)
	return {x = x, y = y}
end

-- proto3 不发送 0，缺省的坐标按 0
local function read_pos(pos)
	if not pos then
		return
	end
	local x = math.floor(pos.x or 0)
	local y = math.floor(pos.y or 0)
	local w, h = map_size()
	if x < 0 or y < 0 or x >= w or y >= h then
		return
	end
	return x, y
end

local function on_req_mark_list(fd)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local mark_list = {}
	for _, pos in ipairs(user:get_mark_list()) do
		mark_list[#mark_list + 1] = {pos = pos_pto(pos.x, pos.y)}
	end
	for_caller.s2c_req_mark_list(fd, {markList = mark_list})
end

local function on_add_mark(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local user_id = user:get_user_id()
	local x, y = read_pos(packet.pos)
	if not x then
		USER_MGR.tell_me(user_id, "坐标无效")
		return
	end
	local key = cell_key(x, y)
	local mx, my = user:get_mark(key)
	if not mx then
		if user:get_mark_cnt() >= DATA_COMMON.get_mark_max_cnt() then
			USER_MGR.tell_me(user_id, "标记已达上限")
			return
		end
		user:set_mark(key, x, y)
		mx, my = x, y
	end
	for_caller.s2c_add_mark(fd, {markInfo = {pos = pos_pto(mx, my)}})
end

local function on_del_mark(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local user_id = user:get_user_id()
	local x, y = read_pos(packet.pos)
	if not x then
		USER_MGR.tell_me(user_id, "坐标无效")
		return
	end
	local key = cell_key(x, y)
	if not user:get_mark(key) then
		USER_MGR.tell_me(user_id, "没有这个标记")
		return
	end
	user:del_mark(key)
	for_caller.s2c_del_mark(fd, {pos = pos_pto(x, y)})
end

function __init__()
	for_maker.c2s_req_mark_list = on_req_mark_list
	for_maker.c2s_add_mark = on_add_mark
	for_maker.c2s_del_mark = on_del_mark
end
