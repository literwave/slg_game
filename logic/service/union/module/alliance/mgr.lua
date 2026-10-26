-- 联盟：每个联盟一份文档，启动时全部加载，玩家归属、申请、重名索引都在内存里重建
-- 邀请只存内存，重启后失效

local skynet = require "skynet"

local CHANGE = CONST.ALLIANCE_CHANGE

-- 模块变量热更时保留，loaded 防止热更后重复加载
-- [alliance_id] = alliance_data
alliance_tbl = {}
-- [user_id] = alliance_id
user_alliance = {}
-- [user_id] = {[alliance_id] = true}
user_applies = {}
-- [name] = alliance_id
name_tbl = {}
-- [user_id] = {[alliance_id] = {inviter_id, inviter_name, time}}
invite_tbl = {}
-- 创建中（等 agent 扣令牌）：[name] = user_id，[user_id] = true
creating_names = {}
creating_users = {}
max_id = 0
loaded = false

local function now()
	return TIME.os_bj_sec()
end

local function utf8_len_ok(s, min, max)
	local len = utf8.len(s)
	return len and len >= min and len <= max
end

function can_join(user_id)
	return not user_alliance[user_id] and not creating_users[user_id]
end

function get_user_alliance(user_id)
	local alliance_id = user_alliance[user_id]
	return alliance_id and alliance_tbl[alliance_id]
end

local function member_count(doc)
	local n = 0
	for _ in pairs(doc._members) do
		n = n + 1
	end
	return n
end

local function member_max(doc)
	local conf = DATA_COMMON.get_alliance_lv_conf(doc._level)
	return conf and conf.MemberMax or 0
end

local function officer_max(doc)
	local conf = DATA_COMMON.get_alliance_lv_conf(doc._level)
	return conf and conf.OfficerMax or 0
end

local function officer_count(doc)
	local n = 0
	for _, m in pairs(doc._members) do
		if m._pos == DATA_COMMON.ALLIANCE_POS.OFFICER then
			n = n + 1
		end
	end
	return n
end

local function is_full(doc)
	return member_count(doc) >= member_max(doc)
end

local function is_manager(member)
	return member and (member._pos == DATA_COMMON.ALLIANCE_POS.LEADER or member._pos == DATA_COMMON.ALLIANCE_POS.OFFICER)
end

local function total_power(doc)
	local sum = 0
	for _, m in pairs(doc._members) do
		sum = sum + m._power
	end
	return sum
end

local function brief_pto(doc)
	local leader = doc._members[doc._leader_id]
	return {
		allianceId = doc._alliance_id,
		name = doc._name,
		flag = doc._flag,
		level = doc._level,
		memberCount = member_count(doc),
		memberMax = member_max(doc),
		power = total_power(doc),
		joinType = doc._join_type,
		notice = doc._notice,
		leaderName = leader and leader._name or "",
	}
end

local function info_pto(doc)
	return {
		brief = brief_pto(doc),
		manifesto = doc._manifesto,
		leaderId = doc._leader_id,
		createTime = doc._create_time,
	}
end

local function member_pto(m)
	return {
		uid = m._uid,
		name = m._name,
		headIcon = m._head_icon,
		pos = m._pos,
		level = m._level,
		power = m._power,
		joinTime = m._join_time,
		offlineTime = USER_MGR.is_online(m._uid) and 0 or m._offline_time,
	}
end

local function apply_pto(a)
	return {
		uid = a._uid,
		name = a._name,
		headIcon = a._head_icon,
		level = a._level,
		power = a._power,
		time = a._time,
	}
end

local function broadcast(doc, pto_name, msg, except_uid)
	for uid in pairs(doc._members) do
		if uid ~= except_uid then
			USER_MGR.send(uid, pto_name, msg)
		end
	end
end

local function sync_my(user_id)
	local doc = get_user_alliance(user_id)
	if not doc then
		USER_MGR.send(user_id, "s2c_sync_my_alliance", {allianceId = 0, myPos = 0})
		return
	end
	USER_MGR.send(user_id, "s2c_sync_my_alliance", {
		allianceId = doc._alliance_id,
		myPos = doc._members[user_id]._pos,
		info = info_pto(doc),
	})
end

local function sync_alliance(doc)
	broadcast(doc, "s2c_sync_alliance", {info = info_pto(doc)})
end

