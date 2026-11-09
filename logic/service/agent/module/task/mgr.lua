-- 任务只存自己的进度和状态。
-- 状态类条件（登录天数、建筑等级、英雄数、道具数、战力）接取时找对应模块 get 一次当前值，之后相关事件来了再 get；
-- 累加类条件（抽卡、换头像、出征）接取时从 0 开始，事件带增量直接加

local COND_GET = {
	[CONST.TASK_COND.LOGIN] = function(user, _, task_type)
		if task_type == CONST.TASK_TYPE.DAILY then
			return user:is_login_today() and 1 or 0
		end
		if task_type == CONST.TASK_TYPE.WEEK then
			return user:get_week_login_days()
		end
		return user:get_login_days()
	end,
	[CONST.TASK_COND.BUILD_LV] = function(user, cond)
		local build = BUILD_MGR.get_build_by_bid(user:get_user_id(), cond.bid)
		return build and build:get_level() or 0
	end,
	[CONST.TASK_COND.HERO_CNT] = function(user)
		local cnt = 0
		for _ in pairs(HERO_MGR.get_hero_tbl_by_user_id(user:get_user_id())) do
			cnt = cnt + 1
		end
		return cnt
	end,
	[CONST.TASK_COND.OWN_ITEM] = function(user, cond)
		return ITEM_MGR.get_item_count(user:get_user_id(), cond.item_id)
	end,
	[CONST.TASK_COND.POWER] = function(user)
		return user:get_power()
	end,
}

local function load_doc(user_id)
	return ORM.load(MONGO_SLAVE.COL.USER_TASK, user_id, ORM.CLS_USER_TASK_DOC)
end

local function cond_of(task_id)
	local conf = DATA_COMMON.get_task_conf(task_id)
	return conf and conf.Cond or EMPTY_TABLE
end

local function task_pto(task)
	return {
		taskId = task._task_id,
		progress = task._progress,
		state = task._state,
		taskType = DATA_COMMON.get_task_type(task._task_id),
	}
end

local function sync_task(user, task)
	local fd = user:get_fd()
	if not fd then
		return
	end
	for_caller.s2c_sync_task(fd, {taskInfo = task_pto(task)})
end

local function set_progress(user, task, value)
	if task._state == CONST.TASK_STATE.GOT then
		return
	end
	local conf = DATA_COMMON.get_task_conf(task._task_id)
	if not conf then
		return
	end
	local state = CONST.TASK_STATE.DOING
	if value >= conf.Target then
		state = CONST.TASK_STATE.CAN_GET
	end
	if task._progress == value and task._state == state then
		return
	end
	task._progress = value
	task._state = state
	sync_task(user, task)
end

local function get_value(user, task)
	local cond = cond_of(task._task_id)
	local get = COND_GET[cond.type]
	if not get then
		return
	end
	return get(user, cond, DATA_COMMON.get_task_type(task._task_id))
end

local function accept(user, doc, task_id)
	doc._tasks[task_id] = {
		_task_id = task_id,
		_progress = 0,
		_state = CONST.TASK_STATE.DOING,
	}
	local task = doc._tasks[task_id]
	set_progress(user, task, get_value(user, task) or 0)
	return task
end

local function accept_all(user, doc, conf_tbl)
	for task_id in pairs(conf_tbl) do
		accept(user, doc, task_id)
	end
end

local function ensure_period(user, doc)
	local now = TIME.os_bj_sec()
	local last = doc._reset_time
	if last == 0 or TIME.get_rela_week_no(last) ~= TIME.get_rela_week_no(now) then
		accept_all(user, doc, DATA_COMMON.get_week_task_tbl())
	end
	if last == 0 or TIME.get_rela_day_no(last) ~= TIME.get_rela_day_no(now) then
		accept_all(user, doc, DATA_COMMON.get_daily_task_tbl())
		doc._reset_time = now
	end
	if doc._main_id == 0 then
		doc._main_id = DATA_COMMON.get_main_task_head() or 0
	end
	if doc._main_id ~= 0 and not doc._tasks[doc._main_id] and DATA_COMMON.get_task_conf(doc._main_id) then
		accept(user, doc, doc._main_id)
	end
end

local function prepare(user_id)
	local user = USER_MGR.try_init_user(user_id)
	local doc = load_doc(user_id)
	ensure_period(user, doc)
	return user, doc
