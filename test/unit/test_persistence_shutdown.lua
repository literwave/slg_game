local T = {}
local function service(path, options)
	local calls, closed, dispatch, response = {}, {}, nil, nil
	local new_count, exits = 0, 0
	local skynet = {
		getenv = function(name)
			if name == "agent_init_cnt" then return 2 end
			if name == "gate_cnt" then return 2 end
			if name == "http_agent_cnt" then return 0 end
			return 1
		end,
		start = function(fn) fn() end,
		dispatch = function(_, fn) dispatch = fn end,
		register = function() end,
		pack = function(...) return {...} end,
		ret = function(r) response = r end,
		self = function() return 1 end,
		error = function() end,
		newservice = function(name) new_count = new_count + 1; return name .. new_count end,
		localname = function(name) return name end,
		call = function(addr, _, cmd, ...)
			calls[#calls + 1] = {addr = addr, cmd = cmd}
			if options.rpc then return options.rpc(addr, cmd, ...) end
		end,
		send = function() end,
		fork = function(fn) fn() end,
		exit = function() exits = exits + 1 end,
	}
	local sock = {listen = function() return 42 end, start = function() end,
		close = function(fd) closed[#closed + 1] = fd end}
	local env = setmetatable({
		require = function(name)
			if name == "skynet" then return skynet end
			if name == "skynet.manager" then return {} end
			if name == "skynet.socket" then return sock end
			return require(name)
		end,
		dofile = function() end,
		LOG = {_debug = function() end},
		MONGO_SLAVE = {flush_sync = function()
			calls[#calls + 1] = {cmd = "flush_sync"}
			if options.fail_flush then error("not saved") end
		end},
	}, {__index = _G})
	assert(loadfile(path, "t", env))()
	local function cmd(name, ...)
		response = nil
		dispatch(1, 0, name, ...)
		return response and table.unpack(response)
	end
	return cmd, calls, closed, function() return exits end
end

function T.shutdown_failure_keeps_database_alive_and_can_retry()
	local fail = true
	local cmd, calls = service("logic/service/mcs/mcs.lua", {rpc = function(addr)
		if addr == ".gated" and fail then error("database unavailable") end
	end})
	cmd("set_ready")
	assert(cmd("stop"):find("^stop failed"))
	assert(cmd("status") == "stop_failed")
	assert(#calls == 2 and calls[2].addr == ".gated", "must stop before closing MongoDB")
	fail = false
	assert(cmd("stop") == "stopped")
	local login_calls, mongo_calls = 0, 0
	for _, c in ipairs(calls) do
		if c.addr == ".logind" then login_calls = login_calls + 1 end
		if c.addr == ".mongodb" then mongo_calls = mongo_calls + 1 end
	end
	assert(login_calls == 1 and mongo_calls == 1, "retry skips already stopped services")
end

function T.gateway_retry_skips_agents_already_saved_and_exited()
	local fail = true
	local cmd, calls, closed, exits = service("logic/service/gated/gated.lua", {rpc = function(addr, name)
		if addr == "agent2" and name == "shutdown" and fail then error("not saved") end
	end})
	cmd("open", {port = 123})
	assert(not pcall(cmd, "shutdown") and exits() == 0)
	fail = false
	cmd("shutdown")
	local first = 0
	for _, c in ipairs(calls) do
		if c.addr == "agent1" and c.cmd == "shutdown" then first = first + 1 end
	end
	assert(first == 1 and #closed == 1 and exits() == 1)
end

function T.ranking_and_world_wait_for_persistence_before_exit()
	for _, name in ipairs({"activity", "world"}) do
		local opts = {fail_flush = true}
		local cmd, calls, _, exits = service("logic/service/" .. name .. "/" .. name .. ".lua", opts)
		assert(not pcall(cmd, "shutdown") and exits() == 0)
		opts.fail_flush = false
		cmd("shutdown")
		assert(exits() == 1 and calls[1].cmd == "flush_sync")
	end
end

return T
