local skynet = require "skynet"
local mongo = require "skynet.db.mongo"
local bson = require "bson"
local batch = require "mongo_batch"

cls_mongo_db = cls_object:Inherit()

function cls_mongo_db:__init__(oci)
	Super(cls_mongo_db).__init__(self, oci)
	local username = skynet.getenv("mongodb_user")
	local password = skynet.getenv("mongodb_password")
	local conf = {host = skynet.getenv("mongodb_host"), port = skynet.getenv("mongodb_port")}
	if username and username ~= "" and password and password ~= "" then
		conf.username, conf.password = username, password
	end
	self.mongo_client = assert(mongo.client(conf), "MongoDB connection failed")
end

function cls_mongo_db:disconnect()
	self.mongo_client:disconnect()
end

local function check_write(op, args, ok, err)
	if not ok then
		-- 必须传回调用方；只记录日志会使 flush_sync 把失败误判为已保存。
		error(string.format("mongo %s failed db=%s col=%s: %s",
			op, tostring(args.database), tostring(args.collection), tostring(err)), 0)
	end
	return true
end

local function check_reply(op, args, reply)
	local err = reply and (reply.errmsg or reply.writeConcernError and reply.writeConcernError.errmsg
		or reply.writeErrors and reply.writeErrors[1] and reply.writeErrors[1].errmsg)
	check_write(op, args, reply and reply.ok == 1 and not reply.writeErrors
		and not reply.writeConcernError and not reply.errmsg, err or "missing MongoDB response")
	return reply
end

function cls_mongo_db:insert(args)
	local c = self.mongo_client:getDB(args.database):getCollection(args.collection)
	return check_write("insert", args, c:safe_insert(args.doc))
end

function cls_mongo_db:delete(args)
	local c = self.mongo_client:getDB(args.database):getCollection(args.collection)
	return check_write("delete", args, c:safe_delete(args.selector, args.single))
end

function cls_mongo_db:update(args)
	local c = self.mongo_client:getDB(args.database):getCollection(args.collection)
	return check_write("update", args, c:safe_update(args.selector, args.update, args.upsert, args.multi))
end

-- BSON 只编码一次；条数和字节数双限，避免大背包/战报使整批超过 MongoDB 命令上限。
local MAX_BATCH_COUNT, MAX_BATCH_BYTES = 256, 4 * 1024 * 1024
local BATCH_FIELD = {insert = "documents", update = "updates", delete = "deletes"}
local function writer(db, args)
	local pending, bytes, kind = {}, 0, nil
	local function flush()
		if #pending == 0 then return end
		check_reply(kind, args, db:runCommand(kind, args.collection, BATCH_FIELD[kind], pending, "ordered", true))
		pending, bytes = {}, 0
	end
	local function add(op, doc)
		local encoded = bson.encode(doc)
		if kind ~= op or #pending >= MAX_BATCH_COUNT or bytes + #encoded > MAX_BATCH_BYTES then flush() end
		kind = op
		pending[#pending + 1] = encoded
		bytes = bytes + #encoded
	end
	return add, flush
end

function cls_mongo_db:insert_batch(args)
	local add, finish = writer(self.mongo_client:getDB(args.database), args)
	for _, doc in ipairs(args.docs) do add("insert", doc) end
	finish()
	return true
end

function cls_mongo_db:save_data(database, all_cmd_tbl)
	local db = self.mongo_client:getDB(database)
	for col, commands in pairs(all_cmd_tbl) do
		local add, finish = writer(db, {database = database, collection = col})
		for _, cmd in ipairs(batch.compact(commands)) do add(batch.operation(cmd)) end
		finish()
	end
	return true
end

local function find_command(db, args, one)
	local cmd = {"find", args.collection, "filter", args.query or {}}
	for _, pair in ipairs({{"projection", args.selector}, {"skip", args.skip}, {"sort", args.sort}}) do
		if pair[2] ~= nil then
			cmd[#cmd + 1], cmd[#cmd + 2] = pair[1], pair[2]
		end
	end
	if one then
		cmd[#cmd + 1], cmd[#cmd + 2] = "limit", 1
		cmd[#cmd + 1], cmd[#cmd + 2] = "singleBatch", true
	elseif args.limit ~= nil then
		cmd[#cmd + 1], cmd[#cmd + 2] = "limit", args.limit
	end
	return check_reply("find", args, db:runCommand(table.unpack(cmd)))
end

function cls_mongo_db:find_one(args)
	local reply = find_command(self.mongo_client:getDB(args.database), args, true)
	assert(reply.cursor and reply.cursor.firstBatch, "missing find cursor")
	return reply.cursor.firstBatch[1]
end

function cls_mongo_db:find_all(args)
	local db = self.mongo_client:getDB(args.database)
	local cursor_id = 0
	local function read()
		local reply = find_command(db, args)
		local result = {}
		local limit = args.limit and math.abs(args.limit) or 0
		while true do
			local cursor = assert(reply.cursor, "missing find cursor")
			cursor_id = cursor.id or 0
			for _, doc in ipairs(cursor.firstBatch or cursor.nextBatch or {}) do
				result[#result + 1] = doc
				if limit > 0 and #result >= limit then return result end
			end
			if cursor_id == 0 then return result end
			reply = check_reply("getMore", args, db:runCommand("getMore", bson.int64(cursor_id),
				"collection", args.collection))
		end
	end
	local ok, result = pcall(read)
	if cursor_id ~= 0 then
		-- 达到 limit 或读取失败也释放游标；清理异常不能掩盖原始读取异常。
		local closed, err = pcall(function()
			check_reply("killCursors", args, db:runCommand("killCursors", args.collection,
				"cursors", {bson.int64(cursor_id)}))
		end)
		if not closed then skynet.error(err) end
	end
	if not ok then error(result, 0) end
	return result
end

-- 每个会话一份有界记录，_id 直接走主键索引，不扫描其它玩家的私聊。
function cls_mongo_db:chat_append(args)
	local db = self.mongo_client:getDB(args.database)
	assert(type(args.key) == "string" and args.key ~= "sequence")
	assert(math.type(args.max_history) == "integer" and args.max_history > 0)
	if not self.chat_sequence_ready then
		check_write("chat sequence seed", args, db:getCollection(args.collection):safe_update(
			{_id = "sequence"}, {["$max"] = {value = os.time() * 1000}}, true, false))
		self.chat_sequence_ready = true
	end
	local r = check_reply("chat sequence", args, db:runCommand("findAndModify", args.collection,
		"query", {_id = "sequence"}, "update", {["$inc"] = {value = 1}}, "new", true))
	local msg = args.msg
	msg.msgId = assert(r.value and r.value.value, "missing chat message id")
	self:update({database = args.database, collection = args.collection, selector = {_id = args.key},
		update = {["$push"] = {["dat.messages"] = {["$each"] = {msg}, ["$slice"] = -args.max_history}},
			["$set"] = {["dat.updated_at"] = msg.time}}, upsert = true, multi = false})
	return msg
end

function cls_mongo_db:drop(args)
	return check_reply("drop", args, self.mongo_client:getDB(args.database):runCommand("drop", args.collection))
end

function cls_mongo_db:create_index(args)
	return self.mongo_client:getDB(args.database):getCollection(args.collection):createIndex(args.keys, args.option)
end

function cls_mongo_db:runCommand(args)
	return check_reply("command", args, self.mongo_client:getDB(args.database):runCommand(table.unpack(args.command)))
end
