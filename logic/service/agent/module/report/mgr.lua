local function get_doc(user_id)
	return ORM.load(MONGO_SLAVE.COL.USER_REPORT, user_id, ORM.CLS_USER_REPORT_DOC)
end

local function sorted_ids(doc)
	local ids = {}
	for id in pairs(doc._reports) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

local function trim(doc)
	local ids = sorted_ids(doc)
	for i = 1, #ids - CONST.REPORT_MAX do
		doc._reports[ids[i]] = nil
	end
end

-- count 在存档里是可用 + 伤兵，协议里的 count 只计可用兵力
local function soldier_pto(count, hurt)
	hurt = hurt or 0
	local healthy = count - hurt
	if healthy < 0 then
		healthy = 0
	end
	return {count = healthy, hurtCount = hurt}
end

local function brief_pto(r)
	return {
		reportId = r._report_id,
		reportType = r._report_type,
		targetType = r._target_type,
		targetId = r._target_id,
		result = r._result,
		time = r._time,
		isRead = r._is_read,
		pos = {x = r._x, y = r._y},
		atkPower = r._atk_side._power,
		defPower = r._def_side._power,
	}
end

local function side_pto(s)
	local units = {}
	for _, u in ipairs(s._units) do
		units[#units + 1] = {
			pos = u._pos,
			cfgId = u._cfg_id,
			level = u._level,
			beforeSoldier = soldier_pto(u._before_count, u._before_hurt),
			afterSoldier = soldier_pto(u._after_count, u._after_hurt),
		}
	end
	return {ownerId = s._owner_id, name = s._name, power = s._power, units = units}
end

local function replay_pto(r)
	local actions = {}
	for _, act in ipairs(r._actions) do
		local effects = {}
		for _, eff in ipairs(act._effects) do
			effects[#effects + 1] = {
				targetSide = eff._target_side,
				targetPos = eff._target_pos,
				value = eff._value,
				afterSoldier = eff._after_soldier,
				flags = eff._flags,
			}
		end
		actions[#actions + 1] = {
			round = act._round,
			actType = act._act_type,
			fromSide = act._from_side,
			fromPos = act._from_pos,
			skillId = act._skill_id,
			effects = effects,
		}
	end
	return {maxRound = r._max_round, actions = actions}
end

function reward_pto_list(rewards)
	local list = {}
	for _, rw in ipairs(rewards) do
		list[#list + 1] = {rewardType = rw._reward_type, itemId = rw._item_id, itemCount = rw._item_count}
	end
	return list
end

-- report 是 report_data 的字段（不含 _report_id），返回存好的战报
function add_report(user_id, report)
	local doc = get_doc(user_id)
	local report_id = doc._next_id + 1
	doc._next_id = report_id
	report._report_id = report_id
	doc._reports[report_id] = report
	trim(doc)
	local saved = doc._reports[report_id]
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if fd then
		for_caller.s2c_sync_report(fd, {reportBrief = brief_pto(saved)})
	end
	return saved
end

local function on_req_report_list(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local doc = get_doc(user_id)
	local ids = sorted_ids(doc)
	local list = {}
	for i = #ids, 1, -1 do
		local r = doc._reports[ids[i]]
		if packet.reportType == 0 or r._report_type == packet.reportType then
			list[#list + 1] = brief_pto(r)
		end
	end
	for_caller.s2c_req_report_list(fd, {reportList = list})
end

local function on_req_report_detail(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local r = get_doc(user_id)._reports[packet.reportId]
	if not r then
		return
	end
	for_caller.s2c_req_report_detail(fd, {
		reportInfo = {
			brief = brief_pto(r),
			atkSide = side_pto(r._atk_side),
			defSide = side_pto(r._def_side),
			rewardList = reward_pto_list(r._rewards),
			replay = replay_pto(r),
		},
	})
end

local function on_req_report_replay(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local r = get_doc(user_id)._reports[packet.reportId]
	if not r then
		return
	end
	for_caller.s2c_req_report_replay(fd, {reportId = r._report_id, replay = replay_pto(r)})
end

local function on_read_report(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local doc = get_doc(user_id)
	local ids = packet.reportIdList
	if #ids == 0 then
		ids = sorted_ids(doc)
	end
	local done = {}
	for _, id in ipairs(ids) do
		local r = doc._reports[id]
		if r and not r._is_read then
			r._is_read = true
			done[#done + 1] = id
		end
	end
	for_caller.s2c_read_report(fd, {reportIdList = done})
end

local function on_del_report(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local doc = get_doc(user_id)
	local done = {}
	for _, id in ipairs(packet.reportIdList) do
		if doc._reports[id] then
			doc._reports[id] = nil
			done[#done + 1] = id
		end
	end
	for_caller.s2c_del_report(fd, {reportIdList = done})
end

function on_user_logout(user_id)
	if ORM.get(MONGO_SLAVE.COL.USER_REPORT, user_id) then
		MONGO_SLAVE.flush()
		ORM.unbind(MONGO_SLAVE.COL.USER_REPORT, user_id)
	end
end

function __init__()
	for_maker.c2s_req_report_list = on_req_report_list
	for_maker.c2s_req_report_detail = on_req_report_detail
	for_maker.c2s_req_report_replay = on_req_report_replay
	for_maker.c2s_read_report = on_read_report
	for_maker.c2s_del_report = on_del_report
	EVENT.listen(CONST.EVENT.ON_USER_LOGOUT)
end
