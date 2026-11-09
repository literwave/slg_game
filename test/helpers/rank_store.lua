-- Offline fixture: real rank manager, Mongo producer, batch compactor and
-- skynet.queue; only RPC transport/storage and clock are controlled by tests.
local M = {}
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

function M.setup(rows)
    local state = {rows = copy(rows or {}), calls = {}, timers = {}, wakeups = {}, now = 1000}
    local skynet = {
        timeout = function(delay, run) state.timers[#state.timers + 1] = {delay = delay, run = run} end,
        error = function() end,
        wait = function() return coroutine.yield("queue") end,
        wakeup = function(co) state.wakeups[#state.wakeups + 1] = co end,
        call = function(_, _, command, args)
            assert(args.collection == nil or args.collection == "rank_entry_col", "old SERVER/1 must not be read")
            if command == "find_all" then
                local found = {}
                for key, dat in pairs(state.rows) do found[#found + 1] = {_id = key, dat = copy(dat)} end
                return found
            end
            assert(command == "save_data")
            -- IPC takes a snapshot before yielding; emulate the same boundary.
            args = copy(args)
            state.calls[#state.calls + 1] = args
            if state.on_save then state.on_save(args, #state.calls) end
            for col, commands in pairs(args) do
                assert(col == "rank_entry_col", "rank writes must be independent documents")
                for _, cmd in ipairs(commands) do
                    if cmd.op_type == "del_doc" then state.rows[cmd.key] = nil
                    else
                        assert(cmd.op_type == "$set" and cmd.field_str == "dat")
                        state.rows[cmd.key] = copy(cmd.value)
                    end
                end
            end
            return true
        end,
    }
    local qenv = setmetatable({require = function() return skynet end}, {__index = _G})
    local queue = assert(loadfile("skynet/lualib/skynet/queue.lua", "t", qenv))()
    local orm = assert(loadfile("lualib/orm/init.lua"))()
    local mongo = setmetatable({
        require = function(name)
            if name == "skynet" then return skynet end
            if name == "skynet.queue" then return queue end
            if name == "orm" then return orm end
            return require(name)
        end,
        GAME = {get_data_base = function() return "offline_rank_test" end},
        CALL_OUT = {call_fre = function() return 1 end},
    }, {__index = _G})
    assert(loadfile("logic/base/mongo_slave.lua", "t", mongo))()
    local env = setmetatable({
        DATA_COMMON = {RANK_TYPE = dofile("game_common/server/enum/RankTypeEnum.lua"),
            get_rank_max = function(kind) return kind == 4 and 50 or 100 end},
        TIME = {os_bj_sec = function() return state.now end},
        MONGO_SLAVE = mongo,
    }, {__index = _G})
    assert(loadfile("logic/service/activity/module/rank/mgr.lua", "t", env))()
    env.__init__()
    state.mongo = mongo
    return env, state
end

return M
