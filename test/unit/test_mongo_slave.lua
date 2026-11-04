local T = {}
local function setup(rpc)
	local timers, calls, dirty, wakeups = {}, {}, {}, {}
	local skynet = {
		timeout = function(delay, fn) timers[#timers + 1] = {delay = delay, fn = fn} end,
		error = function() end,
		wait = function() return coroutine.yield("queue") end,
		wakeup = function(co) wakeups[#wakeups + 1] = co end,
		call = function(_, _, cmd, args)
			calls[#calls + 1] = {cmd = cmd, args = args}
			if rpc then return rpc(cmd, args, #calls) end
			return true
		end,
	}
	-- 实际 skynet.queue 实现；通过协程控制数据库响应时间。
	local queue_env = setmetatable({require = function() return skynet end}, {__index = _G})
	local queue = assert(loadfile("skynet/lualib/skynet/queue.lua", "t", queue_env))()
	local orm = {drain = function()
		local list = {}
		for i, doc in ipairs(dirty) do list[i] = doc end
		for i = #dirty, 1, -1 do dirty[i] = nil end
		return list
	end}
	local env = setmetatable({
		require = function(name)
			if name == "skynet" then return skynet end
			if name == "skynet.queue" then return queue end
			if name == "orm" then return orm end
			return require(name)
		end,
		GAME = {get_data_base = function() return "test" end},
	}, {__index = _G})
	assert(loadfile("logic/base/mongo_slave.lua", "t", env))()
	return env, calls, timers, dirty, wakeups
end

function T.coalesces_short_window_and_flush_sync_is_immediate()
	local env, calls, timers = setup()
	env.save_doc("user", 1, {hp = 1})
	env.save_doc("user", 2, {hp = 2})
	assert(#timers == 1 and timers[1].delay == 5 and #calls == 0)
	env.flush_sync()
	assert(#calls == 1 and #calls[1].args.user == 2)
	timers[1].fn()
	assert(#calls == 1, "empty scheduled flush should not contact db")
end

function T.failed_flush_retains_orm_and_manual_changes_in_order()
	local fail, env, dirty = true
	local calls, timers
	env, calls, timers, dirty = setup(function(_, _, n)
		if fail then
			env.save_doc_field("user", 1, "hp", 2)
			error("database disconnected")
		end
		return true
	end)
	dirty[1] = {col = "user", key = 1, dat = {hp = 1}}
	assert(not pcall(env.flush_sync))
	assert(#env.all_cmd_tbl.user == 2, "failed drained ORM snapshot must remain pending")
	assert(env.all_cmd_tbl.user[1].field_str == "dat")
	assert(env.all_cmd_tbl.user[2].value == 2)
	fail = false
	env.flush_sync()
	assert(next(env.all_cmd_tbl) == nil and #calls == 2)
	assert(#calls[2].args.user == 2)
end

function T.false_or_missing_ack_is_not_success()
	for _, response in ipairs({false, "nil"}) do
		local env = setup(function()
			if response == "nil" then return nil end
			return response
		end)
		env.save_doc("user", 1, {})
		assert(not pcall(env.flush_sync))
		assert(env.all_cmd_tbl.user[1].key == 1)
	end
end

function T.concurrent_flush_waits_and_never_overwrites_new_state_with_old()
	local env, calls, _, dirty, wakeups = setup(function()
		coroutine.yield("db")
		return true
	end)
	env.save_doc("user", 1, {hp = 1})
	local a = coroutine.create(env.flush_sync)
	local b = coroutine.create(env.flush_sync)
	local ok, why = coroutine.resume(a)
	assert(ok and why == "db")
	dirty[1] = {col = "user", key = 1, dat = {hp = 2}}
	ok, why = coroutine.resume(b)
	assert(ok and why == "queue", "second flush must wait for the first acknowledgement")
	assert(#calls == 1)
	ok, why = coroutine.resume(a)
	assert(ok and why == "db" and #calls == 2)
	assert(calls[2].args.user[1].value.hp == 2)
	assert(coroutine.resume(a))
	assert(coroutine.status(a) == "dead" and wakeups[1] == b)
	assert(coroutine.resume(b))
	assert(coroutine.status(b) == "dead" and #calls == 2)
end

function T.load_many_uses_indexed_batches_preserving_key_types()
	local env, calls = setup(function(cmd, args)
		assert(cmd == "find_all")
		local rows = {}
		for _, key in ipairs(args.query._id["$in"]) do
			if key ~= 3 then rows[#rows + 1] = {_id = key, dat = {key = key}} end
		end
		return rows
	end)
	local keys = {}
	for i = 1, 600 do keys[i] = i end
	keys[601], keys[602] = 1, "1"
	local result = env.common_load_many("user", keys)
	assert(#calls == 3 and result[600].key == 600)
	assert(result[1].key == 1 and result["1"].key == "1" and result[3] == nil)
	env.common_load_many("user", {})
	assert(#calls == 3)
end

return T
