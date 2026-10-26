-- 地图标记：格子唯一、上限、删除

local FILE = "logic/service/agent/module/mark/mgr.lua"

local function setup()
	local env = setmetatable({}, {__index = _G})
	local user = {_data = {_marks = {}}}
	function user:get_user_id() return 7 end
	function user:get_mark(key)
		local mark = self._data._marks[key]
		if not mark then
			return
		end
		return mark._x, mark._y
	end
	function user:get_mark_cnt()
		local n = 0
		for _ in pairs(self._data._marks) do
			n = n + 1
		end
		return n
	end
	function user:get_mark_list()
		local list = {}
		for _, mark in pairs(self._data._marks) do
			list[#list + 1] = {x = mark._x, y = mark._y}
		end
		return list
	end
	function user:set_mark(key, x, y)
		self._data._marks[key] = {_x = x, _y = y}
	end
	function user:del_mark(key)
		self._data._marks[key] = nil
	end
	local told = {}
	local sent = {}
	env.DATA_COMMON = {get_mark_max_cnt = function() return 2 end}
	env.USER_MGR = {
		get_user_by_fd = function(fd)
			if fd ~= 9 then
				return
			end
			return user
		end,
		tell_me = function(_, msg) told[#told + 1] = msg end,
	}
	env.for_maker = {}
	env.for_caller = {
		s2c_req_mark_list = function(_, pkt) sent[#sent + 1] = {"list", pkt} end,
		s2c_add_mark = function(_, pkt) sent[#sent + 1] = {"add", pkt} end,
		s2c_del_mark = function(_, pkt) sent[#sent + 1] = {"del", pkt} end,
	}
	assert(loadfile(FILE, "t", env))()
	env.__init__()
	return env, user, told, sent
end

local T = {}

function T.add_list_and_same_cell()
	local M, user, told, sent = setup()
	M.for_maker.c2s_add_mark(9, {pos = {x = 3, y = 4}})
	M.for_maker.c2s_add_mark(9, {pos = {x = 3, y = 4}})
	M.for_maker.c2s_req_mark_list(9, {})
	assert(#told == 0)
	assert(sent[1][1] == "add" and sent[1][2].markInfo.pos.x == 3 and sent[1][2].markInfo.pos.y == 4)
	assert(sent[2][1] == "add")
	local n = 0
	for _ in pairs(user._data._marks) do
		n = n + 1
	end
	assert(n == 1)
	assert(#sent[3][2].markList == 1)
end

function T.zero_pos_is_valid()
	local M, _, told, sent = setup()
	M.for_maker.c2s_add_mark(9, {pos = {}})
	assert(#told == 0 and sent[1][2].markInfo.pos.x == 0 and sent[1][2].markInfo.pos.y == 0)
end

function T.limit_and_delete()
	local M, user, told, sent = setup()
	M.for_maker.c2s_add_mark(9, {pos = {x = 1, y = 1}})
	M.for_maker.c2s_add_mark(9, {pos = {x = 2, y = 2}})
	M.for_maker.c2s_add_mark(9, {pos = {x = 3, y = 3}})
	assert(told[1] == "标记已达上限")
	M.for_maker.c2s_del_mark(9, {pos = {x = 1, y = 1}})
	assert(sent[#sent][1] == "del" and sent[#sent][2].pos.x == 1)
	assert(not user._data._marks[1 * 1000 + 1])
	M.for_maker.c2s_del_mark(9, {pos = {x = 1, y = 1}})
	assert(told[2] == "没有这个标记")
end

function T.out_of_map()
	local M, _, told, sent = setup()
	M.for_maker.c2s_add_mark(9, {pos = {x = -1, y = 0}})
	M.for_maker.c2s_add_mark(9, {pos = {x = 1000, y = 0}})
	assert(told[1] == "坐标无效" and told[2] == "坐标无效" and #sent == 0)
end

function T.proto_roundtrip()
	local protobuf = require "protobuf"
	protobuf.register_file("game_common/pb/common.pb")
	protobuf.register_file("game_common/pb/world.pb")
	local M, _, _, sent = setup()
	M.for_maker.c2s_add_mark(9, {pos = {x = 8, y = 9}})
	local back = protobuf.decode("World.s2c_add_mark", protobuf.encode("World.s2c_add_mark", sent[1][2]))
	assert(back.markInfo.pos.x == 8 and back.markInfo.pos.y == 9)
end

return T
