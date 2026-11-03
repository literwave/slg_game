local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
	skynet.newservice("gamelog")
	LOG._debug("center server start")
	local nodename = (skynet.getenv("nodename") or "center") .. skynet.getenv("host_id")
	cluster.open(nodename)
	LOG._debug("cluster open", nodename)

	skynet.newservice("debug_console", skynet.getenv("console_port") or 8001)
	skynet.newservice("center") -- 收各 game 的 set_ready
	-- 运维 HTTP：就绪检测 / 关服。玩法服务后续再往这里挪
	skynet.newservice("mcs")
	skynet.call(".mcs", "lua", "set_ready")
	skynet.exit()
end)
