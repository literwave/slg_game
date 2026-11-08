-- 邮件：按 Mail 模板发信，标题/正文的 %s 依次用 detailList 替换（先标题后正文）
-- 玩家文档在线时常驻，给离线玩家发信时临时加载，写完就卸掉
-- 领奖要回 agent 发奖，由 agent 调 take_rewards 拿奖励

local SVR_DOC_KEY = "server"
local queue = require "skynet.queue"
user_locks = user_locks or {}

local function serialized(fn)
	return function(uid, ...)
		user_locks[uid] = user_locks[uid] or queue()
		return user_locks[uid](fn, uid, ...)
	end
end

svr_doc = nil

local function now()
	return TIME.os_bj_sec()
end

local function get_doc(user_id)
	return ORM.load(MONGO_SLAVE.COL.USER_MAIL, user_id, ORM.CLS_USER_MAIL_DOC)
end

-- 离线玩家的文档用完卸掉；先 flush，下次加载读到的就是新数据
local function release_if_offline(user_id)
	if USER_MGR.is_online(user_id) then
		return
	end
	MONGO_SLAVE.flush_sync()
	ORM.unbind(MONGO_SLAVE.COL.USER_MAIL, user_id)
end

local function expire_time(mail_id, start_time)
	local day = DATA_COMMON.get_mail_conf(mail_id).ExpireDay
	if day <= 0 then
		day = DATA_COMMON.get_mail_default_expire_day()
	end
	return start_time + day * CONST.ONE_DAY_SEC
end

local function has_reward(m)
	return #m._rewards > 0 and not m._is_got_reward
end

-- 锁定的不过期
local function is_expired(m, t)
	return not m._is_lock and m._end_time <= t
end

local function format_text(mail_id, details)
	local conf = DATA_COMMON.get_mail_conf(mail_id)
	local i = 0
	local function fill()
		i = i + 1
		return details[i] or ""
	end
	local title = conf.Title:gsub("%%s", fill)
	local content = conf.Content:gsub("%%s", fill)
	return title, content
end

local function copy_list(list)
	local ret = {}
	for i, v in ipairs(list) do
		ret[i] = v
	end
	return ret
end

local function reward_data(reward_list)
	local ret = {}
	for i, r in ipairs(reward_list) do
		ret[i] = {
			_reward_type = r.reward_type,
			_item_id = r.item_id,
			_item_count = r.item_count,
		}
	end
	return ret
end

local function reward_list_of(m)
	local ret = {}
	for i, r in ipairs(m._rewards) do
		ret[i] = {reward_type = r._reward_type, item_id = r._item_id, item_count = r._item_count}
	end
	return ret
end

local function reward_pto_list(m)
	local ret = {}
	for i, r in ipairs(m._rewards) do
		ret[i] = {rewardType = r._reward_type, itemId = r._item_id, itemCount = r._item_count}
	end
	return ret
end

local function mail_pto(m)
	local title, content = format_text(m._mail_id, m._details)
	return {
		mailId = m._mail_id,
		mailUid = m._mail_uid,
		title = title,
		content = content,
		isRead = m._is_read,
		isLock = m._is_lock,
		isGotReward = m._is_got_reward,
		startTime = m._start_time,
		endTime = m._end_time,
	}
end

local function send_del(user_id, mail_kind, uid_list)
	if #uid_list > 0 then
		USER_MGR.send(user_id, "s2c_del_mail_list", {mailKind = mail_kind, mailUidList = uid_list})
	end
end

