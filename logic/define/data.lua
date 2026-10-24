local sharedata = require "skynet.sharedata"

local DATA_HERO = sharedata.query("Hero")
local DATA_HERO_LV = sharedata.query("HeroLv")
local DATA_REPORT = sharedata.query("ReportInfo")
local DATA_SERVER_GROUP = sharedata.query("ServerGroup")
local DATA_GLOBAL = sharedata.query("Global")
local DATA_BUILD_DETAIL = sharedata.query("BuildingDetail")
local DATA_BUILD_LEVEL = sharedata.query("BuildingLv")
local DATA_BUILD_CONF = sharedata.query("innerCity")
local DATA_HEAD_ICON = sharedata.query("HeadIcon")
local DATA_LOTTERY = sharedata.query("Lottery")
local DATA_ITEM = sharedata.query("Item")
local DATA_SYSTEM_OPEN = sharedata.query("SystemOpen")
local DATA_MAIN_TASK = sharedata.query("MainTask")
local DATA_DAILY_TASK = sharedata.query("DailyTask")
local DATA_WEEK_TASK = sharedata.query("WeekTask")
local DATA_ACTIVITY = sharedata.query("Activity")
local DATA_MONSTER_GROUP = sharedata.query("MonsterGroup")
local DATA_MONSTER = sharedata.query("Monster")
local DATA_SKILL = sharedata.query("Skill")
local DATA_RANK_TYPE = sharedata.query("RankType")
local DATA_CHAT_CHANNEL = sharedata.query("ChatChannel")
local DATA_ALLIANCE_LV = sharedata.query("AllianceLv")
local DATA_ALLIANCE_POS = sharedata.query("AlliancePos")
local DATA_ALLIANCE_JOIN_TYPE = sharedata.query("AllianceJoinType")
local DATA_ENTITY_TYPE = sharedata.query("EntityType")
local DATA_TARGET_TYPE = sharedata.query("TargetType")
local DATA_REPORT_TYPE = sharedata.query("ReportType")
local DATA_MAIL = sharedata.query("Mail")
local DATA_MAIL_KIND = sharedata.query("MailKind")
local DATA_RES_LAND = sharedata.query("ResLand")
local DATA_RES_LAND_TYPE = sharedata.query("ResLandType")
-- local DATA_NAME_CN = sharedata.query("NameCn")

-- local conf = {
-- 	[CONST.LANGUAGE.CHINESE] = function()
-- 		return DATA_NAME_CN
-- 	end,
-- }

-- 带 Enum 列的表转成 {[Enum] = Id}
local function build_enum(data)
	local ret = {}
	for id, conf in pairs(data) do
		ret[conf.Enum] = id
	end
	return ret
end

-- 枚举直接取配置表，用 DATA_COMMON.XXX.ENUM，不要在加载时缓存成 local（重载配置会换新表）
local function init_enum()
	ENTITY_TYPE = build_enum(DATA_ENTITY_TYPE)
	TARGET_TYPE = build_enum(DATA_TARGET_TYPE)
	REPORT_TYPE = build_enum(DATA_REPORT_TYPE)
	RANK_TYPE = build_enum(DATA_RANK_TYPE)
	CHAT_CHANNEL = build_enum(DATA_CHAT_CHANNEL)
	ALLIANCE_POS = build_enum(DATA_ALLIANCE_POS)
	ALLIANCE_JOIN_TYPE = build_enum(DATA_ALLIANCE_JOIN_TYPE)
	MAIL_KIND = build_enum(DATA_MAIL_KIND)
	RES_LAND_TYPE = build_enum(DATA_RES_LAND_TYPE)
end

