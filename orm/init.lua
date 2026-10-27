-- 游戏侧 ORM 入口：加载 schema_path 下的 *.td，转发到 lualib/orm

local skynet = require "skynet"
local core = require "orm"
local typedef = require "orm.typedef"

CLS_USER_DATA = "user_data"
CLS_HERO_DATA = "hero_data"
CLS_USER_HERO_DOC = "user_hero_doc"
CLS_ITEM_DATA = "item_data"
CLS_USER_ITEM_DOC = "user_item_doc"
CLS_USER_MAIL_DOC = "user_mail_doc"
CLS_SVR_MAIL_DOC = "svr_mail_doc"
CLS_GAME_SID_DATA = "game_sid_data"
CLS_BUILD_DATA = "build_data"
CLS_USER_BUILD_DOC = "user_build_doc"
CLS_TROOP_DATA = "troop_data"
CLS_USER_TROOP_DOC = "user_troop_doc"
CLS_USER_TASK_DOC = "user_task_doc"
CLS_USER_ACTIVITY_DOC = "user_activity_doc"
CLS_SERVER_DATA = "server_data"
CLS_USER_REPORT_DOC = "user_report_doc"
CLS_ALLIANCE_DATA = "alliance_data"
CLS_LAND_DATA = "land_data"

local SCHEMA_FILES = {
	"user.td",
	"hero.td",
	"item.td",
	"mail.td",
	"game_sid.td",
	"build.td",
	"troop.td",
	"task.td",
	"activity.td",
	"server.td",
	"report.td",
	"alliance.td",
	"land.td",
}

local function load_schemas()
	local dir = skynet.getenv("schema_path")
	assert(dir and dir ~= "", "schema_path is empty")
	local type_list = {}
	for _, file in ipairs(SCHEMA_FILES) do
		for _, item in ipairs(typedef.parse(file, dir)) do
			table.insert(type_list, item)
		end
	end
	core.init(type_list)
end

-- 热更这个文件时不重建类型：已有对象挂着旧类型，重建后赋值校验会全部失败。改 .td 要重启
if not core.inited then
	load_schemas()
end

new = core.new
bind = core.bind
get = core.get
unbind = core.unbind
touch = core.touch
dump = core.dump

-- 取已绑定的文档；没有就从 mongo 读出来建好并绑定。第二个返回值为 true 表示这次刚加载
function load(col, key, cls_name)
	local doc = core.get(col, key)
	if doc then
		return doc, false
	end
	doc = core.new(cls_name, MONGO_SLAVE.common_load_single(col, key))
	core.bind(doc, col, key)
	return doc, true
end
