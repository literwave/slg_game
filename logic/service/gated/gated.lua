local skynet = require "skynet"
require "skynet.manager"
local socket = require "skynet.socket"

-- 网关入口：只监听和 accept，连接轮流交给 gate_cnt 个 gate_worker 处理读写
-- agent 池也在这里统一创建，所有 worker 共用同一份列表

local GATE_CNT = tonumber(skynet.getenv("gate_cnt")) or 1
local AGENT_CNT = tonumber(skynet.getenv("agent_init_cnt")) or 1
local LISTEN_BACKLOG = math.floor(tonumber(skynet.getenv("listen_backlog")) or 32)
if LISTEN_BACKLOG < 1 then
	LISTEN_BACKLOG = 32
end

local CMD = {}
local LISTEN_FD = nil
local is_closing = false
local worker_list = {}
local agent_list = {}
local balance = 1

function CMD.open(conf)
	for _ = 1, AGENT_CNT do
		table.insert(agent_list, skynet.newservice("agent"))
	end
	for _ = 1, GATE_CNT do
		local worker = skynet.newservice("gate_worker")
		skynet.call(worker, "lua", "init", agent_list)
		table.insert(worker_list, worker)
	end
	local address = conf.address or "0.0.0.0"
	LISTEN_FD = socket.listen(address, conf.port, LISTEN_BACKLOG)
	LOG._debug("gate listen on %s:%s, worker=%d, agent=%d, backlog=%d", address, conf.port, GATE_CNT, AGENT_CNT, LISTEN_BACKLOG)
	socket.start(LISTEN_FD, function(fd, addr)
		if is_closing then
			socket.close_fd(fd)
			return
		end
		skynet.send(worker_list[balance], "lua", "accept", fd, addr)
		balance = balance % #worker_list + 1
	end)
	skynet.send(".logind", "lua", "register_gate", skynet.self(), conf.serverId, string.format("%s:%s", address, conf.port))
end

function CMD.get_agent_list()
	return agent_list
end

-- 顺序：停收连接 -> worker 停止转发 -> agent 逐个下线存盘 -> worker 断开客户端
local stopped_agents, stopped_workers = {}, {}
function CMD.shutdown()
	if not is_closing then
		is_closing = true
		socket.close(LISTEN_FD)
	end
	for _, worker in ipairs(worker_list) do
		if not stopped_workers[worker] then skynet.call(worker, "lua", "stop_forward") end
	end
	for _, agent in ipairs(agent_list) do
		if not stopped_agents[agent] then
			skynet.call(agent, "lua", "shutdown")
			stopped_agents[agent] = true
		end
	end
	for _, worker in ipairs(worker_list) do
		if not stopped_workers[worker] then
			skynet.call(worker, "lua", "shutdown")
			stopped_workers[worker] = true
		end
	end
	skynet.fork(skynet.exit)
end

skynet.start(function()
	skynet.dispatch("lua", function (session, address, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("gated unknown cmd", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
	skynet.register(".gated")
end)
