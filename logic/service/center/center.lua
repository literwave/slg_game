local skynet = require "skynet"
require "skynet.manager"

-- 中心协调：各 game 节点就绪后 cluster.send 到这里

local CMD = {}
-- [nodename] = true
local ready_nodes = {}

function CMD.shutdown()
	skynet.fork(skynet.exit)
end

function CMD.set_ready(nodename)
	ready_nodes[nodename] = true
	LOG._debug("game node ready", nodename)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("center no callback", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
	skynet.register(".center")
	LOG._debug("boot center success")
end)
