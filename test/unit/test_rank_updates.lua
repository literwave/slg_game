local FILE = "logic/service/agent/module/activity/mgr.lua"
local T = {}

local function setup()
    local env = setmetatable({}, {__index = _G})
    local state = {timers = {}, sent = {}, calls = {}, order = {}, available = true, fail_send = false,
        ranks = {}, power_reads = 0, loaded = true, hero_loaded = true, build_loaded = true, cache_loads = 0, listeners = {}}
    local user = {power = 100, city = 5, name = "before", head = 7, _data = {_kill_count = 3}}
    function user:get_user_id() return 1 end
    function user:get_name() return self.name end
    function user:get_head_icon() return self.head end
    function user:get_power()
        state.power_reads = state.power_reads + 1
        if not state.hero_loaded then state.cache_loads = state.cache_loads + 1; state.hero_loaded = true end
        return self.power
    end
    function user:get_city_level()
        if not state.build_loaded then state.cache_loads = state.cache_loads + 1; state.build_loaded = true end
        return self.city
    end
    function user:get_level() return 5 end
    state.user = user
    env.USER_MGR = {
        get_user_by_id = function() return state.loaded and state.user or nil end,
        get_user_id_by_fd = function() return 1 end,
        get_user_by_fd = function() return state.loaded and state.user or nil end,
        try_init_user = function() error("rank callback must not reload a user") end,
    }
    env.CONST = {BUILD_TYPE = {MAIN_HALL = 1}, RANK_PAGE_MAX = 50, RANK_PAGE_DEFAULT = 20,
        EVENT = {ON_USER_LOGIN = "on_user_login", ON_USER_LOGOUT = "on_user_logout", ON_HERO_ADD = "on_hero_add",
            ON_BUILD_LEVEL = "on_build_level", ON_HEAD_ICON = "on_head_icon", ON_HERO_LEVEL = "on_hero_level",
            ON_CALC_ITEM_REWARD = "on_calc_item_reward", ON_CALC_LOTTERY_COST = "on_calc_lottery_cost"}}
    env.DATA_COMMON = {RANK_TYPE = {POWER = 1, CITY_LEVEL = 2, KILL = 3, ALLIANCE_POWER = 4},
        get_rank_type_conf = function(kind) return kind == 1 and {} or nil end}
    env.MONGO_SLAVE = {COL = {USER_HERO = "hero", USER_BUILD = "build", USER_INFO = "user"}}
    env.ORM = {get = function(col)
        if col == "hero" then return state.hero_loaded or nil end
        if col == "build" then return state.build_loaded or nil end
    end}
    env.EVENT = {listen = function(event) state.listeners[event] = true end}
    env.LOG = {_warn = function() state.warned = (state.warned or 0) + 1 end}
    env.for_maker = {}
    env.for_caller = {s2c_req_rank_list = function(_, value) state.response = value end}
    local skynet = {
        localname = function() return state.available and 17 or nil end,
        timeout = function(delay, fn) state.timers[#state.timers + 1] = {delay = delay, run = fn} end,
        send = function(addr, protocol, cmd, kind, uid, score, name, head)
            assert(addr == 17 and protocol == "lua" and cmd == "set_score")
            if state.fail_send == "throw" then error("service restarting") end
            if state.fail_send then return nil end
            local value = {kind = kind, uid = uid, score = score, name = name, head = head}
            state.sent[#state.sent + 1] = value
            state.order[#state.order + 1] = "send"
            state.ranks[kind] = value
            return 0 -- real skynet.send succeeds with session 0
        end,
        call = function(_, _, cmd, kind)
            assert(cmd ~= "set_score", "derived score updates must not wait for RPC acknowledgements")
            state.calls[#state.calls + 1] = cmd
            state.order[#state.order + 1] = "call"
            local value = state.ranks[kind]
            return {list = {}, self = {rank = 1, uid = 1, name = value and value.name or "", head_icon = 7,
                score = value and value.score or 0}}
        end,
    }
    env.skynet = skynet
    env.require = function(name) if name == "skynet" then return skynet end; return require(name) end
    assert(loadfile(FILE, "t", env))()
    env.__init__()
    function state.tick()
        local timer = table.remove(state.timers, 1)
        assert(timer, "missing deferred flush")
        timer.run()
        return timer.delay
    end
    return env, state
end

function T.ten_new_hero_events_coalesce_without_blocking_the_request()
    local M, s = setup()
    for i = 1, 10 do s.user.power = i * 100; M.on_hero_add(1) end
    assert(#s.calls == 0 and #s.sent == 0 and s.power_reads == 0)
    assert(#s.timers == 1 and s.timers[1].delay == 0)
    s.tick()
    assert(s.power_reads == 1 and #s.sent == 1)
    assert(s.sent[1].kind == 1 and s.sent[1].score == 1000)
    assert(next(M.rank_pending) == nil and #s.timers == 0)
end

function T.immediate_query_sends_new_score_before_its_read()
    local M, s = setup()
    s.user.power = 222
    M.on_hero_add(1)
    M.for_maker.c2s_req_rank_list(9, {rankType = 1})
    assert(s.order[1] == "send" and s.order[2] == "call")
    assert(s.response.selfRank.score == 222 and #s.calls == 1)
    s.tick()
    assert(#s.sent == 1, "the old scheduled callback must not duplicate a flushed score")
end

function T.logout_keeps_the_latest_snapshot_until_service_recovers()
    local M, s = setup()
    s.available = false
    s.user.power = 333
    M.on_hero_add(1)
    M.on_user_logout(1)
    assert(s.power_reads == 1)
    s.loaded = false
    s.tick()
    assert(#s.timers == 1 and s.timers[1].delay == 100, "retry must be rate limited")
    s.available = true
    s.tick()
    assert(#s.sent == 1 and s.sent[1].score == 333 and s.power_reads == 1)
    assert(next(M.rank_pending) == nil)
end

function T.relogin_supersedes_failed_old_snapshots()
    local M, s = setup()
    s.fail_send = "throw"
    M.on_hero_add(1)
    M.on_user_logout(1)
    assert(#s.sent == 0 and s.warned == 1)
    s.user.power = 888; s.user.name = "after"; s.user.head = 9
    M.on_user_login(1)
    s.fail_send = false
    s.tick()
    assert(#s.sent == 3 and s.ranks[1].score == 888)
    for _, value in ipairs(s.sent) do assert(value.name == "after" and value.head == 9) end
    assert(next(M.rank_pending) == nil)
end

function T.nil_send_result_is_retried_without_losing_score()
    local M, s = setup()
    M.on_hero_add(1)
    s.fail_send = true
    s.tick()
    assert(#s.sent == 0 and next(M.rank_pending) ~= nil)
    s.fail_send = false
    s.tick()
    assert(#s.sent == 1 and s.sent[1].score == 100)
end

function T.failed_snapshot_keeps_its_dirty_flag_for_retry()
    local M, s = setup()
    local get_power = s.user.get_power
    s.user.get_power = function() error("temporary data error") end
    M.on_hero_add(1)
    s.tick()
    assert(#s.sent == 0 and M.rank_pending[1].dirty[1])
    s.user.get_power = get_power
    s.tick()
    assert(#s.sent == 1 and s.sent[1].score == 100)
end

function T.each_event_updates_only_its_affected_board()
    local M, s = setup()
    M.on_hero_level(1); M.on_hero_add(1)
    M.on_build_level(1, 2)
    s.tick()
    assert(#s.sent == 1 and s.sent[1].kind == 1)
    M.on_build_level(1, 1)
    s.tick()
    assert(#s.sent == 2 and s.sent[2].kind == 2)
    M.add_kills(s.user, 10)
    s.tick()
    assert(#s.sent == 3 and s.sent[3].kind == 3 and s.sent[3].score == 13)
    M.on_head_icon(1)
    s.tick()
    assert(#s.sent == 6, "profile changes still refresh all three boards")
end

function T.real_lottery_and_rewards_reply_before_deferred_rank_work()
    local M, s = setup()
    local owned, next_hero = {}, 0
    M.EMPTY_TABLE = {}
    M.CONST.REWARD_TYPE_ITEM = 1; M.CONST.REWARD_TYPE_RES = 2; M.CONST.REWARD_TYPE_HERO = 3; M.CONST.REWARD_TYPE_SOLDIER = 4
    M.CONST.COST_TYPE = {ITEM = 3}; M.CONST.FLOW_REASON = {LOTTERY = 4}; M.CONST.EVENT.ON_LOTTERY = "on_lottery"
    s.user.times = 0
    function s.user:get_lottery_times() return self.times end
    function s.user:set_lottery_times(n) self.times = n end
    M.GLOBAL_FUNC = {gen_reward_info = function(kind, id, count) return {reward_type = kind, item_id = id, item_count = count} end}
    M.DATA_COMMON.get_lottery_conf = function() return {CostList = {{item_id = 103, count = 10}}, CommonPools = {},
        HeroPools = {{reward_type = 3, item_id = 1001, item_count = 1, weight = 1}}} end
    M.DATA_COMMON.get_hero_info_by_type = function() return {Convert = {}} end
    M.ITEM_MGR = {check_cost_enough = function() return true end, del_cost_list = function() return true end}
    M.HERO_MGR = {get_hero_by_type = function(_, id) return owned[id] end,
        add_hero = function(_, id) owned[id] = true; s.user.power = s.user.power + 100; M.on_hero_add(1) end}
    M.EVENT.dispatch = function() end
    M.rand_item_by_weight = function()
        next_hero = next_hero + 1
        return {reward_type = 3, item_id = 1000 + next_hero, item_count = 1}
    end
    M.table = setmetatable({deepcopy = function(value)
        local result = {}; for k,v in pairs(value) do result[k] = v end; return result
    end}, {__index = table})
    assert(loadfile("logic/service/agent/module/reward/mgr.lua", "t", M))()
    M.REWARD_MGR = {reward_user = M.reward_user}
    M.for_caller.s2c_user_lottery = function(_, value) s.draw_result = value end
    assert(loadfile("logic/service/agent/module/lottery/lottery.lua", "t", M))()
    M.__init__()
    M.for_maker.c2s_user_lottery(9, {useLotteryTimes = 10})
    assert(s.draw_result and #s.draw_result.rewardList == 10 and s.user.times == 10)
    assert(#s.calls == 0 and #s.sent == 0 and s.power_reads == 0, "lottery reply precedes rank work")
    s.tick()
    assert(#s.sent == 1 and s.sent[1].score == 1100 and s.power_reads == 1)
end


function T.cold_login_initializes_caches_before_deferred_rank_work()
    local M, s = setup()
    s.hero_loaded, s.build_loaded = false, false
    M.on_user_login(1)
    assert(s.cache_loads == 2 and s.hero_loaded and s.build_loaded)
    assert(#s.sent == 0 and #s.calls == 0)
    s.tick()
    assert(#s.sent == 3 and next(M.rank_pending) == nil and #s.timers == 0)
end

function T.background_rank_work_never_initializes_missing_caches()
    local M, s = setup()
    s.hero_loaded, s.build_loaded = false, false
    M.on_head_icon(1)
    s.tick()
    assert(s.cache_loads == 0 and s.power_reads == 0)
    assert(#s.sent == 1 and s.sent[1].kind == 3)
    assert(M.rank_pending[1].dirty[1] and M.rank_pending[1].dirty[2])
    s.hero_loaded, s.build_loaded = true, true
    s.tick()
    assert(#s.sent == 3 and next(M.rank_pending) == nil)
end

function T.real_disconnect_snapshots_before_build_logout_unbinds()
    local M, s = setup()
    assert(not s.listeners[M.CONST.EVENT.ON_USER_LOGOUT], "rank cleanup must not depend on unordered events")
    s.available = false
    local build = setmetatable({}, {__index = M})
    assert(loadfile("logic/service/agent/module/build/mgr.lua", "t", build))()
    build.all_user_build_tbl[1] = {}
    M.MONGO_SLAVE.flush = function() return true end
    M.MONGO_SLAVE.flush_snapshot = function() s.saved = true; return true end
    M.ORM.unbind = function(col)
        if col == "build" then s.build_loaded = false end
    end
    local users = setmetatable({ACTIVITY_MGR = M, EVENT = {emit = function() end, dispatch = function(event, uid)
        assert(event == M.CONST.EVENT.ON_USER_LOGOUT and uid == 1)
        assert(M.rank_pending[1].values[2].score == 5, "rank snapshot must precede document cleanup")
        build.on_user_logout(uid)
    end}}, {__index = M})
    assert(loadfile("logic/service/agent/module/user/mgr.lua", "t", users))()
    M.USER_MGR = users
    users.all_user_tbl[1] = s.user
    users.fd_to_user_id[9], users.user_id_to_fd[1] = 1, 9
    function s.user:on_logout() end
    M.on_head_icon(1)
    users.disconnect(9, 1)
    assert(s.saved and not users.get_user_by_id(1) and not s.build_loaded)
    assert(build.all_user_build_tbl[1] == nil and s.cache_loads == 0)
    s.available = true
    s.tick()
    assert(#s.sent == 3 and next(M.rank_pending) == nil and s.cache_loads == 0)
end

function T.metadata_is_read_after_a_yielding_snapshot()
    local M, s = setup()
    local get_power = s.user.get_power
    s.user.get_power = function(self)
        local score = self.power
        coroutine.yield("snapshot")
        return score
    end
    M.on_hero_add(1)
    local co = coroutine.create(s.tick)
    local ok, why = coroutine.resume(co)
    assert(ok and why == "snapshot")
    s.user.name, s.user.head = "new profile", 99
    M.on_head_icon(1)
    s.user.get_power = get_power
    assert(coroutine.resume(co))
    for _ = 1, 3 do if #s.timers > 0 then s.tick() end end
    assert(#s.sent == 3 and next(M.rank_pending) == nil)
    for _, value in ipairs(s.sent) do assert(value.name == "new profile" and value.head == 99) end
end

function T.replaced_user_cannot_publish_an_old_inflight_snapshot()
    local M, s = setup()
    local old_user, get_power = s.user, s.user.get_power
    old_user.get_power = function(self)
        local score = self.power
        coroutine.yield("snapshot")
        return score
    end
    M.on_hero_add(1)
    local co = coroutine.create(s.tick)
    local ok, why = coroutine.resume(co)
    assert(ok and why == "snapshot")
    s.user = setmetatable({power = 777, head = 77, name = "replacement"}, {__index = old_user})
    old_user.get_power = get_power
    assert(coroutine.resume(co))
    assert(#s.sent == 0 and M.rank_pending[1].dirty[1])
    M.on_user_login(1)
    s.tick()
    assert(#s.sent == 3 and s.ranks[1].score == 777 and s.ranks[1].head == 77)
    assert(next(M.rank_pending) == nil)
end

return T
