local skynet = require "skynet"
local sharedata = require "skynet.sharedata"
require "skynet.manager"
-- 配置文件用 loadfile 读，开着代码缓存重载会拿到旧配置
skynet.cache.mode("OFF")
local CMD = {}

-- 星图导出的表是 { {Id=...}, ... }，业务按 Id 取值，加载时转成 [Id] = row。
-- 不是这种形状的表（例如内城布局）原样放进 sharedata。
local function index_by_id(data)
	local first = data[1]
	if type(first) ~= "table" or first.Id == nil then
		return data
	end
	local indexed = {}
	for _, row in ipairs(data) do
		if type(row) == "table" and row.Id ~= nil then
			indexed[row.Id] = row
		end
	end
	return indexed
end

local function load_config(path)
	local chunk, err = loadfile(path)
	if not chunk then
		error(string.format("load config failed: %s (%s)", path, tostring(err)))
	end
	local data = chunk()
	assert(type(data) == "table", "config must return a table: " .. path)
	return index_by_id(data)
end

-- 这里先这样手动加载数据，后续优化成遍历dir目录下的文件，然后new
DATA_FILE_LIST = {
	"../game_common/server/res/Hero.lua",
	"../game_common/server/res/HeroLv.lua",
	"../game_common/server/res/ReportInfo.lua",
	"../game_common/server/res/ServerGroup.lua",
	"../game_common/server/res/Global.lua",
	"../game_common/server/res/BuildingDetail.lua",
	"../game_common/server/res/BuildingLv.lua",
	"../game_common/server/res/HeadIcon.lua",
	"../game_common/server/res/Item.lua",
	"../game_common/server/res/Lottery.lua",
	"../game_common/server/res/SystemOpen.lua",
	"../game_common/server/res/Activity.lua",
	"../game_common/server/res/MainTask.lua",
	"../game_common/server/res/DailyTask.lua",
	"../game_common/server/res/WeekTask.lua",
	"../game_common/server/res/MonsterGroup.lua",
	"../game_common/server/res/Monster.lua",
	"../game_common/server/res/Skill.lua",
	"../game_common/server/res/EntityType.lua",
	"../game_common/server/res/TargetType.lua",
	"../game_common/server/res/TroopState.lua",
	"../game_common/server/res/RankType.lua",
	"../game_common/server/res/ReportType.lua",
	"../game_common/server/res/ChatChannel.lua",
	"../game_common/server/res/AllianceLv.lua",
	"../game_common/server/res/AlliancePos.lua",
	"../game_common/server/res/AllianceJoinType.lua",
	"../game_common/server/res/Mail.lua",
	"../game_common/server/res/MailKind.lua",
	"../game_common/server/res/ResLand.lua",
	"../game_common/server/res/ResLandType.lua",
	"../res/innerCity.lua",
}

function CMD.shutdown()
	skynet.exit()
end

local function read_all()
	local ret = {}
	for _, file in ipairs(DATA_FILE_LIST) do
		local filename = file:match("([^/\\]+)%.lua$")
		assert(filename, "bad config path: " .. tostring(file))
		ret[filename] = load_config(file)
	end
	return ret
end

-- 全部读成功才替换，避免一张表坏了导致新旧配置混用
function CMD.reload()
	local ok, data_tbl = pcall(read_all)
	if not ok then
		return {ok = false, err = tostring(data_tbl)}
	end
	for filename, data in pairs(data_tbl) do
		sharedata.update(filename, data)
	end
	return {ok = true}
end

skynet.start(function()
	for filename, data in pairs(read_all()) do
		sharedata.new(filename, data)
		skynet.error("sharedata loaded:", filename)
	end
	skynet.dispatch("lua", function(session, source, cmd, ...)
		local f = assert(CMD[cmd], cmd)
		local ret = f(...)
		if session ~= 0 then
			skynet.ret(skynet.pack(ret))
		end
	end)
	skynet.register(".load_xls")
end)
