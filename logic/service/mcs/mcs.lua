local skynet = require "skynet"
require "skynet.manager"
local socket = require "skynet.socket"

local CMD = {}
local SOCKET = {}
local gate
local agent_pools = {}
local vfd_to_agent = {}
-- 顺序即依赖：先关入口，再让持有数据的服务同步落盘，最后才关 .mongodb
local STOP_SERVICE_LIST = {
	".logind",		-- 不再发新 token
	".gated",		-- 停收消息，agent 逐个下线并落盘
	".mail",
	".gameserver",
	".world",
	".activity",
	".union",
	".game_sid",
	".mongodb",		-- 写完队列里剩下的再断开
	".gamelog",		-- 刷盘，之后改为逐行落盘直到进程退出
}
local is_stopping = false
local is_updating = false
-- main_start 把所有服务拉起后置 true，shell/start.sh 轮询 status 判断启动完成
local is_ready = false

function CMD.set_ready()
	is_ready = true
end

function CMD.status()
	if is_stopping then
		return "stopping"
	end
	return is_ready and "ready" or "starting"
end

local HTTP_AGENT_CNT = skynet.getenv("http_agent_cnt")
local http_agent_pools = {}

local LISTEN_FD = nil

local CAN_OP_ADDR_TBL = {
	["127.0.0.1"] = true,		-- 本机 shell/stop.sh、shell/hot_update.sh
}

function CMD.shutdown()
	socket.close(LISTEN_FD)
	skynet.exit()
end

function CMD.start(conf)
	-- skynet.call(gate, "lua", "open" , conf)
end

-- 单点执行，避免多个 http 请求并发关服把 .mongodb 提前关掉
function CMD.stop()
	if is_stopping then
		return "already stopping"
	end
	if is_updating then
		return "hot updating, try later"
	end
	is_stopping = true
	local fail_list = {}
	for _, service_name in ipairs(STOP_SERVICE_LIST) do
		LOG._debug("shutdown step", service_name)
		local ok, err = pcall(skynet.call, service_name, "lua", "shutdown")
		if not ok then
			skynet.error("shutdown step failed", service_name, err)
			table.insert(fail_list, service_name)
		end
	end
	if fail_list[1] then
		return "stopped, failed: " .. table.concat(fail_list, ",")
	end
	return "stopped"
end

-- agent 由 gated 管理，单独取
local HOT_UPDATE_SERVICE_LIST = {
	".mail",
	".gameserver",
	".world",
	".activity",
	".union",
	".game_sid",
}

local function get_hot_update_targets()
	local list = {}
	for _, addr in ipairs(skynet.call(".gated", "lua", "get_agent_list")) do
		table.insert(list, {name = "agent" .. skynet.address(addr), addr = addr})
	end
	for _, name in ipairs(HOT_UPDATE_SERVICE_LIST) do
		table.insert(list, {name = name, addr = name})
	end
	for i = 1, tonumber(skynet.getenv("battle_cnt")) or 1 do
		table.insert(list, {name = ".battle" .. i, addr = ".battle" .. i})
	end
	return list
end

local function do_hot_update(path_list, is_reload_config)
	-- skynet 的 loadfile 有进程级代码缓存，不清掉各服务拿到的还是旧代码
	skynet.cache.clear()
	for _, path in ipairs(path_list) do
		local func, err = loadfile(path)
		if not func then
			return {ok = false, err = err}
		end
	end
	-- 先换配置再换代码：data.lua 的派生数据要基于新配置重算
	if is_reload_config then
		local ret = skynet.call(".load_xls", "lua", "reload")
		if not ret.ok then
			return {ok = false, err = "reload config: " .. ret.err}
		end
		table.insert(path_list, "../logic/define/data.lua")
	end
	local done_list = {}
	for _, target in ipairs(get_hot_update_targets()) do
		local ok, ret = pcall(skynet.call, target.addr, "lua", "hot_update", path_list)
		if not ok then
			ret = {ok = false, err = tostring(ret)}
		end
		if not ret.ok then
			-- 停在第一个失败的服务，最多只有这一个服务处于半更新状态
			return {ok = false, err = string.format("%s: %s", target.name, ret.err), done_list = done_list}
		end
		table.insert(done_list, target.name)
	end
	return {ok = true, done_list = done_list}
end

-- path_list 写法和 Import 一致，如 "../logic/service/agent/module/hero/mgr.lua"
function CMD.hot_update(_, path_list, is_reload_config)
	if not is_ready or is_stopping or is_updating then
		return {ok = false, err = "server is starting, stopping or updating"}
	end
	is_updating = true
	local ok, ret = pcall(do_hot_update, path_list, is_reload_config)
	is_updating = false
	if not ok then
		return {ok = false, err = tostring(ret)}
	end
	return ret
end

skynet.start(function()
	for _ = 1, HTTP_AGENT_CNT do
		table.insert(http_agent_pools, skynet.newservice("http_agent"))
	end
	local balance = 1
	LISTEN_FD = socket.listen("0.0.0.0", skynet.getenv("http_port"))
	socket.start(LISTEN_FD, function(fd, addr)
		addr = string.split(addr, ":")[1]
		LOG._debug("mcs op addr", addr)
		if not CAN_OP_ADDR_TBL[addr] then
			-- 还没 socket.start，socket.close 不生效
			socket.close_fd(fd)
			return
		end
		local http_agent = http_agent_pools[balance]
		skynet.send(http_agent, "lua", fd)
		balance = balance + 1
		if balance > #http_agent_pools then
			balance = 1
		end
	end)
	skynet.dispatch("lua", function (session, address, cmd, ...)
		local f = CMD[cmd]
		if f then
			if session ~= 0 then
				skynet.ret(skynet.pack(f(address, ...)))
			else
			f(address, ...)
		end
	end
	end)
	skynet.register(".mcs")
end)
