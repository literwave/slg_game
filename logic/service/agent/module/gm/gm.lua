local skynet = require "skynet"

local CMD = {}

local CMD_DESC = {
	{ "help", "查看指令 [help] 或 [help 指令名]" },
	{ "code", "执行服务端代码 [code codeString]" },
	{ "update", "重新加载 lua 文件 [update file]" },
	{ "full_build", "所有建筑升至满级 [full_build]" },
	{ "add_time", "增加时间 [add_time hour,min,sec]" },
	{ "reset_time", "重置时间 [reset_time]" },
	{ "show_time", "显示时间 [show_time]" },
	{ "set_open_time", "设置开服时间 [set_open_time 年,月,日] 或 [set_open_time 年,月,日,时,分,秒]，[set_open_time 0] 恢复配置，重启后失效" },
	{ "add_item", "增加道具 [add_item itemId,cnt]" },
	{ "add_soldier", "增加预备兵力 [add_soldier cnt]，不填数量则加到上限，不计入编队" },
	{ "del_item", "删除道具 [del_item itemId,cnt]" },
	{ "mail", "给自己发模板邮件 [mail mailId] 或 [mail mailId,itemId,cnt]" },
	{ "srv_mail", "发全服模板邮件 [srv_mail mailId] 或 [srv_mail mailId,itemId,cnt]" },
	{ "notice", "发全服公告邮件 [notice 标题,内容]" },
	{ "add_hero", "添加武将 [add_hero heroType]" },
	{ "full_hero", "获得全部武将 [full_hero]" },
	{ "add_exp", "增加主角经验 [add_exp exp]" },
	{ "open_system", "解锁系统 [open_system systemId]，0为全部" },
	{ "add_heart", "加减心跳时间 [add_heart sec]，负数为减，之后拦截客户端心跳" },
	{ "super", "超级号：主角升级、开全部系统、全部武将满级满技能、建筑满级、资源兵力道具加满 [super] 或 [super 主角等级]" },
	{ "move_city", "迁主城，不消耗迁城令 [move_city x,y]" },
}

local function tell(vfd, msg)
	local user_id = USER_MGR.get_user_id_by_vfd(vfd)
	if user_id then
		USER_MGR.tell_me(user_id, msg)
	end
end

function CMD.help(vfd, cmd)
	if cmd then
		local desc = "没有这个指令"
		for _, item in ipairs(CMD_DESC) do
			if item[1] == cmd then
				desc = item[2]
				break
			end
		end
		tell(vfd, desc)
	else
		for _, item in ipairs(CMD_DESC) do
			tell(vfd, item[2])
		end
	end
	for_caller.s2c_gm_command_help(vfd, { ret = {} })
end

CMD.h = CMD.help

function CMD.code(vfd, code_string)
	assert(type(code_string) == "string" and code_string ~= "", "empty code")
	local fn, err = load(code_string, "gmcode")
	assert(fn, err)
	fn()
end

-- 只更当前 agent；全服热更用 shell/hot_update.sh
function CMD.update(vfd, file)
	assert(type(file) == "string" and file ~= "", "empty file")
	skynet.cache.clear()
	local ret = hot_update({file})
	assert(ret.ok, ret.err)
	assert(ret.updated[1], "file not imported in this agent")
end

function CMD.full_build(vfd)
	local user_id = USER_MGR.get_user_id_by_vfd(vfd)
	local build_tbl = BUILD_MGR.get_user_build_tbl(user_id)
	for _, build in pairs(build_tbl) do
		local level = DATA_COMMON.get_build_max_level(build:get_build_type())
		build:set_level(level)
		build:sync_to_client()
		EVENT.dispatch(CONST.EVENT.ON_BUILD_LEVEL, user_id, build:get_bid(), level)
	end
end

function CMD.add_time(vfd, hour, min, sec)
	hour = hour or 0
	min = min or 0
	sec = sec or 0
	TIME.add_offset(hour * CONST.ONE_HOUR_SEC + min * 60 + sec)
	tell(vfd, TIME.format(TIME.os_bj_sec()))
end

function CMD.reset_time(vfd)
	TIME.reset_offset()
	tell(vfd, TIME.format(TIME.os_bj_sec()))
end

local function tell_open_time(vfd)
	local open_time = GAME.get_open_time()
	local open_day = TIME.get_rela_day_no(TIME.os_bj_sec()) - TIME.get_rela_day_no(open_time) + 1
	tell(vfd, string.format("开服时间 %s，今天是开服第 %d 天", TIME.format(open_time), open_day))
