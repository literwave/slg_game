-- union 服务：联盟（alliance/mgr.lua）+ 聊天（chat/mgr.lua），用真实 ORM 和配置表，发包记下来检查

local orm = require "orm"
local typedef = require "orm.typedef"

local function load_conf(name)
	local r = {}
	for _, row in ipairs(dofile("game_common/server/res/" .. name .. ".lua")) do
		r[row.Id] = row
	end
	return r
end

local function enum_members(conf)
	local r = {}
	for _, id in pairs(conf) do
		r[id] = true
	end
	return r
end

local ALLIANCE_LV = load_conf("AllianceLv")
local JOIN_TYPE = dofile("game_common/server/enum/AllianceJoinTypeEnum.lua")
local CHANNEL = dofile("game_common/server/enum/ChatChannelEnum.lua")
local GLOBAL = load_conf("Global")

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end

local function init_orm()
	if orm.inited then
		return
	end
	local list = {}
	for _, item in ipairs(typedef.parse("alliance.td", "orm/schema")) do
		list[#list + 1] = item
	end
	orm.init(list)
end

local function setup(opts)
	opts = opts or {}
	init_orm()
	orm.drain()
	local clock = {now = 1000}
	local sent = {}
	local mongo = {saved = opts.saved or {}, deleted = {}}
	mongo.chat = opts.chat_saved or {sequence = 0}
	mongo.chat_reads = 0
	local costs = {}
	local mails = {}
	local rank_scores = {}
	local CONST = setmetatable({}, {__index = _G})
	assert(loadfile("logic/define/const.lua", "t", CONST))()
	-- union 回 agent 扣令牌；opts.cost_fail 模拟令牌不足
	local skynet_stub = {
		error = function() end,
		localname = function() return ".activity" end,
		timeout = function(_, fn) fn() end,
		send = function(_, _, cmd, rank_type, aid, score, name)
			if cmd == "set_score" then rank_scores[aid] = {type=rank_type,score=score,name=name} end
		end,
		call = function(_, _, cmd, user_id, cost_list)
			if cmd == "get_agent_list" then
				return {"agent"}
			end
			if cmd == "cost_items" then
				if opts.cost_fail then
					return false
				end
				costs[#costs + 1] = {uid = user_id, cost = cost_list[1]}
				return true
			end
		end,
	}
	local function mail_of(uid, mail_id, details)
		mails[#mails + 1] = {uid = uid, mail_id = mail_id, details = details}
	end
	local shared = {
		CONST = CONST,
		EMPTY_TABLE = {},
		require = function(name)
			if name == "skynet" then
				return skynet_stub
			end
			if name == "skynet.queue" then
				return function() return function(fn, ...) return fn(...) end end
			end
			return require(name)
		end,
		MAIL = {
			send_user_mail = mail_of,
			send_group_mail = function(uid_list, mail_id, details)
				for _, uid in ipairs(uid_list) do
					mail_of(uid, mail_id, details)
				end
			end,
		},
		TIME = {os_bj_sec = function() return clock.now end},
		DATA_COMMON = {
			ALLIANCE_POS = dofile("game_common/server/enum/AlliancePosEnum.lua"),
			ALLIANCE_JOIN_TYPE = JOIN_TYPE,
			CHAT_CHANNEL = CHANNEL,
			RANK_TYPE = dofile("game_common/server/enum/RankTypeEnum.lua"),
			get_alliance_lv_conf = function(lv) return ALLIANCE_LV[lv] end,
			get_alliance_join_type_conf = function(t) return enum_members(JOIN_TYPE)[t] end,
			get_chat_channel_conf = function(c) return enum_members(CHANNEL)[c] end,
			get_chat_history_max = function() return opts.history_max or 100 end,
			get_alliance_create_cost = function() return GLOBAL[10].value1 end,
			get_alliance_name_max_len = function() return GLOBAL[11].value1 end,
			get_alliance_notice_max_len = function() return GLOBAL[12].value1 end,
			get_alliance_manifesto_max_len = function() return GLOBAL[13].value1 end,
			get_alliance_apply_max = function() return GLOBAL[14].value1 end,
		},
		ORM = {
			CLS_ALLIANCE_DATA = "alliance_data",
			new = orm.new,
			bind = orm.bind,
			unbind = orm.unbind,
			touch = orm.touch,
		},
		MONGO_SLAVE = {
			COL = {ALLIANCE = "alliance_col", USER_INFO = "user_info_col", CHAT = "chat_history_col"},
			system_startup = function() end,
			flush = function()
				for _, doc in ipairs(orm.drain()) do
					mongo.saved[doc.key] = doc.dat
				end
			end,
			del_doc = function(col, key)
				if col == "chat_history_col" then mongo.chat[key] = nil; return end
				mongo.saved[key] = nil
				mongo.deleted[key] = true
			end,
			common_load_tbl = function() return mongo.saved end,
			common_load_single = function(col, key)
				if col == "chat_history_col" then
					mongo.chat_reads = mongo.chat_reads + 1
					if opts.read_fail then error("read failed") end
					return copy(mongo.chat[key])
				end
				return opts.db_users and opts.db_users[key]
			end,
			save_doc = function(_, key, doc) mongo.chat[key] = copy(doc) end,
			flush_sync = function() if opts.write_fail then error("write failed") end end,
			append_chat = function(key, msg)
				if opts.write_fail then error("write failed") end
				mongo.chat.sequence = mongo.chat.sequence + 1
				msg.msgId = mongo.chat.sequence
				local doc = mongo.chat[key] or {messages = {}}
				doc.messages[#doc.messages + 1] = copy(msg)
				while #doc.messages > (opts.history_max or 100) do table.remove(doc.messages, 1) end
				mongo.chat[key] = doc
				return copy(msg)
			end,
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
	shared.USER_MGR = load_mod("logic/service/union/module/user/mgr.lua")
	shared.CHAT_MGR = load_mod("logic/service/union/module/chat/mgr.lua")
	shared.ALLIANCE_MGR = load_mod("logic/service/union/module/alliance/mgr.lua")
	shared.ALLIANCE_MGR.__init__()
	shared.CHAT_MGR.__init__()
	local U = shared.USER_MGR

	local api = {shared = shared, sent = sent, clock = clock, mongo = mongo, costs = costs, mails = mails, rank_scores = rank_scores}
	-- fd 直接用 uid，方便看发给了谁
	function api.online(uid, power)
		U.on_user_login(uid, uid, "gate")
		U.update_brief({uid = uid, name = "p" .. uid, head_icon = 1, level = 1, power = power or 100})
	end
	function api.req(uid, pto, packet)
		U.update_brief(U.get_brief(uid))
		shared.for_maker[pto](uid, packet or {})
	end
	function api.last(uid, name)
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.uid == uid and (not name or s.name == name) then
				return s.msg, s.name
			end
		end
	end
	function api.clear()
		for i = #sent, 1, -1 do
			sent[i] = nil
		end
	end
	return api
end

local A = {}

local function create(t, uid, name, join_type)
	t.req(uid, "c2s_create_alliance", {name = name or "盟" .. uid, flag = 1, joinType = join_type or 1, notice = ""})
	return t.last(uid, "s2c_create_alliance").info.brief.allianceId
end

function A.create_and_free_join()
	local t = setup()
	t.online(1)
	t.online(2)
	local aid = create(t, 1)
	assert(aid == 1)
	assert(t.last(1, "s2c_sync_my_alliance").myPos == 1)
	t.req(2, "c2s_apply_alliance", {allianceId = aid})
	assert(t.last(2, "s2c_apply_alliance").allianceId == aid)
	local my = t.last(2, "s2c_sync_my_alliance")
	assert(my.allianceId == aid and my.myPos == 3)
	local change = t.last(1, "s2c_sync_member_change")
	assert(change.changeType == 1 and change.member.uid == 2)
	t.req(1, "c2s_req_my_alliance")
	assert(t.last(1, "s2c_req_my_alliance").info.brief.memberCount == 2)
end

function A.create_costs_token()
	local t = setup()
	t.online(1)
	create(t, 1, "甲")
	local c = t.costs[1]
	assert(#t.costs == 1 and c.uid == 1)
	assert(c.cost.itemId == 100 and c.cost.count == 100 and c.cost.cost_type == t.shared.CONST.COST_TYPE.ITEM)
end

function A.create_fail_keeps_name_free()
	local t = setup({cost_fail = true})
	t.online(1)
	t.req(1, "c2s_create_alliance", {name = "甲", flag = 1, joinType = 1, notice = ""})
	assert(t.last(1, "s2c_tell_me").msg == "令牌不足")
	assert(not t.last(1, "s2c_create_alliance"))
	assert(not next(t.shared.ALLIANCE_MGR.creating_names) and not next(t.shared.ALLIANCE_MGR.creating_users))
	assert(t.shared.ALLIANCE_MGR.can_join(1))
end

function A.member_mails()
	local t = setup()
	for uid = 1, 3 do
		t.online(uid)
	end
	local aid = create(t, 1, "甲")
	local MAIL_ID = t.shared.CONST.MAIL_ID
	t.req(2, "c2s_apply_alliance", {allianceId = aid})
	t.req(3, "c2s_apply_alliance", {allianceId = aid})
	local m = t.mails[#t.mails]
	assert(m.uid == 3 and m.mail_id == MAIL_ID.ALLIANCE_JOIN and m.details[1] == "甲")
	t.req(1, "c2s_set_member_pos", {uid = 2, pos = 2})
	m = t.mails[#t.mails]
	assert(m.uid == 2 and m.mail_id == MAIL_ID.ALLIANCE_POS and m.details[2] == "2")
	t.req(3, "c2s_leave_alliance")
	m = t.mails[#t.mails]
	assert(m.uid == 3 and m.mail_id == MAIL_ID.ALLIANCE_LEAVE)
	local n = #t.mails
	t.req(1, "c2s_dissolve_alliance")
	assert(#t.mails == n + 2, "dissolve mails leader and remaining member")
end

function A.name_unique_and_length()
	local t = setup()
	t.online(1)
	t.online(2)
	create(t, 1, "同名")
	t.req(2, "c2s_create_alliance", {name = "同名", flag = 1, joinType = 1, notice = ""})
	assert(t.last(2, "s2c_tell_me").msg == "联盟名字已被使用")
	t.req(2, "c2s_create_alliance", {name = "一二三四五六七八九", flag = 1, joinType = 1})
	assert(t.last(2, "s2c_tell_me").msg == "联盟设置不合法")
	t.req(2, "c2s_create_alliance", {name = "ok", flag = 1, joinType = 9})
	assert(t.last(2, "s2c_tell_me").msg == "联盟设置不合法")
end

function A.apply_approve_flow()
	local t = setup()
	for uid = 1, 4 do
		t.online(uid)
	end
	local aid = create(t, 1, nil, 2)
	t.req(2, "c2s_apply_alliance", {allianceId = aid})
	t.req(3, "c2s_apply_alliance", {allianceId = aid})
	assert(not t.last(2, "s2c_sync_my_alliance"), "apply mode does not join directly")
	t.req(4, "c2s_req_apply_list")
	assert(not t.last(4, "s2c_req_apply_list"), "outsider can not see applies")
	t.req(1, "c2s_req_apply_list")
	assert(#t.last(1, "s2c_req_apply_list").applyList == 2)
	t.req(1, "c2s_handle_apply", {uid = 2, agree = true})
	assert(t.last(2, "s2c_sync_my_alliance").allianceId == aid)
	t.req(1, "c2s_handle_apply", {uid = 3})
	assert(t.last(1, "s2c_handle_apply").agree == false)
	assert(not t.last(3, "s2c_sync_my_alliance"))
	t.req(1, "c2s_req_apply_list")
	assert(#t.last(1, "s2c_req_apply_list").applyList == 0)
end

function A.join_clears_other_applies()
	local t = setup()
	for uid = 1, 3 do
		t.online(uid)
	end
	local a1 = create(t, 1, "甲", 2)
	local a2 = create(t, 2, "乙", 1)
	t.req(3, "c2s_apply_alliance", {allianceId = a1})
	t.req(3, "c2s_apply_alliance", {allianceId = a2})
	assert(t.last(3, "s2c_sync_my_alliance").allianceId == a2)
	t.req(1, "c2s_req_apply_list")
	assert(#t.last(1, "s2c_req_apply_list").applyList == 0, "apply to a1 removed after joining a2")
end

function A.kick_rules()
	local t = setup()
	for uid = 1, 4 do
		t.online(uid)
	end
	local aid = create(t, 1)
	for uid = 2, 4 do
		t.req(uid, "c2s_apply_alliance", {allianceId = aid})
	end
	t.req(1, "c2s_set_member_pos", {uid = 2, pos = 2})
	assert(t.last(2, "s2c_sync_my_alliance").myPos == 2)
	t.req(3, "c2s_kick_member", {uid = 4})
	assert(t.last(3, "s2c_tell_me").msg == "没有权限", "member can not kick")
	t.req(2, "c2s_kick_member", {uid = 1})
	assert(t.last(2, "s2c_tell_me").msg == "没有权限", "officer can not kick leader")
	t.req(2, "c2s_kick_member", {uid = 4})
	assert(t.last(2, "s2c_kick_member").uid == 4)
	assert(t.last(4, "s2c_sync_my_alliance").allianceId == 0)
	assert(t.last(1, "s2c_sync_member_change").changeType == 3)
end

function A.officer_cap()
	local t = setup()
	for uid = 1, 5 do
		t.online(uid)
	end
	local aid = create(t, 1)
	for uid = 2, 5 do
		t.req(uid, "c2s_apply_alliance", {allianceId = aid})
	end
	t.req(1, "c2s_set_member_pos", {uid = 2, pos = 2})
	t.req(1, "c2s_set_member_pos", {uid = 3, pos = 2})
	t.req(1, "c2s_set_member_pos", {uid = 4, pos = 2})
	assert(t.last(1, "s2c_tell_me").msg == "官员人数已满", "lv1 OfficerMax = 2")
	t.req(1, "c2s_set_member_pos", {uid = 4, pos = 1})
	assert(t.last(4, "s2c_sync_my_alliance").myPos == 3, "can not set leader directly")
end

function A.transfer_and_leave()
	local t = setup()
	t.online(1)
	t.online(2)
	local aid = create(t, 1)
	t.req(2, "c2s_apply_alliance", {allianceId = aid})
	t.req(1, "c2s_leave_alliance")
	assert(t.last(1, "s2c_tell_me").msg == "盟主需要先转让盟主或解散联盟")
	t.req(1, "c2s_transfer_leader", {uid = 2})
	assert(t.last(2, "s2c_sync_my_alliance").myPos == 1)
	assert(t.last(1, "s2c_sync_my_alliance").myPos == 3, "old leader takes the new leader's old pos")
	assert(t.last(1, "s2c_sync_alliance").info.leaderId == 2)
	t.req(1, "c2s_leave_alliance")
	assert(t.last(1, "s2c_sync_my_alliance").allianceId == 0)
	assert(t.last(2, "s2c_sync_member_change").changeType == 2)
end

function A.member_full()
	local t = setup()
	t.online(1)
	local aid = create(t, 1)
	for uid = 2, 31 do
		t.online(uid)
		t.req(uid, "c2s_apply_alliance", {allianceId = aid})
	end
	assert(t.last(30, "s2c_sync_my_alliance").allianceId == aid)
	assert(t.last(31, "s2c_tell_me").msg == "联盟人数已满", "lv1 MemberMax = 30")
end

function A.invite_flow()
	local t = setup()
	t.online(1)
	t.online(2)
	local aid = create(t, 1, nil, 3)
	t.req(2, "c2s_handle_invite", {allianceId = aid, agree = true})
	assert(t.last(2, "s2c_tell_me").msg == "邀请已失效")
	t.req(1, "c2s_invite_alliance", {uid = 2})
	local inv = t.last(2, "s2c_sync_alliance_invite")
	assert(inv.brief.allianceId == aid and inv.inviterId == 1)
	t.req(2, "c2s_handle_invite", {allianceId = aid, agree = true})
	assert(t.last(2, "s2c_sync_my_alliance").allianceId == aid, "invite bypasses closed join type")
end

function A.invite_expire()
	local t = setup()
	t.online(1)
	t.online(2)
	local aid = create(t, 1)
	t.req(1, "c2s_invite_alliance", {uid = 2})
	t.clock.now = t.clock.now + 86401
	t.req(2, "c2s_handle_invite", {allianceId = aid, agree = true})
	assert(t.last(2, "s2c_tell_me").msg == "邀请已失效")
end

function A.dissolve_persist_and_reload()
	local t = setup()
	for uid = 1, 3 do
		t.online(uid)
	end
	local a1 = create(t, 1, "留下")
	local a2 = create(t, 2, "解散")
	t.req(3, "c2s_apply_alliance", {allianceId = a2})
	t.req(1, "c2s_set_alliance_info", {flag = 7, joinType = 2, notice = "公告", manifesto = "宣言"})
	t.shared.MONGO_SLAVE.flush()
	assert(t.mongo.saved[a1]._notice == "公告")
	t.req(2, "c2s_dissolve_alliance")
	assert(t.last(3, "s2c_sync_my_alliance").allianceId == 0)
	assert(t.mongo.deleted[a2] and not t.mongo.saved[a2])
	t.req(3, "c2s_create_alliance", {name = "解散", flag = 1, joinType = 1, notice = ""})
	assert(t.last(3, "s2c_create_alliance"), "dissolved name is free again")
	t.shared.MONGO_SLAVE.flush()

	local t2 = setup({saved = t.mongo.saved})
	t2.online(1)
	t2.req(1, "c2s_req_my_alliance")
	local info = t2.last(1, "s2c_req_my_alliance").info
	assert(info.brief.allianceId == a1 and info.manifesto == "宣言" and info.brief.joinType == 2)
	t2.online(9)
	assert(create(t2, 9) == 4, "new id continues after max loaded id")
end

function A.list_sort_and_member_offline()
	local t = setup()
	t.online(1, 100)
	t.online(2, 500)
	t.online(3, 50)
	create(t, 1, "弱", 1)
	create(t, 2, "强", 3)
	create(t, 3, "中", 1)
	t.req(1, "c2s_req_alliance_list", {})
	local list = t.last(1, "s2c_req_alliance_list").allianceList
	assert(list[1].name == "弱" and list[2].name == "中" and list[3].name == "强", "closed sinks, then by power")
	t.req(1, "c2s_req_alliance_list", {keyword = "强"})
	assert(#t.last(1, "s2c_req_alliance_list").allianceList == 1)
	t.req(1, "c2s_req_alliance_list", {start = 2, count = 1})
	assert(t.last(1, "s2c_req_alliance_list").allianceList[1].name == "中")

	t.clock.now = 5000
	t.shared.USER_MGR.on_user_logout(1, 1)
	t.shared.ALLIANCE_MGR.on_user_logout(1)
	t.req(2, "c2s_req_member_list", {allianceId = 1})
	assert(t.last(2, "s2c_req_member_list").memberList[1].offlineTime == 5000)
end

function A.brief_refresh_updates_member()
	local t = setup()
	t.online(1, 100)
	local aid = create(t, 1)
	t.shared.ALLIANCE_MGR.on_brief_change({uid = 1, name = "新名", head_icon = 3, level = 9, power = 999})
	t.req(1, "c2s_req_alliance_info", {allianceId = aid})
	local brief = t.last(1, "s2c_req_alliance_info").info.brief
	assert(brief.leaderName == "新名" and brief.power == 999)
	assert(t.rank_scores[aid].type == 4 and t.rank_scores[aid].score == 999)
	t.req(1, "c2s_dissolve_alliance")
	assert(t.rank_scores[aid].score == 0, "解散联盟移出实力榜")
end

function A.chat_channels()
	local t = setup({db_users = {[7] = {}}})
	for uid = 1, 3 do
		t.online(uid)
	end
	local aid = create(t, 1)
	t.req(2, "c2s_apply_alliance", {allianceId = aid})
	t.req(1, "c2s_chat", {channel = 1, content = "大家好"})
	assert(t.last(1, "s2c_chat").msg.content == "大家好")
	assert(t.last(3, "s2c_sync_chat").msg.senderName == "p1")
	assert(not t.last(1, "s2c_sync_chat"), "sender gets s2c_chat only")
	t.clock.now = t.clock.now + 1
	t.req(1, "c2s_chat", {channel = 2, content = "盟友好"})
	assert(t.last(2, "s2c_sync_chat").msg.channel == 2)
	assert(t.last(3, "s2c_sync_chat").msg.channel == 1, "outsider not in alliance channel")
	t.req(3, "c2s_chat", {channel = 2, content = "x"})
	assert(t.last(3, "s2c_tell_me").msg == "还没有加入联盟")
	t.req(3, "c2s_chat", {channel = 3, content = "悄悄话", targetId = 2})
	assert(t.last(2, "s2c_sync_chat").msg.targetId == 2)
	t.clock.now = t.clock.now + 1
	t.req(3, "c2s_chat", {channel = 3, content = "离线也能发", targetId = 7})
	assert(t.last(3, "s2c_chat"), "offline target found in db")
	t.clock.now = t.clock.now + 1
	t.req(3, "c2s_chat", {channel = 3, content = "?", targetId = 8})
	assert(t.last(3, "s2c_tell_me").msg == "玩家不存在")
	t.req(2, "c2s_req_chat_list", {channel = 3, targetId = 3})
	local hist = t.last(2, "s2c_req_chat_list")
	assert(#hist.msgList == 1 and hist.msgList[1].content == "悄悄话")
end

function A.chat_limits_and_history_trim()
	local t = setup({history_max = 3})
	t.online(1)
	t.req(1, "c2s_chat", {channel = 1, content = ""})
	assert(t.last(1, "s2c_tell_me").msg == "聊天内容长度不合法")
	t.req(1, "c2s_chat", {channel = 1, content = "1"})
	t.req(1, "c2s_chat", {channel = 1, content = "2"})
	assert(t.last(1, "s2c_tell_me").msg == "发言太快了")
	for i = 3, 6 do
		t.clock.now = t.clock.now + 1
		t.req(1, "c2s_chat", {channel = 1, content = tostring(i)})
	end
	t.req(1, "c2s_req_chat_list", {channel = 1})
	local list = t.last(1, "s2c_req_chat_list").msgList
	assert(#list == 3 and list[1].content == "4" and list[3].content == "6")
end

function A.chat_restart_retains_channels_and_private_access()
	local t = setup()
	for uid = 1, 3 do t.online(uid) end
	local aid = create(t, 1)
	t.req(2, "c2s_apply_alliance", {allianceId = aid})
	t.req(1, "c2s_chat", {channel = 1, content = "world"})
	t.clock.now = t.clock.now + 1
	t.req(1, "c2s_chat", {channel = 2, content = "alliance"})
	t.req(2, "c2s_chat", {channel = 3, targetId = 1, content = "private"})
	local last_id = t.last(2, "s2c_chat").msg.msgId
	t.shared.MONGO_SLAVE.flush()
	local u = setup({saved = t.mongo.saved, chat_saved = t.mongo.chat})
	for uid = 1, 3 do u.online(uid) end
	assert(u.mongo.chat_reads == 0, "startup must not scan private conversations")
	for channel, text in ipairs({"world", "alliance", "private"}) do
		u.req(1, "c2s_req_chat_list", {channel = channel, targetId = 2})
		assert(u.last(1, "s2c_req_chat_list").msgList[1].content == text)
	end
	u.req(3, "c2s_req_chat_list", {channel = 2})
	assert(#u.last(3, "s2c_req_chat_list").msgList == 0)
	u.req(3, "c2s_req_chat_list", {channel = 3, targetId = 1})
	assert(#u.last(3, "s2c_req_chat_list").msgList == 0, "outsider cannot read another pair")
	u.req(1, "c2s_chat", {channel = 1, content = "after restart"})
	assert(u.last(1, "s2c_chat").msg.msgId > last_id)
	u.req(1, "c2s_dissolve_alliance")
	assert(not u.mongo.chat["alliance:" .. aid])
end

function A.chat_failed_write_is_not_acknowledged_or_broadcast()
	local opts = {write_fail = true}
	local t = setup(opts)
	t.online(1); t.online(2)
	t.req(1, "c2s_chat", {channel = 1, content = "retry later"})
	assert(not t.last(1, "s2c_chat") and not t.last(2, "s2c_sync_chat"))
	assert(#t.shared.CHAT_MGR.world_hist == 0)
	assert(t.last(1, "s2c_tell_me"))
	opts.write_fail = false
	t.req(1, "c2s_chat", {channel = 1, content = "saved"})
	assert(t.last(1, "s2c_chat").msg.content == "saved")
end

function A.chat_failed_read_does_not_poison_cache()
	local opts = {read_fail = true, chat_saved = {sequence = 1,
		world = {messages = {{msgId = 1, content = "existing"}}}}}
	local t = setup(opts); t.online(1)
	t.req(1, "c2s_req_chat_list", {channel = 1})
	assert(not t.last(1, "s2c_req_chat_list"), "read failure must not appear as empty history")
	opts.read_fail = false
	t.req(1, "c2s_req_chat_list", {channel = 1})
	assert(t.last(1, "s2c_req_chat_list").msgList[1].content == "existing")
end

function A.chat_hot_upgrade_saves_old_memory_once()
	local t = setup(); t.online(1)
	local chat = t.shared.CHAT_MGR
	chat.world_hist = {{msgId = 99, content = "old process"}}
	chat.__init__()
	assert(t.mongo.chat.world.messages[1].content == "old process")
	chat.__init__()
	assert(#t.mongo.chat.world.messages == 1)
end

return A
