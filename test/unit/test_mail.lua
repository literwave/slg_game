-- mail 服务：用真实 ORM（全部 schema）和 Mail/MailKind 配置，发包记下来检查

local orm = require "orm"
local typedef = require "orm.typedef"

local function load_conf(name)
	local r = {}
	for _, row in ipairs(dofile("game_common/server/res/" .. name .. ".lua")) do
		r[row.Id] = row
	end
	return r
end

local MAIL = load_conf("Mail")
local MAIL_KIND = {}
for _, id in pairs(dofile("game_common/server/enum/MailKindEnum.lua")) do MAIL_KIND[id] = true end
local GLOBAL = load_conf("Global")

do
	local list = {}
	local p = io.popen("ls orm/schema")
	for file in p:lines() do
		if file:match("%.td$") then
			for _, item in ipairs(typedef.parse(file, "orm/schema")) do
				list[#list + 1] = item
			end
		end
	end
	p:close()
	orm.init(list)
end

local DAY = 86400

local function setup(opts)
	opts = opts or {}
	for uid = 1, 5 do
		orm.unbind("user_mail_col", uid)
	end
	orm.unbind("svr_mail_col", "server")
	orm.drain()
	local clock = {now = 100000}
	local sent = {}
	local saved = {}
	local CONST = setmetatable({}, {__index = _G})
	assert(loadfile("logic/define/const.lua", "t", CONST))()
	local function flush()
		for _, d in ipairs(orm.drain()) do
			saved[d.col .. ":" .. d.key] = d.dat
		end
	end
	local shared = {
		require = function(name)
			if name == "skynet.queue" then return function() return function(fn, ...) return fn(...) end end end
			return require(name)
		end,
		CONST = CONST,
		EMPTY_TABLE = {},
		TIME = {os_bj_sec = function() return clock.now end},
		LOG = {_error = function() end},
		DATA_COMMON = {
			get_mail_conf = function(id) return MAIL[id] end,
			get_mail_kind_conf = function(kind) return MAIL_KIND[kind] end,
			get_mail_kind_max = function() return opts.kind_max or GLOBAL[15].value1 end,
			get_mail_default_expire_day = function() return GLOBAL[16].value1 end,
		},
		ORM = {
			CLS_USER_MAIL_DOC = "user_mail_doc",
			CLS_SVR_MAIL_DOC = "svr_mail_doc",
			unbind = orm.unbind,
			load = function(col, key, cls)
				local doc = orm.get(col, key)
				if doc then
					return doc, false
				end
				doc = orm.new(cls, saved[col .. ":" .. key])
				orm.bind(doc, col, key)
				return doc, true
			end,
		},
		MONGO_SLAVE = {
			COL = {USER_MAIL = "user_mail_col", SVR_MAIL = "svr_mail_col"},
			system_startup = function() end,
			flush = flush,
			flush_sync = flush,
		},
		EVENT = {register = function() end},
		for_maker = {},
		for_caller = setmetatable({}, {__index = function(_, name)
			return function(fd, msg)
				sent[#sent + 1] = {uid = fd, name = name, msg = msg}
			end
		end}),
	}
	local function load_mod(path)
		local env = setmetatable({}, {__index = function(_, k)
			local v = shared[k]
			if v ~= nil then
				return v
			end
			return _G[k]
		end})
		assert(loadfile(path, "t", env))()
		return env
	end
	shared.USER_MGR = load_mod("logic/service/mail/module/user/mgr.lua")
	shared.MAIL_MGR = load_mod("logic/service/mail/module/mail/mgr.lua")
	shared.MAIL_MGR.__init__()
	local U, M = shared.USER_MGR, shared.MAIL_MGR

	local api = {shared = shared, sent = sent, clock = clock, saved = saved, M = M}
	-- fd 直接用 uid
	function api.online(uid)
		U.on_user_login(uid, uid, "gate")
	end
	function api.offline(uid)
		U.on_user_logout(uid, uid)
	end
	function api.req(uid, pto, packet)
		shared.for_maker[pto](uid, packet or {})
	end
	function api.last(uid, name)
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.uid == uid and s.name == name then
				return s.msg
			end
		end
	end
	-- 和 common/mail.lua 一样把 nil 换成空表
	function api.send(uid, mail_id, details, rewards)
		M.send_user_mail(uid, mail_id, details or {}, rewards or {})
	end
	function api.send_srv(mail_id, details, rewards)
		M.send_srv_mail(mail_id, details or {}, rewards or {})
	end
	function api.list(uid, kind)
		api.req(uid, "c2s_req_mail_list", {mailKind = kind})
		return api.last(uid, "s2c_req_mail_list").mailInfoList
	end
	return api
end

local function item(id, cnt)
	return {reward_type = 1, item_id = id, item_count = cnt}
end

local T = {}

function T.send_sync_and_format()
	local t = setup()
	t.online(1)
	t.send(1, 7, {"甲"})
	local sync = t.last(1, "s2c_sync_mail")
	assert(sync.mailKind == 2)
	assert(sync.mailInfo.mailId == 7 and sync.mailInfo.mailUid == 1)
	assert(sync.mailInfo.content == "您已成功加入联盟「甲」，与盟友共谋天下吧！")
	assert(sync.mailInfo.endTime == t.clock.now + 7 * DAY)
	t.send(1, 4, {"战力榜", "3"})
	assert(t.last(1, "s2c_sync_mail").mailInfo.content == "恭喜主公在「战力榜」中获得第3名，奖励已发放，请查收。")
	t.send(1, 10, {"停服公告", "今晚维护"})
	local notice = t.last(1, "s2c_sync_mail").mailInfo
	assert(notice.title == "停服公告" and notice.content == "今晚维护")
	assert(#t.list(1, 1) == 1 and #t.list(1, 2) == 1 and #t.list(1, 3) == 1)
end

function T.offline_send_then_login()
	local t = setup()
	t.send(2, 1, nil, {item(1, 100)})
	assert(not t.last(2, "s2c_sync_mail"))
	assert(not orm.get("user_mail_col", 2), "doc released after offline send")
	t.online(2)
	local list = t.list(2, 1)
	assert(#list == 1 and list[1].title == "欢迎来到乱世" and list[1].isGotReward == false)
end

function T.detail_marks_read()
	local t = setup()
	t.online(1)
	t.send(1, 7, {"甲"}, {item(4, 5)})
	t.req(1, "c2s_req_mail_detail", {mailKind = 2, mailUid = 1})
	local d = t.last(1, "s2c_req_mail_detail")
	assert(d.mailUid == 1 and d.detailList[1] == "甲")
	assert(d.rewardList[1].itemId == 4 and d.rewardList[1].itemCount == 5)
	assert(t.list(1, 2)[1].isRead)
	t.req(1, "c2s_req_mail_detail", {mailKind = 1, mailUid = 1})
	assert(t.last(1, "s2c_tell_me").msg == "邮件不存在", "kind must match")
end

function T.reward_lock_and_delete()
	local t = setup()
	t.online(1)
	t.send(1, 2, nil, {item(1, 10), item(2, 20)})
	t.send(1, 5, nil, {item(3, 30)})
	t.send(1, 6)
	t.req(1, "c2s_del_mail_list", {mailKind = 1, mailUidList = {1, 3}})
	local del = t.last(1, "s2c_del_mail_list").mailUidList
	assert(#del == 1 and del[1] == 3, "unclaimed reward mail kept")
	local ret = t.M.take_rewards(1, {{k = 1, v = "1"}})
	assert(#ret.kind_uid_list == 1 and ret.kind_uid_list[1].v == "1")
	assert(#ret.rewards == 2 and ret.rewards[2].item_count == 20)
	assert(#t.M.take_rewards(1, {{k = 1, v = "1"}}).rewards == 0, "no double claim")
	t.req(1, "c2s_set_mail_lock", {mailKind = 1, mailUid = 1, isLock = true})
	assert(t.last(1, "s2c_set_mail_lock").isLock)
	t.req(1, "c2s_del_mail_list", {mailKind = 1, mailUidList = {1}})
	assert(#t.last(1, "s2c_del_mail_list").mailUidList == 0, "locked mail kept")
	local all = t.M.take_rewards(1, {})
	assert(#all.kind_uid_list == 1 and all.rewards[1].item_id == 3, "empty list claims all")
end

function T.kind_max_trims_oldest()
	local t = setup({kind_max = 2})
	t.online(1)
	t.send(1, 2, nil, {item(1, 1)})
	t.send(1, 5)
	t.send(1, 6)
	local del = t.last(1, "s2c_del_mail_list")
	assert(del.mailKind == 1 and #del.mailUidList == 1 and del.mailUidList[1] == 2, "trim mails without reward first")
	local list = t.list(1, 1)
	assert(#list == 2 and list[1].mailUid == 3 and list[2].mailUid == 1)
	t.send(1, 7, {"甲"})
	assert(#t.list(1, 1) == 2, "other kind not counted")
end

function T.expire_and_lock()
	local t = setup()
	t.online(1)
	t.send(1, 2)
	t.send(1, 6)
	t.req(1, "c2s_set_mail_lock", {mailKind = 1, mailUid = 2, isLock = true})
	t.clock.now = t.clock.now + 7 * DAY
	local list = t.list(1, 1)
	assert(#list == 1 and list[1].mailUid == 2, "expired removed, locked kept")
	assert(t.last(1, "s2c_del_mail_list").mailUidList[1] == 1)
end

function T.srv_mail_fetch()
	local t = setup()
	t.online(1)
	t.send_srv(10, {"开服", "欢迎"})
	assert(t.last(1, "s2c_sync_mail").mailKind == 3)
	t.online(2)
	assert(#t.list(2, 3) == 1, "later login fetches")
	t.offline(2)
	t.online(2)
	assert(#t.list(2, 3) == 1, "fetched only once")
	t.clock.now = t.clock.now + 31 * DAY
	t.online(3)
	assert(#t.list(3, 3) == 0, "expired srv mail not fetched")
end

function T.city_reward_once_survives_unload_and_mail_deletion()
	local t = setup()
	local source = "city:5000000000001234"
	assert(t.M.send_user_mail_once(2, source, 1, 4, {"洛阳攻城", "1"}, {item(1, 100)}))
	assert(not orm.get("user_mail_col", 2))
	t.M.send_user_mail_once(2, source, 1, 4, {"洛阳攻城", "1"}, {item(1, 100)})
	t.online(2)
	local list = t.list(2, 1)
	assert(#list == 1)
	t.M.take_rewards(2, {})
	t.req(2, "c2s_del_mail_list", {mailKind = 1, mailUidList = {list[1].mailUid}})
	t.offline(2)
	t.M.send_user_mail_once(2, source, 1, 4, {"洛阳攻城", "1"}, {item(1, 100)})
	t.online(2)
	assert(#t.list(2, 1) == 0, "删信不删除发奖去重水位")
	t.M.send_user_mail_once(2, source, 2, 4, {"洛阳攻城", "2"}, {item(2, 50)})
	assert(#t.list(2, 1) == 1)
end

function T.city_reward_database_failure_retains_one_mail_until_retry()
	local t = setup()
	t.online(1)
	local flush = t.shared.MONGO_SLAVE.flush_sync
	t.shared.MONGO_SLAVE.flush_sync = function() error("db unavailable") end
	assert(not pcall(t.M.send_user_mail_once, 1, "city:101", 1, 4, {"城池", "1"}, {item(1, 99)}))
	assert(not t.last(1, "s2c_sync_mail"), "失败写盘不能先向客户端宣称已发奖")
	t.shared.MONGO_SLAVE.flush_sync = flush
	t.M.send_user_mail_once(1, "city:101", 1, 4, {"城池", "1"}, {item(1, 99)})
	t.offline(1)
	t.online(1)
	assert(#t.list(1, 1) == 1)
	assert(t.M.take_rewards(1, {}).rewards[1].item_count == 99)
	assert(#t.M.take_rewards(1, {}).rewards == 0)
end

return T
