local skynet = require "skynet"
require "skynet.manager"
local json = require "capacity_json"
local function env(name, default) local value = os.getenv(name); return value and (tonumber(value) or value) or default end
local conf = {users = env("BENCH_USERS", 20), duration = env("BENCH_DURATION", 30), ramp = env("BENCH_RAMP", 10),
    interval_ms = env("BENCH_INTERVAL_MS", 500), timeout_ms = env("BENCH_TIMEOUT_MS", 15000),
    login_addr = env("BENCH_LOGIN_ADDR", "127.0.0.1:39021"), server_id = env("BENCH_SERVER_ID", 901),
    prefix = env("BENCH_PREFIX", "capacity_"), workers = env("BENCH_WORKERS", 8),
    account_model = env("BENCH_ACCOUNT_MODEL", "super"),
    result = assert(os.getenv("BENCH_RESULT")), p99_ms = env("BENCH_MAX_P99_MS", 100)}
local function percentiles(values)
    table.sort(values)
    local sum = 0; for _, value in ipairs(values) do sum = sum + value end
    local function p(q) return values[math.max(1, math.ceil(#values * q))] or 0 end
    return {count = #values, avg = #values > 0 and sum / #values or 0, p50 = p(.5), p95 = p(.95), p99 = p(.99), max = p(1)}
end
local function run()
    assert(conf.login_addr:match("^127%.0%.0%.1:"), "capacity harness is restricted to isolated loopback server")
    assert(conf.account_model == "super" or conf.account_model == "fresh", "unknown capacity account model")
    local workers, lists = {}, {}
    for i = 1, math.min(conf.users, conf.workers) do workers[i] = skynet.newservice("capacity_bot"); lists[i] = {} end
    for i = 1, conf.users do local list = lists[(i - 1) % #workers + 1]; list[#list + 1] = i end
    for i, worker in ipairs(workers) do skynet.call(worker, "lua", "prepare", conf, lists[i]) end
    local started = skynet.now()
    local preparation_limit = started + (conf.ramp + 180) * 100
    local all_prepared, all_ready, routes_validated, measure_started_at = false, false, 0, nil
    while skynet.now() < preparation_limit do
        local done, ready = 0, 0
        for _, worker in ipairs(workers) do local state = skynet.call(worker, "lua", "progress"); done = done + state.done; ready = ready + state.ready end
        print(string.format("CAPACITY_PREP users=%d done=%d ready=%d", conf.users, done, ready))
        if done == conf.users then all_prepared = ready == conf.users; break end
        skynet.sleep(500)
    end
    if all_prepared then
        for _, worker in ipairs(workers) do skynet.call(worker, "lua", "validate_routes") end
        while skynet.now() < preparation_limit do
            local done, ready = 0, 0
            routes_validated = 0
            for _, worker in ipairs(workers) do
                local state = skynet.call(worker, "lua", "progress")
                done, ready = done + state.validation_done, ready + state.ready
                routes_validated = routes_validated + state.validated
            end
            print(string.format("CAPACITY_ROUTES users=%d done=%d validated=%d ready=%d", conf.users, done, routes_validated, ready))
            if done == conf.users or ready ~= conf.users then
                all_ready = routes_validated == conf.users and ready == conf.users
                break
            end
            skynet.sleep(100)
        end
    end
    if all_ready then
        local at = skynet.hpc() / 1e6 + 1000
        measure_started_at = os.time() + 1
        for _, worker in ipairs(workers) do skynet.call(worker, "lua", "begin", at) end
        print(string.format("CAPACITY_MEASURE users=%d seconds=%d interval_ms=%d", conf.users, conf.duration, conf.interval_ms))
    else for _, worker in ipairs(workers) do skynet.call(worker, "lua", "abort") end end
    local end_limit = skynet.now() + (conf.duration + conf.timeout_ms / 1000 + 10) * 100
    while skynet.now() < end_limit do
        local running = 0
        for _, worker in ipairs(workers) do running = running + skynet.call(worker, "lua", "progress").running end
        if running == 0 then break end
        skynet.sleep(100)
    end
    local aggregate = {login = {}, elapsed = {}, req = {}, rejects = {}, reject_reasons = {}, march_rejects = {}, errors = {}, requests = 0,
        successful = 0, expected = 0, attempted = 0, missed = 0,
        draws = 0, draw_requests = 0, draw_final = {},
        hero_initial = {}, hero_final = {}, hero_ids = {}, hero_added = 0, hero_verified = 0,
        route_queries = 0, route_rejected = 0, validation_failed = 0,
        setup_failed = 0, runtime_failed = 0, timeouts = 0, finished = 0}
    for _, worker in ipairs(workers) do
        local state = skynet.call(worker, "lua", "results")
        for _, key in ipairs({"login", "elapsed"}) do for _, value in ipairs(state[key]) do table.insert(aggregate[key], value) end end
        for _, key in ipairs({"requests", "successful", "expected", "attempted", "missed", "draws", "draw_requests", "hero_added", "hero_verified", "route_queries", "route_rejected", "validation_failed", "setup_failed", "runtime_failed", "timeouts", "finished"}) do aggregate[key] = aggregate[key] + state[key] end
        for uid, expected in pairs(state.draw_final) do
            assert(aggregate.draw_final[uid] == nil, "duplicate benchmark account " .. tostring(uid))
            aggregate.draw_final[uid] = expected
        end
        for _, key in ipairs({"hero_initial", "hero_final", "hero_ids"}) do
            for uid, count in pairs(state[key]) do
                assert(aggregate[key][uid] == nil, "duplicate benchmark hero account " .. tostring(uid))
                aggregate[key][uid] = count
            end
        end
        for name, values in pairs(state.req) do aggregate.req[name] = aggregate.req[name] or {}; for _, value in ipairs(values) do table.insert(aggregate.req[name], value) end end
        for _, key in ipairs({"rejects", "errors"}) do for name, value in pairs(state[key]) do aggregate[key][name] = (aggregate[key][name] or 0) + value end end
        for name, reasons in pairs(state.reject_reasons) do
            local combined = aggregate.reject_reasons[name] or {}
            aggregate.reject_reasons[name] = combined
            for reason, count in pairs(reasons) do combined[reason] = (combined[reason] or 0) + count end
        end
        for _, sample in ipairs(state.march_rejects) do table.insert(aggregate.march_rejects, sample) end
    end
    -- The cap applies to the whole run, not independently to every worker.
    table.sort(aggregate.march_rejects, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.idx < b.idx
    end)
    for i = #aggregate.march_rejects, 21, -1 do aggregate.march_rejects[i] = nil end
    for _, sample in ipairs(aggregate.march_rejects) do
        print(string.format("CAPACITY_MARCH_REJECT idx=%d uid=%s targetType=%d target=(%s,%s) returning=%s msg=%q",
            sample.idx, tostring(sample.uid), sample.target_type, tostring(sample.x), tostring(sample.y),
            tostring(sample.returning), sample.msg))
    end
    local result = {config = conf, all_prepared = all_prepared, all_ready = all_ready,
        routes_validated = routes_validated, measure_started_at = measure_started_at, login = percentiles(aggregate.login),
        latency = {}, scheduled_latency = percentiles(aggregate.elapsed), requests = aggregate.requests,
        successful = aggregate.successful, expected = aggregate.expected, attempted = aggregate.attempted,
        draws = aggregate.draws, draw_requests = aggregate.draw_requests, draw_final = aggregate.draw_final,
        hero_initial = aggregate.hero_initial, hero_final = aggregate.hero_final, hero_ids = aggregate.hero_ids,
        hero_added = aggregate.hero_added, hero_verified = aggregate.hero_verified,
        route_queries = aggregate.route_queries, route_rejected = aggregate.route_rejected, validation_failed = aggregate.validation_failed,
        missed = aggregate.missed, setup_failed = aggregate.setup_failed, runtime_failed = aggregate.runtime_failed,
        timeouts = aggregate.timeouts, finished = aggregate.finished, errors = aggregate.errors, rejects = aggregate.rejects,
        reject_reasons = aggregate.reject_reasons, march_rejects = aggregate.march_rejects}
    local all, rejected = {}, 0
    for name, values in pairs(aggregate.req) do result.latency[name] = percentiles(values); for _, value in ipairs(values) do all[#all + 1] = value end end
    for _, value in pairs(result.rejects) do rejected = rejected + value end
    result.latency.all = percentiles(all)
    result.rps = aggregate.successful / conf.duration
    result.response_rps = aggregate.requests / conf.duration
    result.offered_rps = conf.users * 1000 / conf.interval_ms
    result.scheduled_rps = aggregate.expected / conf.duration
    result.pass = all_ready and aggregate.finished == conf.users and aggregate.runtime_failed == 0 and aggregate.timeouts == 0
        and aggregate.missed == 0 and result.scheduled_latency.p99 <= conf.p99_ms
        and rejected == 0 and result.rps >= result.offered_rps * .95
    if conf.account_model == "fresh" then
        result.pass = result.pass and aggregate.hero_verified == conf.users and aggregate.hero_added > 0
    end
    local file = assert(io.open(conf.result, "w")); file:write(json.encode(result), "\n"); file:close()
    print(string.format("CAPACITY_RESULT pass=%s users=%d finished=%d rps=%.1f p99=%.2f scheduled_p99=%.2f rejected=%d missed=%d",
        tostring(result.pass), conf.users, aggregate.finished, result.rps, result.latency.all.p99, result.scheduled_latency.p99, rejected, result.missed))
end
skynet.start(function()
    local ok, err = xpcall(run, debug.traceback)
    if not ok then print("CAPACITY_FATAL " .. tostring(err)) end
    skynet.abort()
end)
