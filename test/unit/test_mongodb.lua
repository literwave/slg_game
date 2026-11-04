local bson = require "bson"
local T = {}
local function setup(reply, collection)
	local calls = {}
	local db = {}
	function db:runCommand(...)
		local args = {...}
		calls[#calls + 1] = args
		return reply and reply(args, #calls) or {ok = 1}
	end
	function db:getCollection() return collection or {} end
	local env = setmetatable({
		cls_object = {Inherit = function() return {} end},
		require = function(name)
			if name == "skynet" then return {error = function() end} end
			if name == "skynet.db.mongo" then return {} end
			return require(name)
		end,
	}, {__index = _G})
	assert(loadfile("logic/service/main_mongodb/module/save/mongo_obj.lua", "t", env))()
	local obj = setmetatable({mongo_client = {getDB = function() return db end}}, {__index = env.cls_mongo_db})
	return obj, calls
end
local function options(args)
	local ret = {}
	for i = 3, #args, 2 do ret[args[i]] = args[i + 1] end
	return ret
end
local function set(key, value)
	return {key = key, op_type = "$set", field_str = "dat", value = value}
end

function T.find_reads_every_batch()
	local obj, calls = setup(function(a, n)
		if n == 1 then return {ok = 1, cursor = {id = 922337203685477580, firstBatch = {{_id = 1}}}} end
		assert(a[1] == "getMore" and a[3] == "collection")
		assert(bson.decode(bson.encode({id = a[2]})).id == (n == 2 and 922337203685477580 or 5))
		if n == 2 then return {ok = 1, cursor = {id = 5, nextBatch = {{_id = 2}, {_id = 3}}}} end
		return {ok = 1, cursor = {id = 0, nextBatch = {{_id = 4}}}}
	end)
	local list = obj:find_all({database = "test", collection = "users"})
	assert(#list == 4 and list[4]._id == 4 and #calls == 3)
end

function T.find_failure_is_not_empty_and_closes_cursor()
	local obj, calls = setup(function(a, n)
		if n == 1 then return {ok = 1, cursor = {id = 123, firstBatch = {{_id = 1}}}} end
		if a[1] == "killCursors" then return {ok = 1} end
		return {ok = 0, errmsg = "cursor unavailable"}
	end)
	local ok, err = pcall(obj.find_all, obj, {database = "test", collection = "users"})
	assert(not ok and tostring(err):find("cursor unavailable", 1, true))
	assert(calls[3][1] == "killCursors")
	obj = setup(function() return {ok = 0, errmsg = "offline"} end)
	assert(not pcall(obj.find_one, obj, {database = "test", collection = "users"}))
end

function T.limit_projection_and_single_read_do_not_mutate_arguments()
	local obj, calls = setup(function(a)
		if a[1] == "killCursors" then return {ok = 1} end
		return {ok = 1, cursor = {id = 3, firstBatch = {{_id = 1}, {_id = 2}, {_id = 3}}}}
	end)
	local args = {database = "test", collection = "users", selector = {dat = 1}, skip = 5, limit = 2, sort = {_id = 1}}
	assert(#obj:find_all(args) == 2)
	assert(calls[2][1] == "killCursors")
	assert(options(calls[1]).skip == 5 and options(calls[1]).projection.dat == 1)
	obj:find_one(args)
	assert(args.limit == 2)
	assert(options(calls[3]).limit == 1 and options(calls[3]).singleBatch == true)
end

function T.batch_reduces_round_trips_and_keeps_order()
	local obj, calls = setup()
	local commands = {}
	for i = 1, 600 do commands[i] = set(i, {value = i}) end
	assert(obj:save_data("test", {users = commands}))
	assert(#calls == 3, "600 documents should use three writes, not 600")
	local count = 0
	for _, a in ipairs(calls) do
		assert(a[1] == "update" and options(a).ordered == true)
		for _, encoded in ipairs(options(a).updates) do
			count = count + 1
			local op = bson.decode(encoded)
			assert(op.q._id == count and op.u["$set"].dat.value == count)
		end
	end
	assert(count == 600)
end

function T.batch_byte_limit_and_insert_do_not_mutate_input()
	local obj, calls = setup()
	local docs = {{_id = 1, payload = string.rep("x", 3 * 1024 * 1024)}, {_id = 2, payload = string.rep("y", 3 * 1024 * 1024)}}
	obj:insert_batch({database = "test", collection = "users", docs = docs})
	assert(#calls == 2)
	assert(type(docs[1]) == "table" and #docs[1].payload == 3 * 1024 * 1024)
end

function T.coalesce_preserves_delete_partial_update_and_false_values()
	local obj, calls = setup()
	obj:save_data("test", {users = {
		set(1, {old = true}), set(2, {b = 2}), set(1, {new = true}),
		{key = 1, op_type = "$unset", field_str = "dat.new"},
		{key = 1, op_type = "del_doc"},
		set(1, {recreated = true}),
		{key = 1, op_type = "$set", field_str = "dat.enabled", value = false},
	}})
	assert(#calls == 3 and calls[2][1] == "delete")
	local first = options(calls[1]).updates
	assert(#first == 3 and bson.decode(first[1]).q._id == 2)
	assert(bson.decode(first[3]).u["$unset"]["dat.new"] == "")
	local last = options(calls[3]).updates
	assert(bson.decode(last[1]).u["$set"].dat.recreated == true)
	assert(bson.decode(last[2]).u["$set"]["dat.enabled"] == false)
end

function T.write_errors_and_write_concern_errors_propagate()
	for _, reply in ipairs({
		{ok = 0, errmsg = "offline"},
		{ok = 1, writeErrors = {{errmsg = "write rejected"}}},
		{ok = 1, writeConcernError = {errmsg = "not durable"}},
	}) do
		local obj = setup(function() return reply end)
		assert(not pcall(obj.save_data, obj, "test", {users = {set(1, {})}}))
	end
	local obj = setup(nil, {safe_update = function() return false, "rejected" end})
	assert(not pcall(obj.update, obj, {database = "test", collection = "users"}))
end

return T
