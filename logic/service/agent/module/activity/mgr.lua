local skynet = require "skynet"

local function call_rank(cmd, ...)
	local addr = skynet.localname(".activity")
	if not addr then
		return
	end
	return skynet.call(addr, "lua", cmd, ...)
end

local function user_level(user)
	local lv = user:get_level()
	if lv < 1 then
		lv = 1
	end
	return lv
end

local function level_ok(user, conf)
	local need = 1
	if conf.OpenCond and conf.OpenCond.level then
		need = conf.OpenCond.level
	end
	return user_level(user) >= need
end

-- weekday：1 是周一。返回 open, ended, start, endt
local function time_window(conf, now, open_time)
	local time_conf = conf.Time or {}
	local kind = time_conf.type
	if kind == nil or kind == CONST.ACTIVITY_TIME.ALWAYS then
		return true, false, 0, 0
	end
	if kind == CONST.ACTIVITY_TIME.OPEN_DAY then
		local open_idx = TIME.get_rela_day_no(now) - TIME.get_rela_day_no(open_time) + 1
		local start_day = time_conf.open_day or 1
		local duration = time_conf.duration or 0
		local start_time = TIME.day_begin(open_time) + (start_day - 1) * CONST.ONE_DAY_SEC
		local end_time = start_time + duration * CONST.ONE_DAY_SEC
		local open = open_idx >= start_day and open_idx < start_day + duration
		return open, open_idx >= start_day + duration, start_time, end_time
	end
	if kind == CONST.ACTIVITY_TIME.WEEKDAY then
		local begin = TIME.day_begin(now)
		local weekday = time_conf.weekday or 1
		local delta = (TIME.get_weekday(now) - weekday) % 7
		local start_time = begin - delta * CONST.ONE_DAY_SEC
		local end_time = start_time + (time_conf.duration or 1) * CONST.ONE_DAY_SEC
		return now >= start_time and now < end_time, false, start_time, end_time
	end
	if kind == CONST.ACTIVITY_TIME.DAILY then
		local start_time = TIME.day_begin(now)
		return true, false, start_time, start_time + CONST.ONE_DAY_SEC
	end
	return false, false, 0, 0
end

local function state_of(user, conf, now, open_time)
	local open, ended, start_time, end_time = time_window(conf, now, open_time)
	if not level_ok(user, conf) then
		return CONST.ACTIVITY_STATE.CLOSED, start_time, end_time
	end
	if open then
		return CONST.ACTIVITY_STATE.OPEN, start_time, end_time
	end
	if ended then
		return CONST.ACTIVITY_STATE.END, start_time, end_time
	end
	return CONST.ACTIVITY_STATE.CLOSED, start_time, end_time
end

local function is_open(user, conf)
	local state = state_of(user, conf, TIME.os_bj_sec(), GAME.get_open_time())
	return state == CONST.ACTIVITY_STATE.OPEN
end

function on_calc_item_reward(user_id, ctx)
	local user = USER_MGR.try_init_user(user_id)
	for _, conf in pairs(DATA_COMMON.get_all_activity()) do
		if conf.Type == CONST.ACTIVITY_TYPE.RES_RATE and is_open(user, conf) and conf.Params then
			local ids = conf.Params.item_ids
			if ids and conf.Params.rate and conf.Params.rate > ctx.rate then
				for _, id in ipairs(ids) do
					if id == ctx.item_id then
						ctx.rate = conf.Params.rate
						break
					end
				end
			end
		end
	end
end

function on_calc_lottery_cost(user_id, ctx)
	local user = USER_MGR.try_init_user(user_id)
	for _, conf in pairs(DATA_COMMON.get_all_activity()) do
		if conf.Type == CONST.ACTIVITY_TYPE.LOTTERY and is_open(user, conf) and conf.Params then
			if conf.Params.lottery_id == ctx.lottery_id and conf.Params.cost_rate and conf.Params.cost_rate < ctx.rate then
				ctx.rate = conf.Params.cost_rate
			end
		end
	end
end

local function report_score(user_id)
	local user = USER_MGR.try_init_user(user_id)
	local name, head_icon = user:get_name(), user:get_head_icon()
	call_rank("set_score", DATA_COMMON.RANK_TYPE.POWER, user_id, user:get_power(), name, head_icon)
	call_rank("set_score", DATA_COMMON.RANK_TYPE.CITY_LEVEL, user_id, user:get_city_level(), name, head_icon)
end

local function rank_item_pto(item)
	return {rank = item.rank, uid = item.uid, name = item.name, headIcon = item.head_icon, score = item.score}
end

local function on_req_rank_list(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id or not DATA_COMMON.get_rank_type_conf(packet.rankType) then
		return
	end
	local start = math.max(1, packet.start)
	local count = packet.count
	if count == 0 or count > CONST.RANK_PAGE_MAX then
		count = CONST.RANK_PAGE_DEFAULT
	end
	local ret = call_rank("get_rank_list", packet.rankType, start, count, user_id)
	if not ret then
		return
	end
	local list = {}
	for _, item in ipairs(ret.list) do
		list[#list + 1] = rank_item_pto(item)
	end
	for_caller.s2c_req_rank_list(fd, {
		rankType = packet.rankType,
		rankList = list,
		selfRank = rank_item_pto(ret.self),
	})
end

function on_user_login(user_id)
	report_score(user_id)
end

function on_hero_add(user_id)
	report_score(user_id)
end

function on_head_icon(user_id)
	report_score(user_id)
end

function on_hero_level(user_id)
	report_score(user_id)
end

function on_build_level(user_id, bid)
	if bid == CONST.BUILD_TYPE.MAIN_HALL then
		report_score(user_id)
	end
end

local function on_req_activity_list(fd)
	local user = USER_MGR.get_user_by_fd(fd)
	if not user then
		return
	end
	local now = TIME.os_bj_sec()
	local open_time = GAME.get_open_time()
	local activity_list = {}
	for _, conf in pairs(DATA_COMMON.get_all_activity()) do
		local state, start_time, end_time = state_of(user, conf, now, open_time)
		activity_list[#activity_list + 1] = {
			activityId = conf.Id,
			state = state,
			startTime = start_time,
			endTime = end_time,
		}
	end
	for_caller.s2c_req_activity_list(fd, {activityList = activity_list})
end

function __init__()
	for_maker.c2s_req_activity_list = on_req_activity_list
	for_maker.c2s_req_rank_list = on_req_rank_list
	EVENT.listen(CONST.EVENT.ON_USER_LOGIN)
	EVENT.listen(CONST.EVENT.ON_HERO_ADD)
	EVENT.listen(CONST.EVENT.ON_BUILD_LEVEL)
	EVENT.listen(CONST.EVENT.ON_HEAD_ICON)
	EVENT.listen(CONST.EVENT.ON_HERO_LEVEL)
	EVENT.listen(CONST.EVENT.ON_CALC_ITEM_REWARD)
	EVENT.listen(CONST.EVENT.ON_CALC_LOTTERY_COST)
end
