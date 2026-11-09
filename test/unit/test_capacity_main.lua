-- Execute the real aggregator without sockets or filesystem writes.
local function worker(index, rejected)
    local state = {login={}, elapsed={}, req={c2s_march={}}, rejects={}, reject_reasons={}, march_rejects={}, errors={},
        requests=1000, successful=1000-rejected, expected=1000, attempted=1000, missed=0,
        draws=0, draw_requests=0, draw_final={}, hero_initial={}, hero_final={}, hero_ids={}, hero_added=0, hero_verified=0,
        route_queries=1, route_rejected=0, validation_failed=0, setup_failed=0, runtime_failed=0, timeouts=0, finished=1}
    for i = 1, 1000 do state.req.c2s_march[i], state.elapsed[i] = 0, 0 end
    if rejected > 0 then
        state.rejects.c2s_march = rejected
        state.reject_reasons.c2s_march = {busy=rejected-1, depleted=1}
        for i = 1, math.min(rejected,20) do
            state.march_rejects[i] = {at=i*10+index, idx=index, uid=100+index,
                target_type=4, x=520, y=500, returning=false, msg="busy"}
        end
    end
    return state
end

local function aggregate(states)
    local result, logs, aborted, created = nil, {}, false, 0
    local settings = {BENCH_USERS="2", BENCH_WORKERS="2", BENCH_DURATION="500", BENCH_RESULT="unused.json"}
    local skynet = {
        start=function(fn) fn() end, abort=function() aborted=true end,
        newservice=function() created=created+1; return created end,
        now=function() return 0 end, hpc=function() return 0 end,
        sleep=function() error("unexpected wait") end,
        call=function(id, _, command)
            if command == "progress" then return {done=1, ready=1, validation_done=1, validated=1, running=0} end
            if command == "results" then return states[id] end
        end,
    }
    local env = setmetatable({
        require=function(name)
            if name == "skynet" then return skynet end
            if name == "skynet.manager" then return true end
            if name == "capacity_json" then return {encode=function(value) result=value; return "captured" end} end
            return require(name)
        end,
        os={getenv=function(name) return settings[name] end, time=function() return 0 end},
        io={open=function() return {write=function() end, close=function() end} end},
        print=function(value) logs[#logs+1]=value end,
    }, {__index=_G})
    assert(loadfile("test/bench/capacity_main.lua", "t", env))()
    assert(aborted and result, table.concat(logs, "\n"))
    return result, logs
end

local T = {}
function T.business_rejection_fails_even_when_latency_and_success_rate_pass()
    local healthy = aggregate({worker(1,0),worker(2,0)})
    assert(healthy.pass)
    local result = aggregate({worker(1,1),worker(2,0)})
    assert(result.all_ready and result.finished == 2 and result.missed == 0)
    assert(result.successful == 1999 and result.requests == 2000)
    assert(result.rps >= result.offered_rps * .95 and result.scheduled_latency.p99 == 0)
    assert(not result.pass and result.rejects.c2s_march == 1)
    assert(result.reject_reasons.c2s_march.depleted == 1)
end
function T.reason_counts_merge_without_truncation_and_logs_cap_globally_at_twenty()
    local result, logs = aggregate({worker(1,40),worker(2,40)})
    assert(not result.pass and result.rejects.c2s_march == 80)
    assert(result.reject_reasons.c2s_march.busy == 78 and result.reject_reasons.c2s_march.depleted == 2)
    assert(#result.march_rejects == 20)
    assert(result.march_rejects[1].idx == 1 and result.march_rejects[2].idx == 2)
    assert(result.march_rejects[20].at == 102)
    local samples = 0
    for _, line in ipairs(logs) do
        if line:find("CAPACITY_MARCH_REJECT",1,true) then
            samples=samples+1
            assert(line:find("uid=",1,true) and line:find("targetType=4",1,true)
                and line:find("target=(520,500)",1,true) and line:find("returning=false",1,true)
                and line:find('msg="busy"',1,true))
        end
    end
    assert(samples == 20, "the cap is per run, not per worker")
end
return T
