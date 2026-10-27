local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
	skynet.newservice("gamelog") -- save file not save db
	LOG._debug("server start")
	local nodename = (skynet.getenv("nodename") or "game") .. skynet.getenv("host_id")
	cluster.open(nodename)
	LOG._debug("cluster open", nodename)

	skynet.newservice("debug_console", skynet.getenv("console_port") or 8000)
	skynet.newservice("load_xls") -- 配置进 sharedata，须先于业务服务
	skynet.newservice("logind") -- login service
	skynet.newservice("main_mongodb")
	skynet.call(".mongodb", "lua", "start")
	skynet.newservice("game_sid")
	local gate = skynet.newservice("gated")
	skynet.call(gate, "lua", "open", {
		serverId = tonumber(skynet.getenv("host_id")),
		address = skynet.getenv("gate_address"),
		port = skynet.getenv("gate_port"),
	})
	-- -- control hot update or stop srv
	skynet.newservice("mcs") -- http服务
	skynet.newservice("gameserver") -- gameserver can get all userId
	skynet.newservice("mail")
	skynet.newservice("world")
	skynet.newservice("activity")
	skynet.newservice("union") -- 联盟
	for i = 1, tonumber(skynet.getenv("battle_cnt")) or 1 do
		skynet.newservice("battle", i)
	end
	skynet.call(".mcs", "lua", "set_ready")
	skynet.exit()
end)