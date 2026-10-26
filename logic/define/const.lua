-- 全局变量文件

RES_TYPE_MONEY = 1
USER_HEART_BEAT_INTERVAL = 5
USER_HEART_BEAT_TIMEOUT = 15
USER_HEART_BEAT_CHECK_INTERVAL = 5

TEST_SERVER_GROUP_TBL = {
	[99] = true,
}

REWARD_TYPE_ITEM = 1
REWARD_TYPE_RES = 2
REWARD_TYPE_HERO = 3
REWARD_TYPE_SOLDIER = 4

-- s2c_show_reward.showTypeList。0 不展示，1 普通弹窗；大于 1 留给专用来源
REWARD_SHOW_TYPE = {
	NONE = 0,
	WINDOW = 1,
}

LOCK_TIME = 1000

BUILD_TYPE = {
	MAIN_HALL = 1,
}

SEX_NONE = 0
SEX_MAN = 1
SEX_WOMAN = 2

RES_TYPE_FOOD = 1
RES_TYPE_WARER = 2
RES_TYPE_WOOD = 3
-- 资源栏石料。key 是 5，和道具 Id、客户端资源栏一致，中间空过 4
RES_TYPE_STONE = 5
RES_BAR_LIST = {RES_TYPE_FOOD, RES_TYPE_WARER, RES_TYPE_WOOD, RES_TYPE_STONE}

COST_TYPE = {
	DIAMOND = 1,
	RES = 2,
	ITEM = 3,
}

ITEM_KIND = {
	RES = 1,
	HERO_CHIP = 2,
	GIFT = 3,
	HERO_EQUIP = 4,
	RANDOM_REWARD = 5,
	SOLDIER = 6,
	VIP = 7,
}

NO_NAME = ""
USER_NAME_MAX_LEN = 12

-- 资源流水原因，reason_list[1]
FLOW_REASON = {
	RECHARGE = 1,
	WIZ = 2,
	MAIL = 3,
	LOTTERY = 4,
	GM = 6,
	TASK = 7,
	ACTIVITY = 8,
	MARCH = 9,
	BATTLE = 10,
	ALLIANCE = 11,
	GATHER = 12,
	MOVE_CITY = 13,
	BUILD = 14,
}

-- 迁主城消耗的道具，对应 Item.Id=1001 迁城令
MOVE_CITY_ITEM = 1001

-- 建筑消耗的四种资源，对应 Item.Id。粮草/木材/铁矿/石料
BUILD_COST_ITEM = {
	GRAIN = 1,
	WOOD = 2,
	IRON = 3,
	STONE = 5,
}

ONE_HOUR_SEC = 3600
ONE_DAY_HOUR = 24
ONE_DAY_SEC = ONE_DAY_HOUR * ONE_HOUR_SEC

INT_SIZE = 32

-- 与 res/map/mapRes_0.lua 格子 type 一致。类型 0 不全是阻挡，阻挡在 terrain.lua
MAP_CELL_TYPE = {
	OBSTRUCT = 0,
	SYS_FORTRESS = 50,
	SYS_CITY = 51,
	WOOD = 52,
	IRON = 53,
	STONE = 54,
	GRAIN = 55,
	FORTRESS = 56,
}

-- 实体类型、行军目标、战报类型、排行榜、聊天频道、联盟职位和加入方式都有枚举表，用 DATA_COMMON.XXX

MARCH_STATE = {
	MOVING = 1,
	ARRIVED = 2,
}

-- 视野半径（格）。1000 地图上 10 格只能看见自己出生点附近；桶边长跟这个值一样
AOI_RADIUS = 80

-- 大地图目标帧间隔（秒）。定时器不会刚好这么久，实际用两次唤醒的时间差补帧
WORLD_TICK_SEC = 0.05

-- 实体 id 分段，避免主城、部队、怪物组互相撞
ENTITY_ID = {
	MONSTER = 1000000000000000,
	TROOP = 2000000000000000,
	CITY = 3000000000000000,
	RES_LAND = 4000000000000000,
}

function city_entity_id(user_id)
	return ENTITY_ID.CITY + user_id
end

function troop_entity_id(user_id, troop_idx)
	return ENTITY_ID.TROOP + user_id * 100 + troop_idx
end

function monster_entity_id(group_id)
	return ENTITY_ID.MONSTER + group_id
end

function res_land_entity_id(land_id)
	return ENTITY_ID.RES_LAND + land_id
end

function res_land_id_of_entity(entity_id)
	return entity_id - ENTITY_ID.RES_LAND
end

RES_LAND_REFRESH = 300			-- 资源地采空后多少秒在别处刷新

TASK_TYPE = {
	MAIN = 1,
	DAILY = 2,
	WEEK = 3,
}

TASK_STATE = {
	DOING = 0,
	CAN_GET = 1,
	GOT = 2,
}

TASK_COND = {
	LOGIN = 1,
	BUILD_LV = 2,
	HERO_CNT = 3,
	LOTTERY = 4,
	HEAD_ICON = 5,
	OWN_ITEM = 6,
	MARCH = 7,
	POWER = 8,
}

ACTIVITY_TYPE = {
	LOGIN = 1,
	RANK = 2,
	LOTTERY = 3,
	RES_RATE = 4,
	GIFT = 5,
	ONLINE = 6,
	EXCHANGE = 7,
}

ACTIVITY_STATE = {
	CLOSED = 0,
	OPEN = 1,
	END = 2,
}

ACTIVITY_TIME = {
	ALWAYS = 1,
	OPEN_DAY = 2,
	WEEKDAY = 3,
	DAILY = 4,
}

