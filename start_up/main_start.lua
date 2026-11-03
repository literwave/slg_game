local skynet = require "skynet"
local cluster = require "skynet.cluster"

-- 从 config/clustername.lua 取 center 节点名（键以 center 开头）
local function center_nodename()
	local conf = {}
	local path = assert(skynet.getenv("cluster"), "cluster config missing")
	local f = assert(io.open(path))
	local source = f:read("*a")
	f:close()
	assert(load(source, "@" .. path, "t", conf))()
	for name, addr in pairs(conf) do
		if type(name) == "string" and name:sub(1, 6) == "center" and type(addr) == "string" then
			return name
		end
	end
	error("no center node in " .. path)
end

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
	-- 向中心节点上报本服就绪；center 未起时 __nowaiting 下会丢掉，不阻塞启动
	-- 这样上报肯定是不稳的，还是通过心跳吧，这样才能保证稳定
	cluster.send(center_nodename(), ".center", "lua", "set_ready", nodename)
	skynet.exit()
end)