-- 二次处理配置表的内容。放在 __init__ 里：热更 / 重载配置时会先恢复旧模块变量再调 __init__，这里才能重算
local function init_config_data()
	init_build_list = {}
	for bid, conf in pairs(DATA_BUILD_DETAIL) do
		if conf.InitLev and conf.InitLev > 0 then
			init_build_list[#init_build_list + 1] = {bid = bid, level = conf.InitLev}
		end
	end
	-- 配置加载后按 Id 索引，没有"第一行"了，主线起点取 Order 最小的
	main_task_head = nil
	for task_id, conf in pairs(DATA_MAIN_TASK) do
		if not main_task_head or conf.Order < DATA_MAIN_TASK[main_task_head].Order then
			main_task_head = task_id
		end
	end
	hero_max_level = 0
	for _, conf in pairs(DATA_HERO_LV) do
		hero_max_level = math.max(hero_max_level, conf.Lv)
	end
	-- [build_type] = { [lv] = conf }，build_max_level_tbl[build_type] = 配置里的最高等级
	build_lv_tbl = {}
	build_max_level_tbl = {}
	for _, conf in pairs(DATA_BUILD_LEVEL) do
		local b_type = conf.BuildingType
		build_lv_tbl[b_type] = build_lv_tbl[b_type] or {}
		build_lv_tbl[b_type][conf.Lv] = conf
		build_max_level_tbl[b_type] = math.max(build_max_level_tbl[b_type] or 0, conf.Lv)
	end
end

local function init_system_open_enum()
	for system_id, conf in pairs(DATA_SYSTEM_OPEN) do
		local enum_name = conf.Enum
		local value = conf.Id or system_id
		assert(_G[enum_name] == nil or _G[enum_name] == value, enum_name)
		_G[enum_name] = value
	end
end

function __init__()
	init_config_data()
	init_enum()
	init_system_open_enum()
end

function get_value_by_key(key)
	return DATA_GLOBAL[key].value1 or DATA_GLOBAL[key].value2 or DATA_GLOBAL[key].value3
end

function get_user_level_up_exp()
	return get_value_by_key(5)
end

function get_troop_max_cnt()
	return get_value_by_key(6)
end

function get_troop_pos_cnt()
	return get_value_by_key(7)
end

local function get_report_info(report_id)
	return DATA_REPORT[report_id]
end

local function get_report_info_by_srv_group(group_id)
	local report_id = DATA_SERVER_GROUP[group_id].reportId
	return get_report_info(report_id)
end

function get_login_address_by_srv_group(group_id)
	local info = get_report_info_by_srv_group(group_id)
	return info.LoginDomain, info.HttpPort, info.HttpsPort
end

function get_first_name_list(language)
	local name_tbl = conf[language]()
	return name_tbl[1]
end

function get_hero_info_by_type(hero_type)
	return DATA_HERO[hero_type]
end

function get_head_icon_info(head_icon)
	return DATA_HEAD_ICON[head_icon]
end

function get_all_hero_types()
	local list = {}
	for hero_type in pairs(DATA_HERO) do
		table.insert(list, hero_type)
	end
	return list
end

function get_item_kind(item_id)
	local item_kind = DATA_ITEM[item_id].item_kind
	return item_kind
end

function get_initial_build_list()
	return init_build_list
end

function get_build_detail(bid)
	return DATA_BUILD_DETAIL[bid]
end

-- BuildingLv.BuildingType 指向 BuildingDetail.Id，协议里的 bid 也是这个 Id
function get_build_type_by_id(bid)
	local conf = DATA_BUILD_DETAIL[bid]
	if not conf then
		return
	end
	return conf.Id
end

-- Lottery 表的 Id 就是一次抽几发；没配的抽数不允许
-- 奖池每项 {reward_type, item_id, item_count, weight}
function get_lottery_conf(use_lottery_times)
	return DATA_LOTTERY[use_lottery_times]
end

function can_overlap(item_id)
	return (DATA_ITEM[item_id].Overlap or 1) > 1
end

function get_item_overlap(item_id)
	return DATA_ITEM[item_id].Overlap
end

function get_item_kind(item_id)
	return DATA_ITEM[item_id].Kind
end

function get_build_max_level(b_type)
	return build_max_level_tbl[b_type] or 0
end

function get_build_level_conf(b_type, lv)
	return build_lv_tbl[b_type] and build_lv_tbl[b_type][lv]
end

function get_system_open_tbl()
	return DATA_SYSTEM_OPEN
end

function get_soldier_max()
	return get_value_by_key(8)
end

-- 每秒走的格子数，可以是小数。Global Id=17 的 value1 是整数，装不下 0.5
function get_march_speed()
	return 0.5
end

function get_main_task_head()
	return main_task_head
end

function get_daily_task_tbl()
	return DATA_DAILY_TASK
end

function get_week_task_tbl()
	return DATA_WEEK_TASK
end

function get_task_conf(task_id)
	return DATA_MAIN_TASK[task_id] or DATA_DAILY_TASK[task_id] or DATA_WEEK_TASK[task_id]
end

function get_task_type(task_id)
	if DATA_MAIN_TASK[task_id] then
		return CONST.TASK_TYPE.MAIN
	end
	if DATA_DAILY_TASK[task_id] then
		return CONST.TASK_TYPE.DAILY
	end
	if DATA_WEEK_TASK[task_id] then
		return CONST.TASK_TYPE.WEEK
	end
end

function get_activity_conf(activity_id)
	return DATA_ACTIVITY[activity_id]
end

function get_all_activity()
	return DATA_ACTIVITY
end

function get_monster_group(group_id)
	return DATA_MONSTER_GROUP[group_id]
end

function get_monster_group_tbl()
	return DATA_MONSTER_GROUP
end

function get_monster_conf(monster_id)
	return DATA_MONSTER[monster_id]
end

function get_skill_conf(skill_id)
	return DATA_SKILL[skill_id]
end

function get_hero_max_level()
	return hero_max_level
end

function get_skill_max_level(skill_id)
	local conf = DATA_SKILL[skill_id]
	return conf and #conf.Levels or 0
end

function get_all_item_ids()
	local list = {}
	for item_id in pairs(DATA_ITEM) do
		list[#list + 1] = item_id
	end
	table.sort(list)
	return list
end

function get_rank_type_conf(rank_type)
	return DATA_RANK_TYPE[rank_type]
end

function get_chat_channel_conf(channel)
	return DATA_CHAT_CHANNEL[channel]
end

-- 单频道（私聊按会话）保留的历史条数
function get_chat_history_max()
	return get_value_by_key(9)
end

function get_alliance_lv_conf(lv)
	return DATA_ALLIANCE_LV[lv]
end

function get_alliance_pos_conf(pos)
	return DATA_ALLIANCE_POS[pos]
end

function get_alliance_join_type_conf(join_type)
	return DATA_ALLIANCE_JOIN_TYPE[join_type]
end

-- 创建联盟消耗的令牌数
function get_alliance_create_cost()
	return get_value_by_key(10)
end

function get_alliance_name_max_len()
	return get_value_by_key(11)
end

function get_alliance_notice_max_len()
	return get_value_by_key(12)
end

function get_alliance_manifesto_max_len()
	return get_value_by_key(13)
end

function get_alliance_apply_max()
	return get_value_by_key(14)
end

function get_mail_conf(mail_id)
	return DATA_MAIL[mail_id]
end

function get_mail_kind_conf(mail_kind)
	return DATA_MAIL_KIND[mail_kind]
end

-- 单个邮件类型最多保留的条数
function get_mail_kind_max()
	return get_value_by_key(15)
end

-- 模板 ExpireDay 为 0 时用的保留天数
function get_mail_default_expire_day()
	return get_value_by_key(16)
end

function get_res_land_conf(land_id)
	return DATA_RES_LAND[land_id]
end

function get_res_land_tbl()
	return DATA_RES_LAND
end