local function member_change(doc, change_type, member_msg)
	broadcast(doc, "s2c_sync_member_change", {
		allianceId = doc._alliance_id,
		changeType = change_type,
		member = member_msg,
	})
end

local function remove_apply(alliance_id, user_id)
	local doc = alliance_tbl[alliance_id]
	if doc then
		doc._applies[user_id] = nil
	end
	local set = user_applies[user_id]
	if set then
		set[alliance_id] = nil
		if not next(set) then
			user_applies[user_id] = nil
		end
	end
end

local function clear_user_applies(user_id)
	local ids = {}
	for alliance_id in pairs(user_applies[user_id] or EMPTY_TABLE) do
		ids[#ids + 1] = alliance_id
	end
	for _, alliance_id in ipairs(ids) do
		remove_apply(alliance_id, user_id)
	end
end

local function new_member(brief, pos)
	return {
		_uid = brief.uid,
		_name = brief.name,
		_head_icon = brief.head_icon,
		_pos = pos,
		_level = brief.level,
		_power = brief.power,
		_join_time = now(),
		_offline_time = 0,
	}
end

local function tell_world(user_id, alliance_id)
	skynet.send(".world", "lua", "set_user_alliance", user_id, alliance_id or 0)
end

-- 入盟后清掉他所有申请和邀请
local function join(doc, brief)
	local user_id = brief.uid
	doc._members[user_id] = new_member(brief, DATA_COMMON.ALLIANCE_POS.MEMBER)
	user_alliance[user_id] = doc._alliance_id
	tell_world(user_id, doc._alliance_id)
	clear_user_applies(user_id)
	invite_tbl[user_id] = nil
	member_change(doc, CHANGE.JOIN, member_pto(doc._members[user_id]))
	sync_alliance(doc)
	sync_my(user_id)
	MAIL.send_user_mail(user_id, CONST.MAIL_ID.ALLIANCE_JOIN, {doc._name})
end

local function remove_member(doc, user_id, change_type)
	doc._members[user_id] = nil
	user_alliance[user_id] = nil
	tell_world(user_id, 0)
	member_change(doc, change_type, {uid = user_id})
	sync_alliance(doc)
	sync_my(user_id)
	MAIL.send_user_mail(user_id, CONST.MAIL_ID.ALLIANCE_LEAVE, {doc._name})
end

-- AlliancePos 的名字只导出到前端，详情里填职位 id
local function send_pos_mail(doc, user_id, pos)
	MAIL.send_user_mail(user_id, CONST.MAIL_ID.ALLIANCE_POS, {doc._name, tostring(pos)})
end

local function index_alliance(doc)
	local alliance_id = doc._alliance_id
	alliance_tbl[alliance_id] = doc
	name_tbl[doc._name] = alliance_id
	for uid in pairs(doc._members) do
		user_alliance[uid] = alliance_id
	end
	for uid in pairs(doc._applies) do
		user_applies[uid] = user_applies[uid] or {}
		user_applies[uid][alliance_id] = true
	end
	if alliance_id > max_id then
		max_id = alliance_id
	end
end

local function check_settings(flag, join_type, notice, manifesto)
	if not DATA_COMMON.get_alliance_join_type_conf(join_type) then
		return false
	end
	if flag < 0 then
		return false
	end
	if not utf8_len_ok(notice, 0, DATA_COMMON.get_alliance_notice_max_len()) then
		return false
	end
	if manifesto and not utf8_len_ok(manifesto, 0, DATA_COMMON.get_alliance_manifesto_max_len()) then
		return false
	end
	return true
end

-- ---------- 协议 ----------

local function on_req_my_alliance(user_id)
	local doc = get_user_alliance(user_id)
	if not doc then
		USER_MGR.send(user_id, "s2c_req_my_alliance", {info = {brief = {allianceId = 0}}, myPos = 0})
		return
	end
	USER_MGR.send(user_id, "s2c_req_my_alliance", {info = info_pto(doc), myPos = doc._members[user_id]._pos})
end

local function on_req_alliance_info(user_id, packet)
	local doc = alliance_tbl[packet.allianceId or 0]
	if not doc then
		USER_MGR.tell_me(user_id, "联盟不存在")
		return
	end
	USER_MGR.send(user_id, "s2c_req_alliance_info", {info = info_pto(doc)})
end

-- 关键字为空时是推荐列表：能进的排前面，再按战力
local function on_req_alliance_list(user_id, packet)
	local keyword = packet.keyword or ""
	local start = math.max(1, packet.start or 0)
	local count = packet.count or 0
	if count == 0 or count > CONST.ALLIANCE_LIST_MAX then
		count = CONST.ALLIANCE_LIST_DEFAULT
	end
	local list = {}
	for _, doc in pairs(alliance_tbl) do
		if keyword == "" or doc._name:find(keyword, 1, true) then
			local brief = brief_pto(doc)
			brief.open = doc._join_type ~= DATA_COMMON.ALLIANCE_JOIN_TYPE.CLOSED and brief.memberCount < brief.memberMax
			list[#list + 1] = brief
		end
	end
	table.sort(list, function(a, b)
		if a.open ~= b.open then
			return a.open
		end
		if a.power ~= b.power then
			return a.power > b.power
		end
		return a.allianceId < b.allianceId
	end)
	local page = {}
	for i = start, math.min(#list, start + count - 1) do
		list[i].open = nil
		page[#page + 1] = list[i]
	end
	USER_MGR.send(user_id, "s2c_req_alliance_list", {allianceList = page})
end

local function create_cost_list()
	return {{
		cost_type = CONST.COST_TYPE.ITEM,
		itemId = CONST.ALLIANCE_CREATE_ITEM,
		count = DATA_COMMON.get_alliance_create_cost(),
	}}
end

-- 扣令牌要回 agent，期间先占住名字、标记创建中，回来后不用再查
local function on_create_alliance(user_id, packet)
	if not can_join(user_id) then
		USER_MGR.tell_me(user_id, "已有联盟")
		return
	end
	local name = packet.name or ""
	local flag = packet.flag or 0
	local join_type = packet.joinType or 0
	local notice = packet.notice or ""
	if not utf8_len_ok(name, 1, DATA_COMMON.get_alliance_name_max_len()) or not check_settings(flag, join_type, notice) then
		USER_MGR.tell_me(user_id, "联盟设置不合法")
		return
	end
	if name_tbl[name] or creating_names[name] then
		USER_MGR.tell_me(user_id, "联盟名字已被使用")
		return
	end
	creating_names[name] = user_id
	creating_users[user_id] = true
	local ok = USER_MGR.cost_items(user_id, create_cost_list(), {CONST.FLOW_REASON.ALLIANCE})
	creating_names[name] = nil
	creating_users[user_id] = nil
	if not ok then
		USER_MGR.tell_me(user_id, "令牌不足")
		return
	end
	local brief = USER_MGR.get_brief(user_id)
	local alliance_id = max_id + 1
	local doc = ORM.new(ORM.CLS_ALLIANCE_DATA, {
		_alliance_id = alliance_id,
		_name = name,
		_flag = flag,
		_level = 1,
		_exp = 0,
		_join_type = join_type,
		_notice = notice,
		_manifesto = "",
		_leader_id = user_id,
		_create_time = now(),
	})
	doc._members[user_id] = new_member(brief, DATA_COMMON.ALLIANCE_POS.LEADER)
	ORM.bind(doc, MONGO_SLAVE.COL.ALLIANCE, alliance_id)
	ORM.touch(doc)
	index_alliance(doc)
	tell_world(user_id, alliance_id)
	clear_user_applies(user_id)
	invite_tbl[user_id] = nil
	USER_MGR.send(user_id, "s2c_create_alliance", {info = info_pto(doc)})
	sync_my(user_id)
end

local function on_dissolve_alliance(user_id)
	local doc = get_user_alliance(user_id)
	if not doc or doc._leader_id ~= user_id then
		return
	end
	local alliance_id = doc._alliance_id
	local members = {}
	for uid in pairs(doc._members) do
		members[#members + 1] = uid
	end
	local applicants = {}
	for uid in pairs(doc._applies) do
		applicants[#applicants + 1] = uid
	end
	for _, uid in ipairs(applicants) do
		remove_apply(alliance_id, uid)
	end
	for _, invites in pairs(invite_tbl) do
		invites[alliance_id] = nil
	end
	alliance_tbl[alliance_id] = nil
	name_tbl[doc._name] = nil
	for _, uid in ipairs(members) do
		user_alliance[uid] = nil
		tell_world(uid, 0)
	end
	-- 先把之前的改动发出去再删，删除排在最后
	MONGO_SLAVE.flush()
	ORM.unbind(MONGO_SLAVE.COL.ALLIANCE, alliance_id)
	MONGO_SLAVE.del_doc(MONGO_SLAVE.COL.ALLIANCE, alliance_id)
	CHAT_MGR.on_alliance_dissolve(alliance_id)
	USER_MGR.send(user_id, "s2c_dissolve_alliance", {})
	MAIL.send_group_mail(members, CONST.MAIL_ID.ALLIANCE_LEAVE, {doc._name})
	for _, uid in ipairs(members) do
		sync_my(uid)
	end
end

local function on_leave_alliance(user_id)
	local doc = get_user_alliance(user_id)
	if not doc then
		return
	end
	if doc._leader_id == user_id then
		USER_MGR.tell_me(user_id, "盟主需要先转让盟主或解散联盟")
		return
	end
	remove_member(doc, user_id, CHANGE.LEAVE)
	USER_MGR.send(user_id, "s2c_leave_alliance", {})
end

-- 盟主能踢所有人，官员只能踢普通成员
local function on_kick_member(user_id, packet)
	local doc = get_user_alliance(user_id)
	local target_id = packet.uid or 0
	if not doc or target_id == user_id then
		return
	end
	local me = doc._members[user_id]
	local target = doc._members[target_id]
	if not is_manager(me) or not target or target._pos <= me._pos then
		USER_MGR.tell_me(user_id, "没有权限")
		return
	end
	remove_member(doc, target_id, CHANGE.KICK)
	USER_MGR.send(user_id, "s2c_kick_member", {uid = target_id})
end

local function on_apply_alliance(user_id, packet)
	if not can_join(user_id) then
		USER_MGR.tell_me(user_id, "已有联盟")
		return
	end
	local doc = alliance_tbl[packet.allianceId or 0]
	if not doc then
		USER_MGR.tell_me(user_id, "联盟不存在")
		return
	end
	local join_type = doc._join_type
	if join_type == DATA_COMMON.ALLIANCE_JOIN_TYPE.CLOSED then
		USER_MGR.tell_me(user_id, "该联盟不接受新成员")
		return
	end
	if is_full(doc) then
		USER_MGR.tell_me(user_id, "联盟人数已满")
		return
	end
	if join_type == DATA_COMMON.ALLIANCE_JOIN_TYPE.FREE then
		join(doc, USER_MGR.get_brief(user_id))
		USER_MGR.send(user_id, "s2c_apply_alliance", {allianceId = doc._alliance_id})
		return
	end
	if doc._applies[user_id] then
		USER_MGR.tell_me(user_id, "已经申请过了")
		return
	end
	local apply_cnt = 0
	for _ in pairs(doc._applies) do
		apply_cnt = apply_cnt + 1
	end
	if apply_cnt >= DATA_COMMON.get_alliance_apply_max() then
		USER_MGR.tell_me(user_id, "该联盟申请人数已满")
		return
	end
	local brief = USER_MGR.get_brief(user_id)
	doc._applies[user_id] = {
		_uid = user_id,
		_name = brief.name,
		_head_icon = brief.head_icon,
		_level = brief.level,
		_power = brief.power,
		_time = now(),
	}
	user_applies[user_id] = user_applies[user_id] or {}
	user_applies[user_id][doc._alliance_id] = true
	USER_MGR.send(user_id, "s2c_apply_alliance", {allianceId = doc._alliance_id})
end

local function on_cancel_apply(user_id, packet)
	local alliance_id = packet.allianceId or 0
	if not (user_applies[user_id] and user_applies[user_id][alliance_id]) then
		return
	end
	remove_apply(alliance_id, user_id)
	USER_MGR.send(user_id, "s2c_cancel_apply", {allianceId = alliance_id})
end

local function on_req_apply_list(user_id)
	local doc = get_user_alliance(user_id)
	if not doc or not is_manager(doc._members[user_id]) then
		return
	end
	local list = {}
	for _, a in pairs(doc._applies) do
		list[#list + 1] = apply_pto(a)
	end
	table.sort(list, function(a, b)
		if a.time ~= b.time then
			return a.time < b.time
		end
		return a.uid < b.uid
	end)
	USER_MGR.send(user_id, "s2c_req_apply_list", {applyList = list})
end

local function on_handle_apply(user_id, packet)
	local doc = get_user_alliance(user_id)
	local target_id = packet.uid or 0
	local agree = packet.agree or false
	if not doc or not is_manager(doc._members[user_id]) then
		return
	end
	local apply = doc._applies[target_id]
	if not apply then
		USER_MGR.tell_me(user_id, "申请已失效")
		return
	end
	local brief = USER_MGR.get_brief(target_id) or {
		uid = target_id,
		name = apply._name,
		head_icon = apply._head_icon,
		level = apply._level,
		power = apply._power,
	}
	remove_apply(doc._alliance_id, target_id)
	if agree then
		if not can_join(target_id) then
			USER_MGR.tell_me(user_id, "对方已加入其它联盟")
			return
		end
		if is_full(doc) then
			USER_MGR.tell_me(user_id, "联盟人数已满")
			return
		end
		join(doc, brief)
	end
	USER_MGR.send(user_id, "s2c_handle_apply", {uid = target_id, agree = agree})
end

local function on_invite_alliance(user_id, packet)
	local doc = get_user_alliance(user_id)
	local target_id = packet.uid or 0
	if not doc or not is_manager(doc._members[user_id]) or target_id == user_id then
		return
	end
	if user_alliance[target_id] then
		USER_MGR.tell_me(user_id, "对方已有联盟")
		return
	end
	if is_full(doc) then
		USER_MGR.tell_me(user_id, "联盟人数已满")
		return
	end
	local inviter = doc._members[user_id]
	invite_tbl[target_id] = invite_tbl[target_id] or {}
	invite_tbl[target_id][doc._alliance_id] = {inviter_id = user_id, inviter_name = inviter._name, time = now()}
	USER_MGR.send(target_id, "s2c_sync_alliance_invite", {
		brief = brief_pto(doc),
		inviterId = user_id,
		inviterName = inviter._name,
	})
	USER_MGR.send(user_id, "s2c_invite_alliance", {uid = target_id})
end

local function on_handle_invite(user_id, packet)
	local alliance_id = packet.allianceId or 0
	local agree = packet.agree or false
	local invites = invite_tbl[user_id]
	local invite = invites and invites[alliance_id]
	if not invite then
		USER_MGR.tell_me(user_id, "邀请已失效")
		return
	end
	invites[alliance_id] = nil
	if agree then
		local doc = alliance_tbl[alliance_id]
		if not doc or now() > invite.time + CONST.ALLIANCE_INVITE_EXPIRE then
			USER_MGR.tell_me(user_id, "邀请已失效")
			return
		end
		if not can_join(user_id) then
			USER_MGR.tell_me(user_id, "已有联盟")
			return
		end
		if is_full(doc) then
			USER_MGR.tell_me(user_id, "联盟人数已满")
			return
		end
		join(doc, USER_MGR.get_brief(user_id))
	end
	USER_MGR.send(user_id, "s2c_handle_invite", {allianceId = alliance_id, agree = agree})
end

local function on_req_member_list(user_id, packet)
	local alliance_id = packet.allianceId or 0
	if alliance_id == 0 then
		alliance_id = user_alliance[user_id] or 0
	end
	local doc = alliance_tbl[alliance_id]
	if not doc then
		USER_MGR.send(user_id, "s2c_req_member_list", {allianceId = alliance_id, memberList = {}})
		return
	end
	local list = {}
	for _, m in pairs(doc._members) do
		list[#list + 1] = member_pto(m)
	end
	table.sort(list, function(a, b)
		if a.pos ~= b.pos then
			return a.pos < b.pos
		end
		if a.power ~= b.power then
			return a.power > b.power
		end
		return a.uid < b.uid
	end)
	USER_MGR.send(user_id, "s2c_req_member_list", {allianceId = alliance_id, memberList = list})
end

local function on_set_alliance_info(user_id, packet)
	local doc = get_user_alliance(user_id)
	if not doc or not is_manager(doc._members[user_id]) then
		return
	end
	local flag = packet.flag or 0
	local join_type = packet.joinType or 0
	local notice = packet.notice or ""
	local manifesto = packet.manifesto or ""
	if not check_settings(flag, join_type, notice, manifesto) then
		USER_MGR.tell_me(user_id, "联盟设置不合法")
		return
	end
	doc._flag = flag
	doc._join_type = join_type
	doc._notice = notice
	doc._manifesto = manifesto
	local info = info_pto(doc)
	USER_MGR.send(user_id, "s2c_set_alliance_info", {info = info})
	broadcast(doc, "s2c_sync_alliance", {info = info}, user_id)
end

-- 只有盟主能调职位，只能在官员和成员之间调
local function on_set_member_pos(user_id, packet)
	local doc = get_user_alliance(user_id)
	local target_id = packet.uid or 0
	local pos = packet.pos or 0
	if not doc or doc._leader_id ~= user_id or target_id == user_id then
		return
	end
	if pos ~= DATA_COMMON.ALLIANCE_POS.OFFICER and pos ~= DATA_COMMON.ALLIANCE_POS.MEMBER then
		return
	end
	local target = doc._members[target_id]
	if not target or target._pos == pos then
		return
	end
	if pos == DATA_COMMON.ALLIANCE_POS.OFFICER and officer_count(doc) >= officer_max(doc) then
		USER_MGR.tell_me(user_id, "官员人数已满")
		return
	end
	target._pos = pos
	member_change(doc, CHANGE.POS, member_pto(target))
	sync_my(target_id)
	USER_MGR.send(user_id, "s2c_set_member_pos", {uid = target_id, pos = pos})
	send_pos_mail(doc, target_id, pos)
end

-- 新盟主原来的职位给老盟主，官员数不会超
local function on_transfer_leader(user_id, packet)
	local doc = get_user_alliance(user_id)
	local target_id = packet.uid or 0
	if not doc or doc._leader_id ~= user_id or target_id == user_id then
		return
	end
	local target = doc._members[target_id]
	if not target then
		return
	end
	local me = doc._members[user_id]
	me._pos = target._pos
	target._pos = DATA_COMMON.ALLIANCE_POS.LEADER
	doc._leader_id = target_id
	member_change(doc, CHANGE.POS, member_pto(target))
	member_change(doc, CHANGE.POS, member_pto(me))
	sync_alliance(doc)
	sync_my(target_id)
	sync_my(user_id)
	USER_MGR.send(user_id, "s2c_transfer_leader", {uid = target_id})
	send_pos_mail(doc, target_id, target._pos)
	send_pos_mail(doc, user_id, me._pos)
end

-- ---------- 名片刷新 / 上下线 ----------

function on_brief_change(brief)
	local user_id = brief.uid
	local doc = get_user_alliance(user_id)
	local m = doc and doc._members[user_id]
	if m then
		m._name = brief.name
		m._head_icon = brief.head_icon
		m._level = brief.level
		m._power = brief.power
	end
	for alliance_id in pairs(user_applies[user_id] or EMPTY_TABLE) do
		local a = alliance_tbl[alliance_id]._applies[user_id]
		a._name = brief.name
		a._head_icon = brief.head_icon
		a._level = brief.level
		a._power = brief.power
	end
end

function on_user_logout(user_id)
	local doc = get_user_alliance(user_id)
	if doc then
		doc._members[user_id]._offline_time = now()
	end
end

local function load_all()
	for _, dat in pairs(MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.ALLIANCE)) do
		local doc = ORM.new(ORM.CLS_ALLIANCE_DATA, dat)
		ORM.bind(doc, MONGO_SLAVE.COL.ALLIANCE, doc._alliance_id)
		index_alliance(doc)
	end
end

function __init__()
	if not loaded then
		loaded = true
		MONGO_SLAVE.system_startup()
		load_all()
	end
	for_maker.c2s_req_my_alliance = on_req_my_alliance
	for_maker.c2s_req_alliance_info = on_req_alliance_info
	for_maker.c2s_req_alliance_list = on_req_alliance_list
	for_maker.c2s_create_alliance = on_create_alliance
	for_maker.c2s_dissolve_alliance = on_dissolve_alliance
	for_maker.c2s_leave_alliance = on_leave_alliance
	for_maker.c2s_kick_member = on_kick_member
	for_maker.c2s_apply_alliance = on_apply_alliance
	for_maker.c2s_cancel_apply = on_cancel_apply
	for_maker.c2s_req_apply_list = on_req_apply_list
	for_maker.c2s_handle_apply = on_handle_apply
	for_maker.c2s_invite_alliance = on_invite_alliance
	for_maker.c2s_handle_invite = on_handle_invite
	for_maker.c2s_req_member_list = on_req_member_list
	for_maker.c2s_set_alliance_info = on_set_alliance_info
	for_maker.c2s_set_member_pos = on_set_member_pos
	for_maker.c2s_transfer_leader = on_transfer_leader
	EVENT.register(CONST.EVENT.ON_USER_LOGOUT)
end
