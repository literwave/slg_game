local T = {}
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function upvalue(fn, wanted)
    for i = 1, 40 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error("missing upvalue " .. wanted)
end

local function fixture(with_agent)
    local state = {flushes = 0, emitted = 0, dispatched = 0, rank_snapshots = 0,
        sent = {}, wakeups = {}, dispatchers = {}, timers = {}, weak = setmetatable({}, {__mode = "k"})}
    local sky = {
        self = function() return 77 end, now = function() return 0 end,
        getenv = function() return state.metrics and "1" or nil end,
        timeout = function(delay, fn) state.timers[#state.timers + 1] = {delay = delay, fn = fn} end, register_protocol = function() end,
        wait = function() return coroutine.yield("queue") end,
        wakeup = function(co) state.wakeups[#state.wakeups + 1] = co end,
        send = function(...) state.sent[#state.sent + 1] = {...}; return 0 end,
        error = function() end, start = function(fn) fn() end,
        fork = function(fn) fn() end, exit = function() state.exited = true end,
        dispatch = function(kind, fn) state.dispatchers[kind] = fn end,
        call = function() return coroutine.yield("confirmation") end,
    }
    local core = assert(loadfile("lualib/orm/init.lua"))()
    core.init({{name = "doc", type = "struct", attrs = {value = {type = "number"}}}})
    local C = setmetatable({}, {__index = _G})
    assert(loadfile("logic/define/const.lua", "t", C))()
    local columns = {USER_INFO = "user", USER_HERO = "hero", USER_ITEM = "item", USER_BUILD = "build",
        USER_TROOP = "troop", USER_TASK = "task", USER_SKILL = "skill", USER_REPORT = "report"}
    local modules = {}
    local shared = setmetatable({CONST = C, ORM = core, TIME = {os_bj_sec = function() return 100000 end},
        for_maker = {}, for_caller = {}, dofile = function() end,
        LOG = {_debug = function() end, _error = function() end},
        ACTIVITY_MGR = {on_user_logout = function() state.rank_snapshots = state.rank_snapshots + 1 end},
    }, {__index = _G})
    local real_queue = assert(loadfile("skynet/lualib/skynet/queue.lua", "t", setmetatable({
        require = function() return sky end}, {__index = _G})))()
    shared.require = function(name)
        if name == "skynet" then return sky end
        if name == "skynet.queue" then return real_queue end
        if name == "protobuf" then return {decode = function() return {} end} end
        return require(name)
    end
    shared.MONGO_SLAVE = {COL = columns,
        flush = function() error("logout must use a single final acknowledgement") end,
        flush_sync = function()
            state.flushes = state.flushes + 1
            if state.pause_save then coroutine.yield("db_ack") end
            if state.fail_save then error("database unavailable") end
            state.saved = core.drain()
            return true
        end}
    local persist = shared.MONGO_SLAVE.flush_sync
    shared.MONGO_SLAVE.flush_snapshot = function()
        state.snapshot_flushes = (state.snapshot_flushes or 0) + 1
        return persist()
    end
    shared.MONGO_SLAVE.flush_sync = function()
        state.drain_flushes = (state.drain_flushes or 0) + 1
        return persist()
    end
    shared.EVENT = {
        listen = function() end, register = function() end,
        dispatch = function(event, uid)
            assert(event == C.EVENT.ON_USER_LOGOUT)
            state.dispatched = state.dispatched + 1
            for _, mod in ipairs(modules) do mod.on_user_logout(uid) end
        end,
        emit = function(event, uid)
            assert(event == C.EVENT.ON_USER_LOGOUT)
            assert(not shared.USER_MGR.get_user_by_id(uid), "notifications must follow complete local cleanup")
            state.emitted = state.emitted + 1
            if state.pause_emit then coroutine.yield("notification") end
        end,
        fire = function(event) assert(event == C.EVENT.ON_USER_LOGIN) end,
    }
    local function load_mod(name)
        local env = setmetatable({}, {__index = shared})
        assert(loadfile("logic/service/agent/module/" .. name .. "/mgr.lua", "t", env))()
        return env
    end
    for _, name in ipairs({"hero", "item", "build", "troop", "task", "skill", "report"}) do
        local mod = load_mod(name)
        modules[#modules + 1] = mod
        shared[name:upper() .. "_MGR"] = mod
    end
    local U = load_mod("user"); shared.USER_MGR = U
    state.U, state.core, state.shared, state.columns, state.sky = U, core, shared, columns, sky
    function state.add_user(uid, fd, objects)
        local docs = {}
        for _, col in pairs(columns) do
            local doc = core.new("doc", {value = uid})
            core.bind(doc, col, uid); core.touch(doc)
            state.weak[doc] = true; docs[col] = doc
        end
        local user = {_data = docs.user, fd = fd, heart = 0, gate = 88}
        function user:on_logout() self._data.value = self._data.value + 1 end
        function user:get_gate_srv() return self.gate end
        function user:get_heart_beat_time() return self.heart end
        function user:set_heart_beat_time(value) self.heart = value end
        function user:set_fd(value) self.fd = value end
        function user:set_gate_srv(value) self.gate = value end
        function user:set_token() end; function user:set_account() end; function user:set_login_addr() end
        state.weak[user] = true
        U.all_user_tbl[uid], U.user_id_to_fd[uid] = user, fd
        if fd then U.fd_to_user_id[fd] = uid end
        shared.HERO_MGR.user_hero_tbl[uid] = {}
        shared.ITEM_MGR.all_item_tbl[uid] = {[1] = {}}
        shared.ITEM_MGR.all_item_uid_tbl[uid] = {}
        shared.ITEM_MGR.all_item_kind_tbl[uid] = {[1] = {}}
        for i = 1, objects or 1 do
            local hero, item = {doc = docs.hero}, {doc = docs.item}
            state.weak[hero], state.weak[item] = true, true
            shared.HERO_MGR.user_hero_tbl[uid][i] = hero
            shared.ITEM_MGR.all_item_tbl[uid][1][i] = item
            shared.ITEM_MGR.all_item_uid_tbl[uid][i] = item
            shared.ITEM_MGR.all_item_kind_tbl[uid][1][i] = item
        end
        shared.BUILD_MGR.all_user_build_tbl[uid] = {docs.build}
        shared.TROOP_MGR.all_user_troop_tbl[uid] = {docs.troop}
        return user
    end
    function state.assert_bound(uid, expected)
        for _, col in pairs(columns) do assert((core.get(col, uid) ~= nil) == expected, col) end
        for _, cache in ipairs({shared.HERO_MGR.user_hero_tbl, shared.ITEM_MGR.all_item_tbl,
            shared.ITEM_MGR.all_item_uid_tbl, shared.ITEM_MGR.all_item_kind_tbl,
            shared.BUILD_MGR.all_user_build_tbl, shared.TROOP_MGR.all_user_troop_tbl}) do
            assert((cache[uid] ~= nil) == expected)
        end
    end
    if with_agent then
        shared.ID_TO_PTONAME, shared.ID_TO_PACK_NAME = {[7] = "c2s_test"}, {[7] = "Test"}
        shared.for_maker.c2s_test = function() end
        local env = setmetatable({}, {__index = shared})
        assert(loadfile("logic/service/agent/agent.lua", "t", env))()
        state.CMD = upvalue(state.dispatchers.lua, "CMD")
        state.RPC = upvalue(state.dispatchers.rpc, "RPC_CMD")
        state.queues = upvalue(upvalue(state.CMD.disconnect, "get_user_queue"), "user_queues")
        U.is_new_user = function() return false end
        U.try_init_user = function(uid)
            if state.pause_login then coroutine.yield("login_load") end
            return U.get_user_by_id(uid) or state.add_user(uid, 99)
        end
        U.module_on_user_login = function() end
        U.dispatch_cross = function() end
        function state.client(fd, uid) return state.dispatchers.client(0, 0, fd, string.pack(">I2I2", 2, 7), uid) end
    end
    return state
end

local function resume(co, expected, ...)
    local ok, why = coroutine.resume(co, ...)
    assert(ok, why)
    if expected then assert(why == expected, tostring(why) .. " != " .. expected) end
    return why
end

function T.failed_ack_keeps_all_documents_and_secondary_indexes_for_retry()
    local s = fixture()
    local user = s.add_user(1, 9)
    s.fail_save = true
    assert(not pcall(s.U.disconnect, 9, 1))
    assert(s.U.get_user_by_id(1) == user and s.emitted == 0 and s.dispatched == 0)
    s.assert_bound(1, true)
    s.core.get("hero", 1).value = 999
    s.fail_save = false
    assert(s.U.disconnect(9, 1))
    s.assert_bound(1, false)
    assert(s.emitted == 1 and s.dispatched == 1)
    assert(s.snapshot_flushes == 2 and not s.drain_flushes)
    local found
    for _, doc in ipairs(s.saved) do if doc.col == "hero" then found = doc.dat.value end end
    assert(found == 999, "retry must save retained live objects")
    assert(s.U.disconnect(9, 1) == false and s.flushes == 2)
end

function T.cache_release_happens_only_after_ack_and_before_notification_yields()
    local s = fixture()
    s.add_user(1, 9); s.pause_save, s.pause_emit = true, true
    local co = coroutine.create(function() return s.U.disconnect(9, 1) end)
    resume(co, "db_ack"); s.assert_bound(1, true)
    assert(s.dispatched == 0 and s.emitted == 0)
    resume(co, "notification"); s.assert_bound(1, false)
    assert(not s.U.get_user_by_id(1) and s.dispatched == 1)
    resume(co)
    assert(coroutine.status(co) == "dead")
end

function T.suspended_save_cannot_release_replaced_session_objects()
    local s = fixture()
    s.add_user(1, 9); s.pause_save = true
    local co = coroutine.create(function() return s.U.disconnect(9, 1) end)
    resume(co, "db_ack")
    local replacement = s.add_user(1, 10)
    assert(resume(co) == false)
    assert(s.U.get_user_by_id(1) == replacement and s.U.get_fd_by_user_id(1) == 10)
    s.assert_bound(1, true)
    assert(s.emitted == 0 and s.dispatched == 0)
    assert(s.U.disconnect(9, 1) == false and s.flushes == 1)
end

function T.disconnect_waiters_and_new_requests_keep_one_queue()
    local s = fixture(true)
    s.add_user(1, 9); s.pause_save = true
    local out = coroutine.create(function() s.CMD.disconnect(9, 1) end)
    local first = coroutine.create(function() s.CMD.login(88, 10, 1, "", "", 1, "") end)
    local second = coroutine.create(function() s.CMD.login(88, 11, 1, "", "", 1, "") end)
    resume(out, "db_ack"); resume(first, "queue")
    s.pause_save = false; resume(out)
    assert(count(s.queues) == 1, "a waiting login still owns the queue")
    resume(second, "queue")
    s.pause_login = true; resume(first, "login_load")
    assert(count(s.queues) == 1)
    s.pause_login = false; resume(first); resume(second)
    assert(s.U.get_fd_by_user_id(1) == 11 and count(s.queues) == 0)
    s.CMD.disconnect(9, 1)
    assert(s.U.get_fd_by_user_id(1) == 11 and s.flushes == 1)
end

function T.heartbeat_kick_waits_for_inflight_client_work()
    local s = fixture(true)
    s.add_user(1, 9)
    s.shared.for_maker.c2s_test = function() coroutine.yield("client_work") end
    local client = coroutine.create(function() s.client(9, 1) end)
    resume(client, "client_work")
    s.U.kick_user(9, 1, true)
    assert(s.sent[1][1] == 77 and s.sent[1][3] == "kick_user")
    local kick = coroutine.create(function() s.CMD.kick_user(9, 1, true) end)
    resume(kick, "queue")
    assert(s.flushes == 0); s.assert_bound(1, true)
    resume(client); resume(kick)
    assert(s.flushes == 1 and s.emitted == 1 and not s.U.get_user_by_id(1))
    assert(count(s.queues) == 0)
end

function T.delayed_old_heartbeat_cannot_kick_a_new_connection()
    local s = fixture(true)
    local user = s.add_user(1, 10)
    s.U.fd_to_user_id[9] = nil
    s.CMD.kick_user(9, 1, true)
    assert(s.U.get_user_by_id(1) == user and s.U.get_fd_by_user_id(1) == 10)
    assert(s.flushes == 0 and #s.sent == 0)
end

function T.rpc_confirmation_blocks_competing_cost_and_rechecks_balance()
    local s = fixture(true)
    s.add_user(1, 9)
    local balance = 1
    s.shared.ITEM_MGR.check_cost_enough = function() return balance >= 1 end
    s.shared.ITEM_MGR.del_cost_list = function()
        if balance < 1 then return false end
        balance = balance - 1; return true
    end
    local rpc = coroutine.create(function() s.RPC.sub_item_list(1, 1, 88, {}, {}) end)
    local cost_result
    local cost = coroutine.create(function() cost_result = s.CMD.cost_items(1, {}, {}) end)
    resume(rpc, "confirmation"); resume(cost, "queue")
    resume(rpc, nil, true); resume(cost)
    assert(balance == 0 and cost_result == false and count(s.queues) == 0)
end

function T.stale_rpc_confirmation_cannot_charge_a_replacement_session()
    local s = fixture(true)
    s.add_user(1, 9)
    local charged = 0
    s.shared.ITEM_MGR.check_cost_enough = function() return true end
    s.shared.ITEM_MGR.del_cost_list = function() charged = charged + 1; return true end
    local rpc = coroutine.create(function() s.RPC.sub_item_list(1, 1, 88, {}, {}) end)
    resume(rpc, "confirmation")
    s.add_user(1, 10)
    resume(rpc, nil, true)
    assert(charged == 0 and count(s.queues) == 0)
end

function T.queue_is_released_on_handler_error()
    local s = fixture(true)
    s.add_user(1, 9)
    s.shared.for_maker.c2s_test = function() error("handler failed") end
    s.client(9, 1)
    assert(count(s.queues) == 0)
    s.shared.for_maker.c2s_test = function() end
    s.client(9, 1)
    assert(count(s.queues) == 0)
end

function T.churn_reclaims_all_cached_objects_and_orm_bindings()
    local s = fixture(true)
    collectgarbage("collect")
    local before = collectgarbage("count")
    local peak, users = 0, 1000
    for wave = 0, 19 do
        for n = 1, 50 do s.add_user(wave * 50 + n, wave * 50 + n + 1000, 16) end
        peak = math.max(peak, count(s.weak))
        for n = 1, 50 do
            local uid = wave * 50 + n
            s.CMD.disconnect(uid + 1000, uid)
            s.assert_bound(uid, false)
        end
        s.saved = nil
        collectgarbage("collect")
        assert(count(s.weak) == 0, "disconnected ORM objects/heroes/items must be collectible")
        assert(count(s.queues) == 0 and not next(s.U.all_user_tbl))
    end
    collectgarbage("collect")
    local after = collectgarbage("count")
    assert(s.flushes == users and s.emitted == users)
    print(string.format("lifecycle churn: users=%d peak_objects=%d retained_objects=%d queues=%d heap_delta_kib=%.1f",
        users, peak, count(s.weak), count(s.queues), after - before))
end

function T.performance_stats_are_optional_counts_and_include_waiters()
    local s = fixture(true)
    s.add_user(1, 9)
    assert(s.CMD.performance_stats().enabled == false)
    s.metrics, s.pause_save = true, true
    local out = coroutine.create(function() s.CMD.disconnect(9, 1) end)
    local waiter = coroutine.create(function() s.CMD.disconnect(9, 1) end)
    resume(out, "db_ack"); resume(waiter, "queue")
    local stats = s.CMD.performance_stats()
    assert(stats.users == 1 and stats.hero_users == 1 and stats.item_users == 1)
    assert(stats.item_uid_users == 1 and stats.item_kind_users == 1)
    assert(stats.player_queues == 1 and stats.player_queue_calls == 2)
    s.pause_save = false; resume(out); resume(waiter)
    stats = s.CMD.performance_stats()
    for key, value in pairs(stats) do if key ~= "enabled" then assert(value == 0, key) end end
end


function T.login_waiting_before_shutdown_is_rejected_when_it_gets_the_queue()
    local s = fixture(true)
    s.add_user(1, 9)
    s.shared.for_maker.c2s_test = function() coroutine.yield("client_work") end
    local client = coroutine.create(function() s.client(9, 1) end)
    local login = coroutine.create(function() s.CMD.login(88, 10, 1, "", "", 1, "") end)
    local shutdown = coroutine.create(function() s.CMD.shutdown() end)
    resume(client, "client_work"); resume(login, "queue"); resume(shutdown, "queue")
    resume(client)
    local ok, err = coroutine.resume(login)
    assert(not ok and tostring(err):find("server is closing", 1, true))
    resume(shutdown)
    assert(s.exited and not s.U.get_user_by_id(1) and count(s.queues) == 0)
end


local function offline_arrivals(s)
    s.shared.DATA_COMMON = {TARGET_TYPE = {MOVE = 4, ATTACK_CITY = 5, REDEPLOY = 6,
        ATTACK_MONSTER = 1, OCCUPY_RES_LAND = 2}}
    s.U.try_init_user = function(uid) return s.U.get_user_by_id(uid) or s.add_user(uid, nil, 4) end
    s.shared.TROOP_MGR.get_troop = function(uid)
        local doc = s.core.get("troop", uid)
        return {_data = {_siege_city = 0},
            get_march_state = function() return s.shared.CONST.MARCH_STATE.MOVING end,
            get_end_time = function() return 10 end,
            get_target_type = function() return 4 end,
            set_arrived = function() doc.value = doc.value + 100; s.arrived = (s.arrived or 0) + 1 end}
    end
    local march = setmetatable({}, {__index = s.shared})
    assert(loadfile("logic/service/agent/module/march/mgr.lua", "t", march))()
    s.shared.MARCH_MGR = march
end

function T.offline_real_arrival_persists_then_releases_without_logout_events()
    local s = fixture(true); offline_arrivals(s)
    s.pause_save = true
    local job = coroutine.create(function() s.CMD.march_arrive(1, 1, 10) end)
    resume(job, "db_ack")
    s.assert_bound(1, true)
    assert(s.U.get_fd_by_user_id(1) == nil and s.arrived == 1)
    resume(job)
    s.assert_bound(1, false)
    assert(s.emitted == 0 and s.dispatched == 0 and s.flushes == 1)
    local user_value, troop_value
    for _, row in ipairs(s.saved) do
        if row.col == "user" then user_value = row.dat.value end
        if row.col == "troop" then troop_value = row.dat.value end
    end
    assert(user_value == 1 and troop_value == 101, "offline cleanup must not settle a second logout")
    assert(#s.sent == 0 and count(s.queues) == 0, "cleanup must not hide world entities")
end

function T.offline_cleanup_failure_retains_objects_and_retries_after_one_second()
    local s = fixture(true); offline_arrivals(s)
    s.fail_save = true
    s.CMD.march_arrive(1, 1, 10)
    s.assert_bound(1, true)
    assert(#s.timers == 1 and s.timers[1].delay == 100 and s.flushes == 1)
    s.fail_save = false
    s.timers[1].fn()
    s.assert_bound(1, false)
    assert(s.flushes == 2 and s.arrived == 1 and s.emitted == 0 and s.dispatched == 0)
end

function T.relogin_waits_for_offline_ack_and_retry_cannot_release_new_session()
    local s = fixture(true); offline_arrivals(s)
    s.pause_save = true
    local job = coroutine.create(function() s.CMD.march_arrive(1, 1, 10) end)
    local login = coroutine.create(function() s.CMD.login(88, 10, 1, "", "", 1, "") end)
    resume(job, "db_ack"); resume(login, "queue")
    s.fail_save = true; resume(job)
    local retained = s.U.get_user_by_id(1)
    s.pause_save, s.fail_save = false, false
    resume(login)
    assert(s.U.get_user_by_id(1) == retained and s.U.get_fd_by_user_id(1) == 10)
    s.timers[1].fn()
    s.assert_bound(1, true)
    assert(s.flushes == 1 and count(s.queues) == 0)
end

function T.nested_offline_job_releases_only_after_outer_callback_returns()
    local s = fixture(true); offline_arrivals(s)
    s.shared.MARCH_MGR.on_occupy_done = function(uid) s.core.get("troop", uid).value = 777 end
    local original = s.shared.MARCH_MGR.on_arrive
    s.shared.MARCH_MGR.on_arrive = function(uid, ...)
        original(uid, ...)
        s.CMD.occupy_done(uid, 1, 10)
        s.assert_bound(uid, true)
        assert(s.flushes == 0)
    end
    s.CMD.march_arrive(1, 1, 10)
    s.assert_bound(1, false)
    assert(s.flushes == 1 and count(s.queues) == 0)
end

function T.shutdown_waits_for_started_cold_login_before_final_logout()
    local s = fixture(true)
    s.pause_login = true
    local login = coroutine.create(function() s.CMD.login(88, 10, 1, "", "", 1, "") end)
    local shutdown = coroutine.create(function() s.CMD.shutdown() end)
    resume(login, "login_load")
    assert(not next(s.U.user_id_to_fd))
    resume(shutdown, "queue")
    assert(not s.exited and s.flushes == 0)
    assert(not pcall(s.CMD.march_arrive, 2, 1, 10), "closing must reject new offline work")
    s.pause_login = false; resume(login); resume(shutdown)
    s.assert_bound(1, false)
    assert(s.exited and s.emitted == 1 and count(s.queues) == 0)
    assert(s.snapshot_flushes == 1 and s.drain_flushes == 1, "shutdown must retain its final drain-all barrier")
end

function T.offline_arrival_churn_reclaims_loaded_users_and_troops()
    local s = fixture(true); offline_arrivals(s)
    for uid = 1, 1000 do
        s.CMD.march_arrive(uid, 1, 10)
        s.assert_bound(uid, false)
    end
    s.saved = nil
    collectgarbage("collect")
    assert(count(s.weak) == 0 and not next(s.U.all_user_tbl) and count(s.queues) == 0)
    assert(s.arrived == 1000 and s.emitted == 0 and s.dispatched == 0)
    print("offline arrivals: jobs=1000 retained_users=0 retained_objects=0 queues=0 logout_events=0")
end


local function accepted_battle_continuation(s)
    s.U.try_init_user = function(uid) return s.U.get_user_by_id(uid) or s.add_user(uid, nil) end
    s.shared.BATTLE_MGR = {on_encounter = function(uid)
        s.U.try_init_user(uid)
        return function()
            s.U.try_init_user(uid)
            s.continuation_runs = (s.continuation_runs or 0) + 1
            s.core.get("troop", uid).value = 777
        end
    end}
end

function T.shutdown_consumes_continuation_registered_before_offline_ack()
    local s = fixture(true); accepted_battle_continuation(s)
    s.metrics, s.pause_save = true, true
    local battle = coroutine.create(function() s.CMD.encounter_result(1, 1, {}) end)
    local shutdown = coroutine.create(function() s.CMD.shutdown() end)
    resume(battle, "db_ack")
    assert(s.CMD.performance_stats().pending_continuations == 1 and #s.timers == 1)
    resume(shutdown, "queue")
    s.pause_save = false; resume(battle); resume(shutdown)
    assert(s.exited and s.continuation_runs == 1 and s.CMD.performance_stats().pending_continuations == 0)
    s.assert_bound(1, false)
    s.timers[1].fn()
    assert(s.continuation_runs == 1 and s.emitted == 0 and count(s.queues) == 0)
end

function T.shutdown_waits_for_timer_claimed_continuation_without_replaying_it()
    local s = fixture(true); accepted_battle_continuation(s)
    s.pause_save = true
    local battle = coroutine.create(function() s.CMD.encounter_result(1, 1, {}) end)
    resume(battle, "db_ack")
    local callback = coroutine.create(s.timers[1].fn)
    local shutdown = coroutine.create(function() s.CMD.shutdown() end)
    resume(callback, "queue"); resume(shutdown, "queue")
    s.pause_save = false; resume(battle); resume(callback); resume(shutdown)
    assert(s.continuation_runs == 1 and s.exited and count(s.queues) == 0)
    s.assert_bound(1, false)
end

function T.shutdown_runs_accepted_zero_tick_followup_before_timer_fires()
    local s = fixture(true); accepted_battle_continuation(s)
    s.CMD.encounter_result(1, 1, {})
    assert(not s.continuation_runs and #s.timers == 1 and count(s.queues) == 0)
    s.CMD.shutdown()
    assert(s.continuation_runs == 1 and s.exited)
    s.timers[1].fn()
    assert(s.continuation_runs == 1 and count(s.queues) == 0)
end

return T
