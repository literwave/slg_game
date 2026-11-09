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
	local orm = {has_dirty = function() return #dirty > 0 end, drain = function(limit)
		local list = {}
		for _ = 1, math.min(limit or #dirty, #dirty) do list[#list + 1] = table.remove(dirty, 1) end
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

function T.background_bounds_orm_dump_and_yields_after_each_ack()
	local env, calls, timers, dirty = setup()
	for i = 1, 150 do dirty[i] = {col = "users", key = i, dat = {n = i}} end
	env.flush()
	assert(#calls == 1 and #calls[1].args.users == 64 and #dirty == 86)
	assert(#timers == 1 and timers[1].delay == 1, "ACK must schedule a new turn, not dump every player inline")
	timers[1].fn()
	assert(#calls == 2 and #calls[2].args.users == 64 and #dirty == 22)
	timers[2].fn()
	assert(#calls == 3 and #calls[3].args.users == 22 and #dirty == 0)
	assert(#timers == 2)
end

function T.slow_database_does_not_accumulate_background_lock_waiters()
	local env, calls, timers, _, wakeups = setup(function() coroutine.yield("db"); return true end)
	env.save_doc("user", 1, {hp = 1})
	local worker = coroutine.create(timers[1].fn)
	local ok, why = coroutine.resume(worker)
	assert(ok and why == "db" and env.flush_running)
	for i = 2, 100 do
		env.save_doc("user", 1, {hp = i})
		assert(env.flush(), "periodic timers must skip in-flight writer without waiting")
	end
	assert(#timers == 1 and #calls == 1 and #wakeups == 0)
	assert(coroutine.resume(worker) and coroutine.status(worker) == "dead")
	assert(#timers == 2 and timers[2].delay == 1)
	worker = coroutine.create(timers[2].fn)
	ok, why = coroutine.resume(worker)
	assert(ok and why == "db" and #calls[2].args.user == 1)
	assert(calls[2].args.user[1].value.hp == 100, "compact duplicate full snapshots before IPC")
	assert(coroutine.resume(worker) and #wakeups == 0)
end

function T.failed_background_preserves_newer_partial_write_and_retry_delay()
	local failed, env = true
	local calls, timers
	env, calls, timers = setup(function()
		if failed then env.save_doc_field("user", 1, "hp", 2); error("offline") end
		return true
	end)
	env.save_doc("user", 1, {hp = 1})
	assert(not env.flush())
	assert(#timers == 2 and timers[2].delay == 500)
	timers[1].fn()
	assert(#calls == 1, "old 50ms timer must not bypass retry backoff")
	failed = false
	timers[2].fn()
	assert(#calls == 2 and #calls[2].args.user == 2)
	assert(calls[2].args.user[1].field_str == "dat" and calls[2].args.user[1].value.hp == 1)
	assert(calls[2].args.user[2].field_str == "dat.hp" and calls[2].args.user[2].value == 2)
	assert(next(env.all_cmd_tbl) == nil)
end

function T.background_bounds_manual_writes_without_starving_collections()
	local env, calls = setup()
	for i = 1, 100 do
		env.save_doc("users", i, {i = i})
		env.save_doc("heroes", i, {i = i})
	end
	env.flush()
	assert(#calls == 1 and #calls[1].args.users == 32 and #calls[1].args.heroes == 32)
	env.flush_sync()
	assert(#calls == 2 and #calls[2].args.users == 68 and #calls[2].args.heroes == 68)
	for _, col in ipairs({"users", "heroes"}) do
		for i, cmd in ipairs(calls[2].args[col]) do assert(cmd.key == i + 32) end
	end
end

function T.shutdown_waits_for_background_ack_then_drains_new_dirty_data()
	local env, calls, timers, dirty, wakeups = setup(function() coroutine.yield("db"); return true end)
	for i = 1, 70 do env.save_doc("users", i, {i = i}) end
	local background = coroutine.create(timers[1].fn)
	local ok, why = coroutine.resume(background)
	assert(ok and why == "db" and #calls[1].args.users == 64)
	local shutdown = coroutine.create(env.flush_sync)
	ok, why = coroutine.resume(shutdown)
	assert(ok and why == "queue")
	dirty[1] = {col = "heroes", key = 1, dat = {level = 2}}
	assert(coroutine.resume(background) and coroutine.status(background) == "dead" and wakeups[1] == shutdown)
	ok, why = coroutine.resume(shutdown)
	assert(ok and why == "db" and #calls[2].args.users == 6 and calls[2].args.heroes[1].value.level == 2)
	dirty[1] = {col = "heroes", key = 1, dat = {level = 3}}
	ok, why = coroutine.resume(shutdown)
	assert(ok and why == "db" and calls[3].args.heroes[1].value.level == 3)
	assert(coroutine.resume(shutdown) and coroutine.status(shutdown) == "dead")
	assert(#dirty == 0 and next(env.all_cmd_tbl) == nil)
	for _, timer in ipairs(timers) do timer.fn() end
	assert(#calls == 3, "leftover background timer must not repeat acknowledged writes")
end


function T.snapshot_ack_returns_despite_continuous_other_player_writes()
    local env, calls, _, dirty = setup(function() coroutine.yield("db"); return true end)
    dirty[1] = {col = "users", key = 1, dat = {score = 10}}
    local snapshot = coroutine.create(env.flush_snapshot)
    local ok, why = coroutine.resume(snapshot)
    assert(ok and why == "db" and calls[1].args.users[1].key == 1)
    dirty[1] = {col = "users", key = 2, dat = {score = 20}}
    env.save_doc_field("users", 3, "score", 30)
    assert(coroutine.resume(snapshot) and coroutine.status(snapshot) == "dead")
    assert(#calls == 1 and #dirty == 1 and env.all_cmd_tbl.users[1].key == 3,
        "a player's ACK must not consume writes created by other players while waiting")
    for score = 21, 25 do
        local background = coroutine.create(env.flush)
        ok, why = coroutine.resume(background)
        assert(ok and why == "db")
        dirty[1] = {col = "users", key = 2, dat = {score = score}}
        assert(coroutine.resume(background) and coroutine.status(background) == "dead")
        assert(#dirty == 1, "new writes stay available for a later background turn")
    end
    local background = coroutine.create(env.flush)
    ok, why = coroutine.resume(background)
    assert(ok and why == "db" and calls[#calls].args.users[1].value.score == 25)
    assert(coroutine.resume(background) and #dirty == 0 and next(env.all_cmd_tbl) == nil)
end

function T.snapshot_waits_for_prior_ack_then_captures_all_current_documents()
    local env, calls, _, dirty, wakeups = setup(function() coroutine.yield("db"); return true end)
    env.save_doc("users", 1, {score = 1})
    local background = coroutine.create(env.flush)
    local ok, why = coroutine.resume(background)
    assert(ok and why == "db")
    for i = 1, 150 do dirty[i] = {col = "heroes", key = i, dat = {level = i}} end
    local snapshot = coroutine.create(env.flush_snapshot)
    ok, why = coroutine.resume(snapshot)
    assert(ok and why == "queue" and #calls == 1)
    assert(coroutine.resume(background) and wakeups[1] == snapshot)
    ok, why = coroutine.resume(snapshot)
    assert(ok and why == "db" and #calls[2].args.heroes == 150,
        "snapshot barriers include the whole current snapshot, not just 64 documents")
    dirty[1] = {col = "heroes", key = 151, dat = {level = 151}}
    assert(coroutine.resume(snapshot) and coroutine.status(snapshot) == "dead")
    assert(#calls == 2 and #dirty == 1 and dirty[1].key == 151)
end

function T.failed_snapshot_retains_old_commands_before_newer_changes()
    local fail = true
    local env, calls, _, dirty = setup(function()
        coroutine.yield("db")
        if fail then error("database disconnected") end
        return true
    end)
    env.save_doc("users", 1, {score = 1})
    local snapshot = coroutine.create(env.flush_snapshot)
    local ok, why = coroutine.resume(snapshot)
    assert(ok and why == "db")
    env.save_doc_field("users", 1, "score", 2)
    dirty[1] = {col = "heroes", key = 2, dat = {level = 3}}
    ok = coroutine.resume(snapshot)
    assert(not ok and #env.all_cmd_tbl.users == 2 and #dirty == 1)
    assert(env.all_cmd_tbl.users[1].field_str == "dat" and env.all_cmd_tbl.users[1].value.score == 1)
    assert(env.all_cmd_tbl.users[2].field_str == "dat.score" and env.all_cmd_tbl.users[2].value == 2)
    fail = false
    snapshot = coroutine.create(env.flush_snapshot)
    ok, why = coroutine.resume(snapshot)
    assert(ok and why == "db" and #calls[2].args.users == 2 and calls[2].args.heroes[1].value.level == 3)
    assert(coroutine.resume(snapshot) and coroutine.status(snapshot) == "dead")
    assert(next(env.all_cmd_tbl) == nil and #dirty == 0)
end

return T
