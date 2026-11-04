-- 每个频道/私聊会话保留 Global.Id=9 条；数据库确认保存后才回执、广播。
local skynet = require "skynet"
local queue = require "skynet.queue"
chat_lock = queue()
history_loaded = {}

world_hist = {}
-- [alliance_id] = {msg, ...}
alliance_hist = {}
-- ["小uid:大uid"] = {msg, ...}
private_hist = {}
-- [user_id] = 上次发言时间
last_chat_time = {}
-- [user_id] = true，确认过存在的私聊对象
known_user = {}


local function private_key(a, b)
	if a > b then
		a, b = b, a
	end
	return a .. ":" .. b
end

local function push(list, msg)
	list[#list + 1] = msg
	local over = #list - DATA_COMMON.get_chat_history_max()
	if over > 0 then
		table.move(list, over + 1, #list, 1)
		for i = #list - over + 1, #list do
			list[i] = nil
		end
	end
end

local function user_exists(user_id)
	if known_user[user_id] or USER_MGR.get_brief(user_id) then
		return true
	end
	if MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.USER_INFO, user_id) then
		known_user[user_id] = true
		return true
	end
	return false
end

local function load_history(key, list)
	if history_loaded[key] then return list end
	local saved = MONGO_SLAVE.common_load_single(MONGO_SLAVE.COL.CHAT, key)
	local legacy = {}
	for i, msg in ipairs(list) do legacy[i] = msg end
	for i = #list, 1, -1 do list[i] = nil end
	local seen = {}
	for _, msg in ipairs(saved and saved.messages or {}) do
		if not seen[msg.msgId] then push(list, msg); seen[msg.msgId] = true end
	end
	-- 热更时将旧版还在内存中的消息补存；重启后的空缓存只读取，不重写历史。
	for _, msg in ipairs(legacy) do
		if not seen[msg.msgId] then push(list, msg); seen[msg.msgId] = true end
	end
	if #legacy > 0 then
		MONGO_SLAVE.save_doc(MONGO_SLAVE.COL.CHAT, key, {messages = list})
		MONGO_SLAVE.flush_sync()
	end
	history_loaded[key] = true
	return list
end

local function history_of(user_id, channel, target_id)
	if channel == DATA_COMMON.CHAT_CHANNEL.WORLD then
		return load_history("world", world_hist), "world"
	end
	if channel == DATA_COMMON.CHAT_CHANNEL.ALLIANCE then
		local aid = ALLIANCE_MGR.user_alliance[user_id]
		if not aid then return end
		alliance_hist[aid] = alliance_hist[aid] or {}
		local key = "alliance:" .. aid
		local hist = load_history(key, alliance_hist[aid])
		-- 读取会让出协程；被踢出/退盟的玩家不能拿到原联盟的历史。
		if ALLIANCE_MGR.user_alliance[user_id] ~= aid then return end
		return hist, key, aid
	end
	if channel == DATA_COMMON.CHAT_CHANNEL.PRIVATE then
		if target_id <= 0 or target_id == user_id then return end
		local pair = private_key(user_id, target_id)
		private_hist[pair] = private_hist[pair] or {}
		local key = "private:" .. pair
		return load_history(key, private_hist[pair]), key
	end
end

local function deliver(user_id, msg, alliance_id)
	if msg.channel == DATA_COMMON.CHAT_CHANNEL.WORLD then
		for uid in pairs(USER_MGR.user_id_to_fd) do
			if uid ~= user_id then
				USER_MGR.send(uid, "s2c_sync_chat", {msg = msg})
			end
		end
	elseif msg.channel == DATA_COMMON.CHAT_CHANNEL.ALLIANCE then
		local doc = ALLIANCE_MGR.alliance_tbl[alliance_id]
		if not doc then return end
		for uid in pairs(doc._members) do
			if uid ~= user_id then
				USER_MGR.send(uid, "s2c_sync_chat", {msg = msg})
			end
		end
	elseif msg.channel == DATA_COMMON.CHAT_CHANNEL.PRIVATE then
		USER_MGR.send(msg.targetId, "s2c_sync_chat", {msg = msg})
	end
end

local function on_chat(user_id, packet)
	local channel = packet.channel or 0
	local content = packet.content or ""
	local target_id = packet.targetId or 0
	if not DATA_COMMON.get_chat_channel_conf(channel) then
		return
	end
	local len = utf8.len(content)
	if not len or len < 1 or len > CONST.CHAT_CONTENT_MAX_LEN then
		USER_MGR.tell_me(user_id, "聊天内容长度不合法")
		return
	end
	local now = TIME.os_bj_sec()
	if now < (last_chat_time[user_id] or 0) + CONST.CHAT_INTERVAL then
		USER_MGR.tell_me(user_id, "发言太快了")
		return
	end
	if channel ~= DATA_COMMON.CHAT_CHANNEL.PRIVATE then
		target_id = 0
	elseif not user_exists(target_id) then
		USER_MGR.tell_me(user_id, "玩家不存在")
		return
	end
	local hist, key, aid = history_of(user_id, channel, target_id)
	if not hist then
		if channel == DATA_COMMON.CHAT_CHANNEL.ALLIANCE then
			USER_MGR.tell_me(user_id, "还没有加入联盟")
		end
		return
	end
	local brief = USER_MGR.get_brief(user_id)
	local msg = {
		channel = channel,
		senderId = user_id,
		senderName = brief.name,
		headIcon = brief.head_icon,
		content = content,
		time = now,
		targetId = target_id,
	}
	local saved, result = pcall(MONGO_SLAVE.append_chat, key, msg)
	if not saved then
		-- 超时可能发生在数据库写入之后；下次重新读，避免缓存把已落库的消息遮住。
		history_loaded[key] = nil
		for i = #hist, 1, -1 do hist[i] = nil end
		error(result, 0)
	end
	msg = result
	last_chat_time[user_id] = now
	push(hist, msg)
	USER_MGR.send(user_id, "s2c_chat", {msg = msg})
	deliver(user_id, msg, aid)
end

local function on_req_chat_list(user_id, packet)
	local channel = packet.channel or 0
	local target_id = packet.targetId or 0
	if channel ~= DATA_COMMON.CHAT_CHANNEL.PRIVATE then
		target_id = 0
	end
	local hist = history_of(user_id, channel, target_id)
	USER_MGR.send(user_id, "s2c_req_chat_list", {
		channel = channel,
		targetId = target_id,
		msgList = hist or {},
	})
end

function on_alliance_dissolve(alliance_id)
	chat_lock(function()
		alliance_hist[alliance_id] = nil
		history_loaded["alliance:" .. alliance_id] = nil
		MONGO_SLAVE.del_doc(MONGO_SLAVE.COL.CHAT, "alliance:" .. alliance_id)
	end)
end

local function handle(fn, user_id, packet)
	local ok, err = pcall(chat_lock, fn, user_id, packet)
	if not ok then
		skynet.error("chat storage unavailable: " .. tostring(err))
		USER_MGR.tell_me(user_id, "聊天暂时不可用，请稍后重试")
	end
end

function __init__()
	for_maker.c2s_chat = function(uid, packet) handle(on_chat, uid, packet) end
	for_maker.c2s_req_chat_list = function(uid, packet) handle(on_req_chat_list, uid, packet) end
	-- 升级到持久化版本时保住旧进程里的聊天；正常冷启动不会扫描所有会话。
	chat_lock(function()
		if #world_hist > 0 then load_history("world", world_hist) end
		for aid, hist in pairs(alliance_hist) do
			if #hist > 0 then load_history("alliance:" .. aid, hist) end
		end
		for pair, hist in pairs(private_hist) do
			if #hist > 0 then load_history("private:" .. pair, hist) end
		end
	end)
end