end

function CMD.show_time(vfd)
	tell(vfd, TIME.format(TIME.os_bj_sec()))
	tell_open_time(vfd)
end

-- 每个 agent 各存一份，要广播到所有 agent
function CMD.set_open_time(vfd, year, month, day, hour, min, sec)
	assert(year, "need year,month,day or 0")
	local t
	if year ~= 0 then
		assert(month and day, "need year,month,day")
		t = TIME.os_bj_sec_by_tbl({year = year, month = month, day = day, hour = hour or 0, min = min or 0, sec = sec or 0})
	end
	local self = skynet.self()
	for _, agent in ipairs(skynet.call(".gated", "lua", "get_agent_list")) do
		if agent ~= self then
			skynet.send(agent, "lua", "set_open_time", t)
		end
	end
	GAME.set_open_time(t)
	tell_open_time(vfd)
end

function CMD.add_item(vfd, item_id, cnt)
	assert(item_id and cnt and cnt > 0)
	local user_id = USER_MGR.get_user_id_by_vfd(vfd)
	REWARD_MGR.reward_user_and_show(user_id, {
		GLOBAL_FUNC.gen_reward_info(CONST.REWARD_TYPE_ITEM, item_id, cnt),
	}, {CONST.FLOW_REASON.GM})
end

function CMD.del_item(vfd, item_id, cnt)
	assert(item_id and cnt and cnt > 0)
	local user_id = USER_MGR.get_user_id_by_vfd(vfd)
	assert(ITEM_MGR.del_cost_list(user_id, {
		{
			cost_type = CONST.COST_TYPE.ITEM,
			itemId = item_id,
			count = cnt,
		},
	}, {CONST.FLOW_REASON.GM}))
end

local function gm_mail_rewards(item_id, cnt)
	if item_id and cnt and cnt > 0 then
		return {GLOBAL_FUNC.gen_reward_info(CONST.REWARD_TYPE_ITEM, item_id, cnt)}
	end
end

function CMD.mail(vfd, mail_id, item_id, cnt)
	assert(DATA_COMMON.get_mail_conf(mail_id))
	MAIL.send_user_mail(USER_MGR.get_user_id_by_vfd(vfd), mail_id, nil, gm_mail_rewards(item_id, cnt))
end

function CMD.srv_mail(vfd, mail_id, item_id, cnt)
	assert(DATA_COMMON.get_mail_conf(mail_id))
	MAIL.send_srv_mail(mail_id, nil, gm_mail_rewards(item_id, cnt))
end

function CMD.notice(vfd, title, content)
	assert(title and content)
	MAIL.send_srv_mail(CONST.MAIL_ID.NOTICE, {tostring(title), tostring(content)})
end

function CMD.add_hero(vfd, hero_type)
	assert(hero_type)
	local user_id = USER_MGR.get_user_id_by_vfd(vfd)
	HERO_MGR.add_hero(user_id, hero_type, {CONST.FLOW_REASON.GM})
end

function CMD.full_hero(vfd)
	local user_id = USER_MGR.get_user_id_by_vfd(vfd)
	for _, hero_type in ipairs(DATA_COMMON.get_all_hero_types()) do
		HERO_MGR.add_hero(user_id, hero_type, {CONST.FLOW_REASON.GM})
	end
end

function CMD.add_soldier(vfd, cnt)
	local user = USER_MGR.get_user_by_fd(vfd)
	assert(user)
	if not cnt then
		cnt = DATA_COMMON.get_soldier_max()
	end
	assert(cnt > 0)
	local added = user:add_soldier(cnt)
	user:sync_soldier()
	tell(vfd, string.format("兵力 +%d，当前 %d", added, user:get_soldier_cnt()))
end

function CMD.add_exp(vfd, exp)
	assert(exp and exp > 0)
	local user = USER_MGR.get_user_by_fd(vfd)
	assert(user)
	user:add_exp(exp)
end

function CMD.add_heart(vfd, sec)
	assert(sec)
	local user = USER_MGR.get_user_by_fd(vfd)
	assert(user)
	local last_time = user:get_heart_beat_time() or TIME.os_bj_sec()
	user:set_heart_beat_time(last_time + sec)
	USER_MGR.hold_heart_beat(user:get_user_id())
	tell(vfd, TIME.format(user:get_heart_beat_time()))
end

