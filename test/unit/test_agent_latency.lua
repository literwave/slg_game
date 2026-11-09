local T = {}
local function run(wait_ticks, work_ticks, fail, stale)
    local now, logs, dispatch, called = 0, {}, {}, 0
    local skynet = {
        PTYPE_CLIENT = 1, PTYPE_RPC = 2,
        register_protocol = function() end,
        now = function() return now end,
        start = function(fn) fn() end,
        dispatch = function(kind, fn) dispatch[kind] = fn end,
        error = function(message) logs[#logs + 1] = message end,
    }
    local env = setmetatable({
        dofile = function() end,
        require = function(name)
            if name == "skynet" then return skynet end
            if name == "protobuf" then return {decode = function() return {private_field = "secret"} end} end
            if name == "skynet.queue" then return function()
                return function(fn, ...) now = now + wait_ticks; return fn(...) end
            end end
            error(name)
        end,
        ID_TO_PTONAME = {[7] = "c2s_user_lottery"},
        ID_TO_PACK_NAME = {[7] = "Lottery.c2s_user_lottery"},
        USER_MGR = {get_fd_by_user_id = function() return stale and 88 or 99 end},
        LOG = {_error = function() end},
        for_maker = {c2s_user_lottery = function()
            called = called + 1
            now = now + work_ticks
            if fail then error("test failure") end
        end},
    }, {__index = _G})
    assert(loadfile("logic/service/agent/agent.lua", "t", env))()
    dispatch.client(0, 0, 99, string.pack(">I2I2", 2, 7), 123)
    return logs, called
end

function T.slow_request_separates_queue_and_handler_without_payload()
    local logs, called = run(7, 8)
    assert(called == 1 and #logs == 1)
    assert(logs[1]:find("queue_ms=70", 1, true))
    assert(logs[1]:find("handler_ms=80", 1, true))
    assert(logs[1]:find("protocol=c2s_user_lottery", 1, true))
    assert(not logs[1]:find("secret", 1, true))
end

function T.fast_requests_and_stale_sessions_do_not_log_slow_requests()
    local logs, called = run(1, 2)
    assert(called == 1 and #logs == 0)
    logs, called = run(20, 20, false, true)
    assert(called == 0 and #logs == 0)
end

function T.failed_handler_keeps_error_reporting_and_timing()
    local logs, called = run(0, 12, true)
    assert(called == 1 and #logs == 3)
    assert(logs[3]:find("handler_ms=120", 1, true))
    assert(logs[3]:find("ok=false", 1, true))
end
return T
