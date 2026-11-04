local skynet = require "skynet"
require "skynet.manager"
local mongo_module = Import("../logic/service/main_mongodb/module/save/mongo_obj.lua")
local function client() return mongo_module.cls_mongo_db:New() end
local function main()
	-- 使用独立测试库；从不修改游戏库、真实玩家或聊天记录。
	local database = "slg_persistence_test_" .. os.time() .. "_" .. skynet.self()
	assert(database:match("^slg_persistence_test_%d+_%d+$"))
	local db = client()
	local function args(col) return {database = database, collection = col} end
	local ok, err = xpcall(function()
		local docs = {}
		for i = 1, 650 do docs[i] = {_id = i, dat = {count = i, keep = "keep"}} end
		local a = args("users"); a.docs = docs
		local start = skynet.now()
		db:insert_batch(a)
		local all = db:find_all(args("users"))
		assert(#all == 650, "read stopped at first MongoDB batch")
		local changes = {}
		for i = 1, 650 do changes[i] = {key = i, op_type = "$set", field_str = "dat.count", value = i * 2} end
		db:save_data(database, {users = changes})
		a = args("users"); a.query = {_id = 650}
		assert(db:find_one(a).dat.count == 1300)
		db:save_data(database, {users = {
			{key = 1, op_type = "$unset", field_str = "dat.count"},
			{key = 2, op_type = "del_doc"},
			{key = 2, op_type = "$set", field_str = "dat", value = {new = true}},
		}})
		a.query = {_id = 1}
		assert(db:find_one(a).dat.keep == "keep" and not db:find_one(a).dat.count)
		a.query = {_id = 2}
		assert(db:find_one(a).dat.new and not db:find_one(a).dat.keep)
		print(string.format("PASS: 650 records, full cursor, bounded batch, unset/delete order (%d ms)", (skynet.now() - start) * 10))
		local last_id = 0
		for i = 1, 7 do
			local m = db:chat_append({database = database, collection = "chat", key = "private:1:2",
				max_history = 3, msg = {channel = 3, senderId = 1, targetId = 2, content = "message " .. i, time = os.time()}})
			assert(m.msgId > last_id)
			last_id = m.msgId
		end
		db:disconnect()
		db = client() -- 丢弃连接和服务内序列状态，模拟重启恢复
		local m = db:chat_append({database = database, collection = "chat", key = "private:1:2",
			max_history = 3, msg = {content = "after restart", time = os.time()}})
		assert(m.msgId > last_id)
		a = args("chat"); a.query = {_id = "private:1:2"}
		local hist = db:find_one(a).dat.messages
		assert(#hist == 3 and hist[1].content == "message 6" and hist[3].content == "after restart")
		print("PASS: persisted chat, bounded history, fresh connection and monotonic IDs")
		-- 真实数据库唯一键失败必须抛给调用方。
		a = args("users"); a.doc = {_id = 1, dat = {}}
		assert(not pcall(db.insert, db, a), "duplicate write was incorrectly acknowledged")
		print("PASS: real write failure propagates")
	end, debug.traceback)
	local cleaned, clean_err = pcall(function()
		db:runCommand({database = database, command = {"dropDatabase", 1}})
	end)
	db:disconnect()
	if not ok then error(err) end
	assert(cleaned, tostring(clean_err))
end

skynet.start(function()
	local ok, err = xpcall(main, debug.traceback)
	if ok then print("PERSISTENCE_INTEGRATION_PASS") else print("PERSISTENCE_INTEGRATION_FAIL\n" .. tostring(err)) end
	skynet.abort()
end)
