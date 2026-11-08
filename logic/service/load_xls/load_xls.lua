local skynet = require "skynet"
local sharedata = require "skynet.sharedata"
require "skynet.manager"
-- 配置文件用 loadfile 读，开着代码缓存重载会拿到旧配置
skynet.cache.mode("OFF")
local CMD = {}

local config_table = require "config_table"

local function load_config(path)
	local chunk, err = loadfile(path)
	if not chunk then
		error(string.format("load config failed: %s (%s)", path, tostring(err)))
	end
	local data = chunk()
	assert(type(data) == "table", "config must return a table: " .. path)
	return config_table.index_by_id(data)
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
	"../game_common/server/res/TargetType.lua",
	"../game_common/server/res/Rank.lua",
	"../game_common/server/res/AllianceLv.lua",
	"../game_common/server/res/Mail.lua",
	"../game_common/server/res/ResLand.lua",
	"../game_common/server/res/ResLandFirst.lua",
	"../game_common/server/res/City.lua",
	"../game_common/server/enum/CityTypeEnum.lua",
	"../game_common/server/enum/EntityTypeEnum.lua",
	"../game_common/server/enum/TargetTypeEnum.lua",
	"../game_common/server/enum/TroopStateEnum.lua",
	"../game_common/server/enum/ReportTypeEnum.lua",
	"../game_common/server/enum/RankTypeEnum.lua",
	"../game_common/server/enum/ChatChannelEnum.lua",
	"../game_common/server/enum/AlliancePosEnum.lua",
	"../game_common/server/enum/AllianceJoinTypeEnum.lua",
	"../game_common/server/enum/MailKindEnum.lua",
	"../game_common/server/enum/ResLandTypeEnum.lua",
	"../game_common/server/enum/SystemOpenEnum.lua",
	"../game_common/server/enum/ErrcodeEnum.lua",
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
	config_table.validate_city_guards(ret)
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
		LOG._debug("sharedata loaded:", filename)
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