function CMD.open_system(vfd, system_id)
	assert(system_id)
	local user = USER_MGR.get_user_by_fd(vfd)
	assert(user)
	if system_id == 0 then
		tell(vfd, string.format("新开启 %d 个系统", SYSTEM_OPEN.open_all(user)))
		SYSTEM_OPEN.sync_all(user)
		return
	end
	assert(DATA_COMMON.get_system_open_tbl()[system_id], "没有这个系统 " .. tostring(system_id))
	if SYSTEM_OPEN.open_system(user, system_id) then
		tell(vfd, "系统已开启 " .. system_id)
	else
		tell(vfd, "系统之前已开启 " .. system_id)
		SYSTEM_OPEN.sync_all(user)
	end
end

-- 一键拉满：主角等级、全部系统、全部武将满级满技能、建筑满级、资源、兵、道具。可重复执行
function CMD.super(vfd, level)
	level = level or CONST.GM_SUPER_LEVEL
	local user = USER_MGR.get_user_by_fd(vfd)
	assert(user)
	local user_id = user:get_user_id()
	if user:get_level() < level then
		user:add_exp((level - user:get_level()) * DATA_COMMON.get_user_level_up_exp() - user:get_exp())
	end
	SYSTEM_OPEN.open_all(user)
	SYSTEM_OPEN.sync_all(user)

	CMD.full_hero(vfd)
	local hero_max = DATA_COMMON.get_hero_max_level()
	for _, hero in pairs(HERO_MGR.get_hero_tbl_by_user_id(user_id)) do
		hero:set_level(hero_max)
		local skill_ids = {}
		for skill_id in pairs(hero:get_skill_tbl()) do
			skill_ids[#skill_ids + 1] = skill_id
		end
		for _, skill_id in ipairs(skill_ids) do
			hero:set_skill_lv(skill_id, DATA_COMMON.get_skill_max_level(skill_id))
		end
		hero:sync_to_client()
	end

	CMD.full_build(vfd)

	local res_list = {}
	for _, res_type in ipairs(CONST.RES_BAR_LIST) do
		user:add_res(res_type, CONST.GM_SUPER_RES, {CONST.FLOW_REASON.GM})
		res_list[#res_list + 1] = res_type
	end
	user:sync_res(res_list)
	user:add_soldier(DATA_COMMON.get_soldier_max())
	user:sync_soldier()

	local reward_list = {}
	for _, item_id in ipairs(DATA_COMMON.get_all_item_ids()) do
		local overlap = DATA_COMMON.get_item_overlap(item_id) or 1
		reward_list[#reward_list + 1] = GLOBAL_FUNC.gen_reward_info(CONST.REWARD_TYPE_ITEM, item_id, math.max(1, overlap))
	end
	REWARD_MGR.reward_user(user_id, reward_list, {CONST.FLOW_REASON.GM})

	tell(vfd, string.format("超级号完成：主角 %d 级，武将 %d 级", user:get_level(), hero_max))
end

function CMD.move_city(vfd, x, y)
	assert(x and y)
	local user = USER_MGR.get_user_by_fd(vfd)
	assert(user)
	local ok, msg = USER_MGR.try_move_city(user, x, y, false)
	if not ok then
		tell(vfd, msg)
		error(msg)
	end
	for_caller.s2c_move_city(vfd, {cityPos = user:get_city_pos_pto()})
	user:sync_city_pos()
	tell(vfd, string.format("主城已迁到 %d,%d", user:get_birth_x(), user:get_birth_y()))
end

local function on_gm_command(fd, packet)
	local cmd = packet and packet.cmd
	if type(cmd) ~= "string" or cmd == "" then
		return
	end
	local user_id = USER_MGR.get_user_id_by_vfd(fd)
	if not user_id then
		return
	end
	local cmd_tbl = string.split(cmd, " ")
	local func_name = cmd_tbl[1]
	local func = CMD[func_name]
	if not func then
		USER_MGR.tell_me(user_id, "没有这个指令")
		return
	end
	skynet.error(string.format("gmcmd:%s %s", user_id, cmd))
	local args = {}
	if func_name == "code" then
		table.insert(args, string.match(cmd, "^%S+%s+(.*)$"))
	elseif cmd_tbl[2] then
		for _, v in ipairs(string.split(cmd_tbl[2], ",")) do
			table.insert(args, tonumber(v) or v)
		end
	end
	local ok = xpcall(function()
		func(fd, table.unpack(args))
	end, __G__TRACKBACK__)
	if ok then
		USER_MGR.tell_me(user_id, "指令使用成功")
	else
		USER_MGR.tell_me(user_id, "指令使用失败报错")
	end
end

function __init__()
	for_maker.c2s_gm_command = on_gm_command
end