-- ---------- 战斗 ----------
BATTLE_SIDE = {
	ATK = 1,
	DEF = 2,
}

BATTLE_RESULT = {
	WIN = 1,
	LOSE = 2,
}

-- 快照里的单位类型：武将读 Hero 配置，怪物读 Monster 配置
BATTLE_UNIT = {
	HERO = 1,
	MONSTER = 2,
}

-- 回放 actType，和 report.proto 一致
BATTLE_ACT = {
	ATTACK = 1,
	ACTIVE = 2,
	PASSIVE = 3,
	PURSUE = 4,
	COMMAND = 5,
	HEAL = 6,
	STATE = 7,
}

-- 回放 flags 的位
BATTLE_FLAG = {
	CRIT = 1,
}

-- Skill.Trigger
SKILL_TRIGGER = {
	ACTIVE = 1,		-- 自己行动时按概率发动
	PASSIVE = 2,	-- 开战时生效
	PURSUE = 3,		-- 普攻后按概率追加
	COMMAND = 4,	-- 开战时生效，先于被动
}

-- Skill.Target
SKILL_TARGET = {
	SELF = 1,
	ALLY_ALL = 4,
	ENEMY_ONE = 5,
	ENEMY_1_2 = 6,
	ENEMY_2_3 = 7,
	ENEMY_ALL = 8,
}

-- Skill.IncludeEffect，和 Levels[].effect_value / effect_round 按下标对应
SKILL_EFFECT = {
	DAMAGE = 1,		-- 伤害率 %
	ATTACK = 2,		-- 攻击 %
	DEFENSE = 3,	-- 防御 %
	INTEL = 4,		-- 谋略 %
	SPEED = 5,		-- 速度 %
}

-- 配置里没有的数值先放这里
BATTLE_MAX_ROUND = 20
BATTLE_DAMAGE_RATE = 0.3		-- 伤害 = 带兵 * 伤害率 * 攻/(攻+防) * 这个系数
BATTLE_CRIT_RATE = 150			-- 暴击伤害 %
BATTLE_HURT_RATE = 50			-- 损失的兵里转为伤兵的 %，其余阵亡
BATTLE_HERO_LV_GROWTH = 5		-- 武将每升一级属性 +%
REPORT_MAX = 30					-- 每人保留的战报数

GM_SUPER_LEVEL = 50				-- 超级号默认主角等级
GM_SUPER_RES = 10000000			-- 超级号每种资源加多少

RANK_PAGE_DEFAULT = 50			-- 排行榜请求 count = 0 或超过上限时用
RANK_PAGE_MAX = 100

-- ---------- 聊天 ----------
CHAT_CONTENT_MAX_LEN = 100		-- 字符数（utf8）
CHAT_INTERVAL = 1				-- 发言间隔秒

-- ---------- 联盟 ----------
-- s2c_sync_member_change.changeType，没有枚举表
ALLIANCE_CHANGE = {
	JOIN = 1,
	LEAVE = 2,
	KICK = 3,
	POS = 4,
}

-- 名字/公告/宣言长度、申请上限、创建消耗数量读 Global 10~14
ALLIANCE_CREATE_ITEM = 4		-- 创建联盟消耗的令牌道具 id
ALLIANCE_LIST_DEFAULT = 20		-- 联盟列表 count = 0 或超过上限时用
ALLIANCE_LIST_MAX = 50
ALLIANCE_INVITE_EXPIRE = 86400	-- 邀请有效期，只存内存

-- ---------- 邮件 ----------
-- Mail 表的模板 id（没有 Enum 列）
MAIL_ID = {
	WELCOME = 1,
	REWARD_REISSUE = 2,
	ACTIVITY_REWARD = 3,
	RANK_REWARD = 4,
	MAINTAIN = 5,
	SERVER_OPEN = 6,
	ALLIANCE_JOIN = 7,
	ALLIANCE_LEAVE = 8,
	ALLIANCE_POS = 9,
	NOTICE = 10,
}

EVENT = {
	ON_USER_LOGIN = "on_user_login",
	ON_USER_LOGOUT = "on_user_logout",
	KICK_USER = "kick_user",
	ON_SYSTEM_OPEN = "on_system_open",
	-- 以下是 agent 内的玩法触发，用 EVENT.dispatch 同步分发，监听方在玩家队列里执行
	-- 跨天/跨周/跨月 (user_id)：在线时由心跳检测，离线跨过的在登录时补发一次。跨周、跨月前一定先发跨天
	ON_NEW_DAY = "on_new_day",
	ON_NEW_WEEK = "on_new_week",
	ON_NEW_MONTH = "on_new_month",
	ON_ONLINE_MINUTE = "on_online_minute",
	ON_USER_LEVEL = "on_user_level",	-- (user_id)，玩家等级提升
	ON_LOTTERY = "on_lottery",
	ON_HEAD_ICON = "on_head_icon",
	ON_HERO_ADD = "on_hero_add",
	ON_HERO_LEVEL = "on_hero_level",	-- (user_id, hero_type)，战力会变
	ON_BUILD_LEVEL = "on_build_level",
	ON_ITEM_CHANGE = "on_item_change",
	ON_MARCH = "on_march",
	ON_RECHARGE = "on_recharge",
	-- 计算类：传一个 ctx 表，监听方同步改里面的倍率，发起方 dispatch 完再用
	ON_CALC_ITEM_REWARD = "on_calc_item_reward",	-- (user_id, ctx{item_id, rate=1})，取最大倍率
	ON_CALC_LOTTERY_COST = "on_calc_lottery_cost",	-- (user_id, ctx{lottery_id, rate=100})，百分比取最低；活动 lottery_id=0 表示全部抽数
}