end

-- 状态类条件重新 get 一次。match 为空时全部
local function refresh_get(user_id, match)
	local user, doc = prepare(user_id)
	for _, task in pairs(doc._tasks) do
		local cond = cond_of(task._task_id)
		if COND_GET[cond.type] and (not match or match(cond)) then
			set_progress(user, task, get_value(user, task))
		end
	end
	return doc
end

local function add_count(user_id, kind, delta)
	local user, doc = prepare(user_id)
	for _, task in pairs(doc._tasks) do
		if cond_of(task._task_id).type == kind then
			set_progress(user, task, task._progress + delta)
		end
	end
end

function on_user_login(user_id)
	refresh_get(user_id)
end

function on_user_logout(user_id)
	if ORM.get(MONGO_SLAVE.COL.USER_TASK, user_id) then
		ORM.unbind(MONGO_SLAVE.COL.USER_TASK, user_id)
	end
end

function on_new_day(user_id)
	refresh_get(user_id, function(cond)
		return cond.type == CONST.TASK_COND.LOGIN
	end)
end

function on_lottery(user_id, cnt)
	add_count(user_id, CONST.TASK_COND.LOTTERY, cnt)
end

function on_head_icon(user_id, cnt)
	add_count(user_id, CONST.TASK_COND.HEAD_ICON, cnt)
end

function on_march(user_id, cnt)
	add_count(user_id, CONST.TASK_COND.MARCH, cnt)
end

function on_hero_add(user_id)
	refresh_get(user_id, function(cond)
		return cond.type == CONST.TASK_COND.HERO_CNT or cond.type == CONST.TASK_COND.POWER
	end)
end

function on_build_level(user_id, bid)
	refresh_get(user_id, function(cond)
		return cond.type == CONST.TASK_COND.BUILD_LV and cond.bid == bid
	end)
end

function on_item_change(user_id, item_id)
	refresh_get(user_id, function(cond)
		return cond.type == CONST.TASK_COND.OWN_ITEM and cond.item_id == item_id
	end)
end

local function on_req_task_list(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local _, doc = prepare(user:get_user_id())
	local want = packet.taskType or 0
	local task_list = {}
	for _, task in pairs(doc._tasks) do
		if want == 0 or want == DATA_COMMON.get_task_type(task._task_id) then
			task_list[#task_list + 1] = task_pto(task)
		end
	end
	for_caller.s2c_req_task_list(fd, {taskList = task_list})
end

local function on_get_task_reward(fd, packet)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local task_id = packet.taskId
	local conf = DATA_COMMON.get_task_conf(task_id)
	if not conf then
		return
	end
	local user_id = user:get_user_id()
	local _, doc = prepare(user_id)
	local task = doc._tasks[task_id]
	if not task or task._state ~= CONST.TASK_STATE.CAN_GET then
		return
	end
	task._state = CONST.TASK_STATE.GOT
	sync_task(user, task)
	if DATA_COMMON.get_task_type(task_id) == CONST.TASK_TYPE.MAIN and conf.NextId and DATA_COMMON.get_task_conf(conf.NextId) then
		doc._tasks[task_id] = nil
		doc._main_id = conf.NextId
		accept(user, doc, conf.NextId)
	end
	REWARD_MGR.reward_user_and_show(user_id, conf.Reward or EMPTY_TABLE, {CONST.FLOW_REASON.TASK, task_id})
	for_caller.s2c_get_task_reward(fd, {taskId = task_id})
end

function __init__()
	for_maker.c2s_req_task_list = on_req_task_list
	for_maker.c2s_get_task_reward = on_get_task_reward
	EVENT.listen(CONST.EVENT.ON_USER_LOGIN)
	EVENT.listen(CONST.EVENT.ON_USER_LOGOUT)
	EVENT.listen(CONST.EVENT.ON_NEW_DAY)
	EVENT.listen(CONST.EVENT.ON_LOTTERY)
	EVENT.listen(CONST.EVENT.ON_HEAD_ICON)
	EVENT.listen(CONST.EVENT.ON_MARCH)
	EVENT.listen(CONST.EVENT.ON_HERO_ADD)
	EVENT.listen(CONST.EVENT.ON_BUILD_LEVEL)
	EVENT.listen(CONST.EVENT.ON_ITEM_CHANGE)
end