-- 超过单类型上限删最早的：锁定的不删，先删没有待领奖励的
local function trim_kind(user_id, doc, mail_kind)
	local list = {}
	local cnt = 0
	for _, m in pairs(doc._mails) do
		if m._mail_kind == mail_kind then
			cnt = cnt + 1
			if not m._is_lock then
				list[#list + 1] = m
			end
		end
	end
	local need = cnt - DATA_COMMON.get_mail_kind_max()
	if need <= 0 then
		return
	end
	table.sort(list, function(a, b)
		local ra, rb = has_reward(a), has_reward(b)
		if ra ~= rb then
			return rb
		end
		return a._mail_uid < b._mail_uid
	end)
	local del = {}
	for i = 1, math.min(need, #list) do
		local uid = list[i]._mail_uid
		doc._mails[uid] = nil
		del[#del + 1] = uid
	end
	send_del(user_id, mail_kind, del)
end

local function clear_expired(user_id, doc)
	local t = now()
	local del_tbl = {}
	for uid, m in pairs(doc._mails) do
		if is_expired(m, t) then
			del_tbl[m._mail_kind] = del_tbl[m._mail_kind] or {}
			table.insert(del_tbl[m._mail_kind], uid)
		end
	end
	for mail_kind, uid_list in pairs(del_tbl) do
		for _, uid in ipairs(uid_list) do
			doc._mails[uid] = nil
		end
		send_del(user_id, mail_kind, uid_list)
	end
end

local function put_mail(user_id, doc, mail_id, details, rewards, start_time, end_time, defer_push)
	local mail_kind = DATA_COMMON.get_mail_conf(mail_id).Kind
	local uid = doc._next_uid + 1
	doc._next_uid = uid
	doc._mails[uid] = {
		_mail_uid = uid,
		_mail_id = mail_id,
		_mail_kind = mail_kind,
		_details = copy_list(details),
		_rewards = rewards,
		_start_time = start_time,
		_end_time = end_time,
		_is_read = false,
		_is_got_reward = false,
		_is_lock = false,
	}
	if not defer_push then
		USER_MGR.send(user_id, "s2c_sync_mail", {mailKind = mail_kind, mailInfo = mail_pto(doc._mails[uid])})
		trim_kind(user_id, doc, mail_kind)
	end
	return doc._mails[uid]
end

-- 补发 _fetch_idx 之后没过期的全服邮件
local function fetch_svr_mail(user_id, doc)
	local t = now()
	for idx = doc._fetch_idx + 1, svr_doc._next_idx do
		local s = svr_doc._mails[idx]
		if s and s._end_time > t then
			put_mail(user_id, doc, s._mail_id, s._details, reward_data(reward_list_of(s)), s._start_time, s._end_time)
		end
	end
	doc._fetch_idx = svr_doc._next_idx
end

local function clear_svr_expired()
	local t = now()
	for idx, s in pairs(svr_doc._mails) do
		if s._end_time <= t then
			svr_doc._mails[idx] = nil
		end
	end
end

function send_user_mail(user_id, mail_id, details, reward_list)
	if not DATA_COMMON.get_mail_conf(mail_id) then
		LOG._error("mail conf not found: %s", mail_id)
		return
	end
	local doc = get_doc(user_id)
	local t = now()
	put_mail(user_id, doc, mail_id, details, reward_data(reward_list), t, expire_time(mail_id, t))
	release_if_offline(user_id)
end

-- 同一城池的轮次按顺序投递；去重水位和邮件一起保存在 user_mail 文档。
-- 保留水位，即使玩家删信或邮件过期，重试也不能再次生成奖励邮件。
function send_user_mail_once(user_id, source, round, mail_id, details, reward_list)
	assert(type(source) == "string" and round > 0)
	assert(DATA_COMMON.get_mail_conf(mail_id), "missing mail template")
	local doc = get_doc(user_id)
	local added
	if (doc._source_rounds[source] or 0) < round then
		local t = now()
		added = put_mail(user_id, doc, mail_id, details, reward_data(reward_list), t, expire_time(mail_id, t), true)
		doc._source_rounds[source] = round
		doc._source_mail_ids[source] = added._mail_uid
	elseif doc._source_rounds[source] == round then
		added = doc._mails[doc._source_mail_ids[source]]
	end
	-- 写失败保留已绑定的文档，下一次重试先补写同一封邮件。
	MONGO_SLAVE.flush_sync()
	if added then
		USER_MGR.send(user_id, "s2c_sync_mail", {mailKind = added._mail_kind, mailInfo = mail_pto(added)})
		trim_kind(user_id, doc, added._mail_kind)
		MONGO_SLAVE.flush_sync()
	end
	if not USER_MGR.is_online(user_id) then ORM.unbind(MONGO_SLAVE.COL.USER_MAIL, user_id) end
	return true
end

function send_group_mail(user_id_list, mail_id, details, reward_list)
	for _, user_id in ipairs(user_id_list) do
		send_user_mail(user_id, mail_id, details, reward_list)
	end
end

function send_srv_mail(mail_id, details, reward_list)
	if not DATA_COMMON.get_mail_conf(mail_id) then
		LOG._error("mail conf not found: %s", mail_id)
		return
	end
	clear_svr_expired()
	local t = now()
	local idx = svr_doc._next_idx + 1
	svr_doc._next_idx = idx
	svr_doc._mails[idx] = {
		_mail_id = mail_id,
		_details = copy_list(details),
		_rewards = reward_data(reward_list),
		_start_time = t,
		_end_time = expire_time(mail_id, t),
	}
	for user_id in pairs(USER_MGR.user_id_to_fd) do
		serialized(function(uid) fetch_svr_mail(uid, get_doc(uid)) end)(user_id)
	end
end

-- agent 领奖：标记已领并返回 {kind_uid_list = 领到的 {k, v}, rewards = 合并前的奖励列表}
-- kind_uid_list 为空表示领全部
function take_rewards(user_id, kind_uid_list)
	local doc = get_doc(user_id)
	local targets = {}
	if #kind_uid_list == 0 then
		for _, m in pairs(doc._mails) do
			targets[#targets + 1] = m
		end
	else
		for _, info in ipairs(kind_uid_list) do
			local m = doc._mails[tonumber(info.v) or 0]
			if m and m._mail_kind == (info.k or 0) then
				targets[#targets + 1] = m
			end
		end
	end
	local done = {}
	local rewards = {}
	local t = now()
	for _, m in ipairs(targets) do
		if has_reward(m) and not is_expired(m, t) then
			m._is_got_reward = true
			m._is_read = true
			done[#done + 1] = {k = m._mail_kind, v = tostring(m._mail_uid)}
			for _, r in ipairs(reward_list_of(m)) do
				rewards[#rewards + 1] = r
			end
		end
	end
	return {kind_uid_list = done, rewards = rewards}
end

-- ---------- 协议 ----------

local function find_mail(doc, mail_kind, mail_uid)
	local m = doc._mails[mail_uid or 0]
	if m and m._mail_kind == mail_kind then
		return m
	end
end

local function on_req_mail_list(user_id, packet)
	local mail_kind = packet.mailKind or 0
	if not DATA_COMMON.get_mail_kind_conf(mail_kind) then
		return
	end
	local doc = get_doc(user_id)
	clear_expired(user_id, doc)
	local list = {}
	for _, m in pairs(doc._mails) do
		if m._mail_kind == mail_kind then
			list[#list + 1] = m
		end
	end
	table.sort(list, function(a, b)
		return a._mail_uid > b._mail_uid
	end)
	local pto_list = {}
	for i, m in ipairs(list) do
		pto_list[i] = mail_pto(m)
	end
	USER_MGR.send(user_id, "s2c_req_mail_list", {mailKind = mail_kind, mailInfoList = pto_list})
end

local function on_req_mail_detail(user_id, packet)
	local m = find_mail(get_doc(user_id), packet.mailKind or 0, packet.mailUid)
	if not m then
		USER_MGR.tell_me(user_id, "邮件不存在")
		return
	end
	m._is_read = true
	USER_MGR.send(user_id, "s2c_req_mail_detail", {
		mailUid = m._mail_uid,
		detailList = copy_list(m._details),
		rewardList = reward_pto_list(m),
	})
end

-- 锁定的、还有奖励没领的不删
local function on_del_mail_list(user_id, packet)
	local mail_kind = packet.mailKind or 0
	local doc = get_doc(user_id)
	local del = {}
	for _, uid in ipairs(packet.mailUidList or EMPTY_TABLE) do
		local m = find_mail(doc, mail_kind, uid)
		if m and not m._is_lock and not has_reward(m) then
			doc._mails[uid] = nil
			del[#del + 1] = uid
		end
	end
	USER_MGR.send(user_id, "s2c_del_mail_list", {mailKind = mail_kind, mailUidList = del})
end

local function on_set_mail_lock(user_id, packet)
	local mail_kind = packet.mailKind or 0
	local is_lock = packet.isLock or false
	local m = find_mail(get_doc(user_id), mail_kind, packet.mailUid)
	if not m then
		return
	end
	m._is_lock = is_lock
	USER_MGR.send(user_id, "s2c_set_mail_lock", {mailKind = mail_kind, mailUid = m._mail_uid, isLock = is_lock})
end

-- ---------- 上下线 ----------

function on_user_login(user_id)
	local doc = get_doc(user_id)
	clear_expired(user_id, doc)
	fetch_svr_mail(user_id, doc)
end

function on_user_logout(user_id)
	MONGO_SLAVE.flush_sync()
	ORM.unbind(MONGO_SLAVE.COL.USER_MAIL, user_id)
end

function __init__()
	if not svr_doc then
		MONGO_SLAVE.system_startup()
		svr_doc = ORM.load(MONGO_SLAVE.COL.SVR_MAIL, SVR_DOC_KEY, ORM.CLS_SVR_MAIL_DOC)
	end
	for_maker.c2s_req_mail_list = serialized(on_req_mail_list)
	for_maker.c2s_req_mail_detail = serialized(on_req_mail_detail)
	for_maker.c2s_del_mail_list = serialized(on_del_mail_list)
	for_maker.c2s_set_mail_lock = serialized(on_set_mail_lock)
end

-- 多城同时给一个离线玩家发奖时，加载、写入、卸载必须属于同一临界区。
send_user_mail = serialized(send_user_mail)
send_user_mail_once = serialized(send_user_mail_once)
take_rewards = serialized(take_rewards)
on_user_login = serialized(on_user_login)
on_user_logout = serialized(on_user_logout)
