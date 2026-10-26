
LOG		= Import("../logic/base/log.lua")
GAME		= Import("../logic/game.lua")
CONST		= Import("../logic/define/const.lua")
DATA_COMMON	= Import("../logic/define/data.lua")
FUNCLIB 	= Import("../common/funclib.lua")
CB_MGR		= Import("../common/cb_mgr.lua")
CALL_OUT	= Import("../common/call_out.lua")
EVENT		= Import("../common/event.lua")
MAIL		= Import("../common/mail.lua")
GLOBAL_FUNC	= Import("../common/global_func.lua")
TIME		= Import("../common/time.lua")
MARCH_PATH	= Import("../common/march_path.lua")

ORM		= Import("../orm/init.lua")

USER_BASE	= Import("../logic/service/agent/module/user/base.lua")
USER_MGR	= Import("../logic/service/agent/module/user/mgr.lua")
json4_lua	= Import("../common/json.lua")
MONGO_SLAVE	= Import("../logic/base/mongo_slave.lua")
LMDB		= Import("../logic/service/agent/lua_mdb.lua")

CLS_HERO	= Import("../logic/service/agent/module/hero/base.lua")
HERO_MGR	= Import("../logic/service/agent/module/hero/mgr.lua")

ITEM_MGR	= Import("../logic/service/agent/module/item/mgr.lua")


-- BLACK_LIST	= Import("../logic/module/black_list/black_list.lua")
-- RANDOM_NAME	= Import("../logic/module/name/random_name.lua")
-- CHAT_BASE     = Import("chat/base.lua")
-- CHAT_MGR      = Import("chat/mgr.lua")

REWARD_MGR	= Import("../logic/service/agent/module/reward/mgr.lua")
BUILD_BASE	= Import("../logic/service/agent/module/build/base.lua")
BUILD_MGR	= Import("../logic/service/agent/module/build/mgr.lua")

RESOURCE	= Import("../logic/service/agent/module/resource/resource.lua")
LOTTERY		= Import("../logic/service/agent/module/lottery/lottery.lua")

CLS_BASE_ITEM 	= Import("../logic/service/agent/module/item/base.lua")
CLS_HERO_EQUIP_ITEM = Import("../logic/service/agent/module/item/hero_equip.lua")

GM = Import("../logic/service/agent/module/gm/gm.lua")

SYSTEM_OPEN = Import("../logic/service/agent/module/system_open/mgr.lua")

TROOP_BASE = Import("../logic/service/agent/module/troop/base.lua")
TROOP_MGR = Import("../logic/service/agent/module/troop/mgr.lua")

TASK_MGR = Import("../logic/service/agent/module/task/mgr.lua")
ACTIVITY_MGR = Import("../logic/service/agent/module/activity/mgr.lua")
MARCH_MGR = Import("../logic/service/agent/module/march/mgr.lua")
REPORT_MGR = Import("../logic/service/agent/module/report/mgr.lua")
BATTLE_MGR = Import("../logic/service/agent/module/battle/mgr.lua")
SOCIAL_MGR = Import("../logic/service/agent/module/social/mgr.lua")
MAIL_MGR = Import("../logic/service/agent/module/mail/mgr.lua")
MARK_MGR = Import("../logic/service/agent/module/mark/mgr.lua")