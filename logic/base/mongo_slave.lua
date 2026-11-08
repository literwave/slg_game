local skynet = require "skynet"
local orm = require "orm"
local queue = require "skynet.queue"

COL = {
	USER_INFO = "user_info_col",
	USER_HERO = "user_hero_col",
	USER_BUILD = "user_build_col",
	USER_ITEM = "user_item_col",
	QUEUE = "queue_col",
	USER_TROOP = "user_troop_col",
	USER_TASK = "user_task_col",
	USER_ACTIVITY = "user_activity_col",
	USER_REPORT = "user_report_col",
	ALLIANCE = "alliance_col",
	SERVER = "server_col",
	GAME_SID = "game_sid_col",
	MAIL = "mail_col",
	USER_MAIL = "user_mail_col",
	SVR_MAIL = "svr_mail_col",
	LAND = "land_col",
	USER_SKILL = "user_skill_col",
	CHAT = "chat_history_col",
	CITY = "alliance_city_col",
}

-- 运行时状态用模块变量，热更时会保留；写成 local 会被重置，丢掉还没发出去的写盘
flush_cb = nil
all_cmd_tbl = {}
flush_scheduled = false
flush_lock = queue()
local flush_cd = 5

local function enqueue(col, cmd)
	if not all_cmd_tbl[col] then
		all_cmd_tbl[col] = {}
	end
	table.insert(all_cmd_tbl[col], cmd)
end

local function schedule_flush(delay)
	if flush_scheduled then
		return
	end
	flush_scheduled = true
	-- 50ms 内的连续属性变化合并为一轮；显式 flush_sync 不等待该窗口。
	skynet.timeout(delay or 5, function()
		flush_scheduled = false
		flush()
	end)
end

orm.on_dirty = function() schedule_flush() end

local function take_cmds()
	for _, doc in ipairs(orm.drain()) do
		enqueue(doc.col, {
			key = doc.key,
			op_type = "$set",
			field_str = "dat",
			value = doc.dat,
		})
	end
	local sending = all_cmd_tbl
	all_cmd_tbl = {}
	return next(sending) and sending
end

-- 等 .mongodb 真正写完才返回，关服用。等待期间定时器可能又改了数据，所以写到没有新脏数据为止
function flush_sync()
	return flush_lock(function()
		local sending = take_cmds()
		while sending do
			local ok, err = pcall(skynet.call, ".mongodb", "lua", "save_data", sending)
			if not ok or err ~= true then
				-- 失败的旧写必须放在新写前面，避免重试旧整包覆盖刚产生的新状态。
				for col, commands in pairs(all_cmd_tbl) do
					local old = sending[col] or {}
					for _, cmd in ipairs(commands) do old[#old + 1] = cmd end
					sending[col] = old
				end
				all_cmd_tbl = sending
				schedule_flush(500)
				error(err or "MongoDB save failed", 0)
			end
			sending = take_cmds()
		end
		return true
	end)
end

function flush()
	local ok, err = pcall(flush_sync)
	if not ok then skynet.error("MongoDB flush retained for retry: " .. tostring(err)) end
	return ok
end

local function push_cmd(col, cmd)
	enqueue(col, cmd)
	schedule_flush()
end

function common_load_single(col, key)
	assert(key)
	local ret = skynet.call(".mongodb", "lua", "find_one", {
		database = GAME.get_data_base(),
		collection = col,
		query = {_id = key},
		selector = {dat = 1},
	})
	if ret and ret.dat then
		return ret.dat
	end
	return nil
end

function common_load_tbl(col, selector)
	local list = skynet.call(".mongodb", "lua", "find_all", {
		database = GAME.get_data_base(),
		collection = col,
		selector = selector,
	}) or {}
	local tbl = {}
	for _, doc in ipairs(list) do
		if doc and doc._id ~= nil and doc.dat ~= nil then
			tbl[doc._id] = doc.dat
		end
	end
	return tbl
end

function common_load_many(col, key_list)
	local ret = {}
	local keys, seen = {}, {}
	local function load_batch()
		if #keys == 0 then return end
		local docs = skynet.call(".mongodb", "lua", "find_all", {
			database = GAME.get_data_base(), collection = col,
			query = {_id = {["$in"] = keys}}, selector = {dat = 1},
		})
		for _, doc in ipairs(docs) do ret[doc._id] = doc.dat end
		keys = {}
	end
	for _, key in pairs(key_list) do
		if not seen[key] then
			seen[key] = true
			keys[#keys + 1] = key
			if #keys >= 256 then load_batch() end
		end
	end
	load_batch()
	return ret
end

function append_chat(key, msg)
	return skynet.call(".mongodb", "lua", "chat_append", {
		database = GAME.get_data_base(), collection = COL.CHAT, key = key,
		msg = msg, max_history = DATA_COMMON.get_chat_history_max(),
	})
end

-- 整包覆盖 dat（map 的 number key 由 ORM.dump 转成字符串）
function save_doc(col, key, dumped)
	assert(col)
	assert(key)
	assert(type(dumped) == "table")
	push_cmd(col, {
		key = key,
		op_type = "$set",
		field_str = "dat",
		value = dumped,
	})
end

-- 子树字段更新：field 必须是非纯数字的 string 字段名
function save_doc_field(col, key, field, value)
	assert(col)
	assert(key)
	assert(type(field) == "string", "saveDocField field must be string")
	assert(not tonumber(field), "saveDocField field must not be numeric string")
	push_cmd(col, {
		key = key,
		op_type = "$set",
		field_str = "dat." .. field,
		value = value,
	})
end

function del_doc(col, key)
	assert(col)
	assert(key)
	push_cmd(col, {
		key = key,
		op_type = "del_doc",
		field_str = nil,
		value = "",
	})
end

function common_save_many(col, tbl)
	for key, dat in pairs(tbl) do
		if type(dat) == "table" then
			save_doc(col, key, dat)
		end
	end
end

function common_del_many(col, key_tbl)
	for key in pairs(key_tbl) do
		del_doc(col, key)
	end
end

function system_startup()
	if not flush_cb then
		flush_cb = CALL_OUT.call_fre("MONGO_SLAVE", "flush", flush_cd)
	end
end
