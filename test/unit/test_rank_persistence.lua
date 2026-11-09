local store = dofile("test/helpers/rank_store.lua")
local T = {}
local function resume(co, expected)
    local ok, why = coroutine.resume(co)
    assert(ok, why)
    if expected then assert(why == expected, tostring(why)) end
end

function T.one_changed_entry_writes_only_that_document_and_noop_writes_nothing()
    local M, s = store.setup()
    for kind = 1, 4 do
        for uid = 1, 250 do M.set_score(kind, uid, uid, "p" .. uid, uid) end
    end
    s.mongo.flush_sync()
    s.calls = {}
    M.set_score(2, 123, 900, "changed", 7)
    s.mongo.flush_sync()
    assert(#s.calls == 1 and #s.calls[1].rank_entry_col == 1)
    local cmd = s.calls[1].rank_entry_col[1]
    assert(cmd.key == "2:123" and cmd.value._score == 900)
    M.set_score(2, 123, 900, "changed", 7)
    s.mongo.flush_sync()
    assert(#s.calls == 1)
    local restarted = store.setup(s.rows)
    assert(restarted.get_rank(2, 123) == 1 and restarted.get_rank(1, 250) == 1)
end

function T.same_score_profile_update_preserves_tie_time_and_queued_snapshot()
    local M, s = store.setup()
    M.set_score(1, 1, 100, "old", 1)
    local first = s.mongo.all_cmd_tbl.rank_entry_col[1].value
    s.now = 2000
    M.set_score(1, 2, 100, "second", 2)
    M.set_score(1, 1, 100, "new", 8)
    assert(first._name == "old" and first._head_icon == 1 and first._time == 1000)
    s.mongo.flush_sync()
    assert(s.rows["1:1"]._time == 1000 and s.rows["1:1"]._name == "new")
    local restarted = store.setup(s.rows)
    assert(restarted.get_rank(1, 1) == 1 and restarted.get_rank(1, 2) == 2)
end

function T.suspended_background_ack_preserves_later_delete_readd_and_metadata()
    local M, s = store.setup()
    M.set_score(1, 1, 100, "old", 1)
    s.on_save = function() coroutine.yield("db") end
    local background = coroutine.create(s.mongo.flush)
    resume(background, "db")
    M.set_score(1, 1, 0)
    M.set_score(1, 1, 300, "new", 3)
    s.now = 2000
    M.set_score(1, 1, 300, "latest", 4)
    assert(s.calls[1].rank_entry_col[1].value._score == 100)
    assert(#s.calls == 1)
    resume(background)
    assert(coroutine.status(background) == "dead" and s.rows["1:1"]._score == 100)
    s.on_save = nil
    s.mongo.flush_sync()
    local commands = s.calls[2].rank_entry_col
    assert(#commands == 2 and commands[1].op_type == "del_doc" and commands[2].value._score == 300)
    assert(s.rows["1:1"]._name == "latest" and s.rows["1:1"]._head_icon == 4)
    local restarted = store.setup(s.rows)
    assert(restarted.get_rank_list(1, 1, 1, 1).self.score == 300)
end

function T.failed_old_write_cannot_restore_an_entry_deleted_while_suspended()
    local M, s = store.setup()
    M.set_score(1, 1, 100)
    s.on_save = function() coroutine.yield("db"); error("offline") end
    local background = coroutine.create(s.mongo.flush)
    resume(background, "db")
    M.set_score(1, 1, 0)
    resume(background)
    assert(coroutine.status(background) == "dead")
    s.on_save = nil
    s.mongo.flush_sync()
    assert(s.rows["1:1"] == nil and next(s.mongo.all_cmd_tbl) == nil)
    local commands = s.calls[2].rank_entry_col
    assert(commands[1].value._score == 100 and commands[2].op_type == "del_doc")
    local restarted = store.setup(s.rows)
    assert(restarted.get_rank(1, 1) == 0)
end

function T.failed_ack_retry_then_readd_preserves_newest_entry()
    local M, s = store.setup()
    M.set_score(4, 9, 100, "before", 1)
    local saved
    s.on_save = function(args)
        -- The database may have committed before its acknowledgement was lost.
        saved = args.rank_entry_col[1].value
        s.rows["4:9"] = saved
        coroutine.yield("db")
        error("ack lost")
    end
    local background = coroutine.create(s.mongo.flush)
    resume(background, "db")
    M.set_score(4, 9, 0)
    M.set_score(4, 9, 500, "after", 5)
    resume(background)
    assert(saved._score == 100)
    s.on_save = nil
    s.mongo.flush_sync()
    assert(s.rows["4:9"]._score == 500 and s.rows["4:9"]._name == "after")
end

function T.shutdown_barrier_waits_for_inflight_ack_and_all_later_rank_updates()
    local M, s = store.setup()
    M.set_score(1, 1, 100)
    s.on_save = function() coroutine.yield("db") end
    local background = coroutine.create(s.mongo.flush)
    resume(background, "db")
    local shutdown = coroutine.create(s.mongo.flush_sync)
    resume(shutdown, "queue")
    M.set_score(1, 1, 200)
    resume(background)
    assert(s.wakeups[1] == shutdown)
    resume(shutdown, "db")
    M.set_score(1, 1, 0)
    M.set_score(2, 2, 300)
    resume(shutdown, "db")
    assert(coroutine.status(shutdown) ~= "dead", "barrier must await the final ACK")
    resume(shutdown)
    assert(coroutine.status(shutdown) == "dead" and next(s.mongo.all_cmd_tbl) == nil)
    assert(s.rows["1:1"] == nil and s.rows["2:2"]._score == 300)
    for _, timer in ipairs(s.timers) do timer.run() end
    assert(#s.calls == 3, "stale scheduled callbacks must not repeat writes")
end

return T
