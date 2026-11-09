local orm = require "orm"
local typedef = require "orm.typedef"

local SCHEMA_DIR = "orm/schema"

local function load_all_schemas()
	local type_list = {}
	local p = io.popen("ls " .. SCHEMA_DIR)
	for file in p:lines() do
		if file:match("%.td$") then
			for _, item in ipairs(typedef.parse(file, SCHEMA_DIR)) do
				type_list[#type_list + 1] = item
			end
		end
	end
	p:close()
	orm.init(type_list)
end

load_all_schemas()
orm.drain()

local COL = "unit_user"
local key_seq = 0

local function new_user(data)
	key_seq = key_seq + 1
	local obj = orm.new("user_data", data or {_user_id = key_seq})
	orm.bind(obj, COL, key_seq)
	return obj, key_seq
end

local function find(list, key)
	for _, v in ipairs(list) do
		if v.key == key then
			return v
		end
	end
end

local T = {}

function T.all_schemas_parse()
	load_all_schemas()
	orm.drain()
end

function T.default_values()
	local u = orm.new("user_data", {})
	assert(u._name == "")
	assert(u._level == 0)
	assert(u._res_tbl ~= nil, "map field should be created")
end

function T.change_marks_dirty_once()
	local u, key = new_user()
	orm.drain()
	u._name = "a"
	u._level = 3
	local list = orm.drain()
	assert(#list == 1, "same doc changed twice should appear once")
	assert(list[1].col == COL and list[1].key == key)
	assert(list[1].dat._name == "a" and list[1].dat._level == 3)
	assert(#orm.drain() == 0)
end

function T.same_value_not_dirty()
	local u = new_user({_name = "x"})
	orm.drain()
	u._name = "x"
	assert(#orm.drain() == 0)
end

function T.nested_change_marks_root()
	local u, key = new_user()
	orm.drain()
	u._res_tbl[1] = 10
	local doc = find(orm.drain(), key)
	assert(doc, "root should be dirty after nested change")
	assert(doc.dat._res_tbl["1"] == 10, "number map key should dump as string")
end

function T.string_key_loads_as_number()
	local u = orm.new("user_data", {_res_tbl = {["1001"] = 5}})
	assert(u._res_tbl[1001] == 5)
end

function T.wrong_type_rejected()
	local u = orm.new("user_data", {})
	assert(not pcall(function() u._level = "abc" end))
	assert(not pcall(function() u._no_such_field = 1 end))
end

function T.unbound_change_not_dirty()
	orm.drain()
	local u = orm.new("user_data", {})
	u._name = "free"
	assert(#orm.drain() == 0)
end

function T.unbind()
	local _, key = new_user()
	assert(orm.get(COL, key))
	orm.unbind(COL, key)
	assert(orm.get(COL, key) == nil)
end

function T.new_returns_same_object()
	local u = orm.new("user_data", {})
	assert(orm.new("user_data", u) == u)
end

function T.removing_child_by_nil()
	local u, key = new_user()
	u._res_tbl[2] = 1
	orm.drain()
	u._res_tbl[2] = nil
	local doc = find(orm.drain(), key)
	assert(doc and doc.dat._res_tbl["2"] == nil)
end

function T.bounded_drain_keeps_dirty_identity_and_fifo_order()
	orm.drain()
	local first, first_key = new_user()
	local second, second_key = new_user()
	local third, third_key = new_user()
	first._level = 1
	second._level = 2
	third._level = 3
	assert(orm.has_dirty())
	assert(#orm.drain(0) == 0 and orm.has_dirty())
	local list = orm.drain(1)
	assert(#list == 1 and list[1].key == first_key and list[1].dat._level == 1)
	second._level = 20 -- still queued: update the existing pending document, not its order
	first._level = 10 -- already drained: a new dirty entry belongs at the tail
	list = orm.drain(2)
	assert(#list == 2 and list[1].key == second_key and list[1].dat._level == 20)
	assert(list[2].key == third_key and orm.has_dirty())
	list = orm.drain()
	assert(#list == 1 and list[1].key == first_key and list[1].dat._level == 10)
	assert(not orm.has_dirty() and #orm.drain(1) == 0)
	first._level = 11
	assert(orm.has_dirty() and orm.drain(1)[1].dat._level == 11)
	assert(not orm.has_dirty())
	for _, invalid in ipairs({-1, 1.5, "1"}) do assert(not pcall(orm.drain, invalid)) end
end

function T.bounded_drain_only_dumps_the_requested_roots()
	orm.drain()
	for i = 1, 130 do local user = new_user(); user._name = "user" .. i end
	local old_dump, dumps = orm.dump, 0
	orm.dump = function(obj) dumps = dumps + 1; return old_dump(obj) end
	-- Every user also contains nested structs/maps; compare a fixed one-root cost
	-- with the entire backlog left dirty, rather than assuming a schema size.
	local ok, err = pcall(function()
		assert(#orm.drain(1) == 1)
		local per_root = dumps
		dumps = 0
		assert(#orm.drain(64) == 64 and dumps == per_root * 64)
		assert(orm.has_dirty() and #orm.drain() == 65 and not orm.has_dirty())
	end)
	orm.dump = old_dump
	assert(ok, err)
end

function T.bounded_drain_serialization_failure_keeps_the_entire_batch_dirty()
	orm.drain()
	local first, first_key = new_user()
	local second, second_key = new_user()
	first._level = 1
	second._level = 2
	local old_dump = orm.dump
	orm.dump = function(obj)
		if obj == second then error("cannot serialize second document") end
		return old_dump(obj)
	end
	local ok, err = pcall(orm.drain, 2)
	orm.dump = old_dump
	assert(not ok and tostring(err):find("cannot serialize second document", 1, true))
	assert(orm.has_dirty())
	first._level = 10
	local retry = orm.drain(2)
	assert(#retry == 2 and retry[1].key == first_key and retry[1].dat._level == 10)
	assert(retry[2].key == second_key and retry[2].dat._level == 2 and not orm.has_dirty())
end

function T.unbind_after_partial_flush_keeps_logout_snapshot_pending()
	orm.drain()
	local users, keys = {}, {}
	for i = 1, 65 do
		users[i], keys[i] = new_user()
		users[i]._level = i
	end
	assert(#orm.drain(64) == 64 and orm.has_dirty())
	-- A logout module may unbind after a bounded background flush. The final
	-- shutdown/disconnect barrier must still find that last document in the queue.
	orm.unbind(COL, keys[65])
	assert(orm.get(COL, keys[65]) == nil)
	users[65]._level = 66
	local final = orm.drain()
	assert(#final == 1 and final[1].key == keys[65] and final[1].dat._level == 66)
	assert(not orm.has_dirty())
end

function T.report_nested_roundtrip()
	local doc = orm.new("user_report_doc", {})
	orm.bind(doc, "unit_report", 1)
	orm.drain()
	doc._reports[1] = {
		_report_id = 1,
		_is_read = false,
		_atk_side = {_name = "a", _units = {{_pos = 1, _before_count = 100, _after_count = 80, _after_hurt = 20}}},
		_actions = {{_round = 1, _effects = {{_target_side = 2, _value = 40}}}},
	}
	local dumped = find(orm.drain(), 1).dat
	local back = orm.new("user_report_doc", dumped)
	local r = back._reports[1]
	assert(r._atk_side._units[1]._after_count == 80 and r._atk_side._units[1]._after_hurt == 20)
	assert(r._actions[1]._effects[1]._value == 40)
	assert(r._def_side._name == "", "missing struct field gets default")
	assert(r._is_read == false)
end

return T
