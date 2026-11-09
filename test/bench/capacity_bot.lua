-- Isolated capacity workload: real WebSocket/protobuf, successful writes and movement.
local skynet = require "skynet"
local P = require "bench_proto"
local metrics = require "capacity_metrics"
local CMD, conf, clients, pending, ready = {}, nil, {}, {}, 0
local assigned, plans = {}, {}
local validation_requested, validation_done, validated = false, 0, 0
local running, prepare_done, started, deadline, aborted = 0, 0, nil, nil, false
local stat = {login = {}, req = {}, elapsed = {}, rejects = {}, reject_reasons = {}, march_rejects = {}, errors = {}, requests = 0,
    successful = 0, expected = 0, attempted = 0, missed = 0,
    draws = 0, draw_requests = 0, draw_final = {},
    hero_initial = {}, hero_final = {}, hero_ids = {}, hero_added = 0, hero_verified = 0,
    route_queries = 0, route_rejected = 0, validation_failed = 0,
    setup_failed = 0, runtime_failed = 0, timeouts = 0, finished = 0}
local function ms() return skynet.hpc() / 1e6 end
local function failure(message)
    message = tostring(message):sub(1, 180)
    stat.errors[message] = (stat.errors[message] or 0) + 1
end
local function request(ws, name, response, body, decode, due, validate)
    local begin = ms()
    if due ~= nil then stat.attempted = stat.attempted + 1 end
    pending[ws] = begin
    P.send(ws, name, body)
    local got, data = P.recv_match(ws, {[response] = true, s2c_tell_me = true},
        decode and {[response] = true, s2c_tell_me = true} or {s2c_tell_me = true})
    pending[ws] = nil
    if not got then error(name .. ": " .. tostring(data)) end
    local invalid = got ~= "s2c_tell_me" and validate and not validate(data)
    metrics.response(stat, name, begin, ms(), due, got == "s2c_tell_me" or invalid)
    if invalid or got == "s2c_tell_me" then
        local reason = invalid and "invalid or duplicate response" or tostring(data and data.msg or "<missing message>")
        if due ~= nil then
            local reasons = stat.reject_reasons[name] or {}
            stat.reject_reasons[name] = reasons
            reasons[reason] = (reasons[reason] or 0) + 1
        end
        if invalid then error(name .. ": " .. reason) end
        return false, reason
    end
    return true, data
end
local function gm(ws, command)
    pending[ws] = ms()
    P.send(ws, "c2s_gm_command", {cmd = command})
    while true do
        local got, body = P.recv_match(ws, {s2c_tell_me = true}, {s2c_tell_me = true})
        if not got then error("GM connection closed") end
        local message = body and body.msg or ""
        if message:find("指令使用成功", 1, true) then break end
        if message:find("指令使用失败", 1, true) then error(message) end
    end
    pending[ws] = nil
end
local function heartbeat(ws)
    assert(request(ws, "c2s_heart_beat", "s2c_heart_beat"))
end
local function hero_ids(list)
    local ids, count = {}, 0
    for _, hero in ipairs(list or {}) do
        assert(type(hero.heroId) == "number" and hero.heroId > 0 and not ids[hero.heroId], "invalid hero roster")
        ids[hero.heroId], count = true, count + 1
    end
    return ids, count
end
local function prepare(idx)
    local beginning, sockets = ms(), {}
    local ws, uid = P.login(conf.login_addr, conf.server_id, conf.prefix .. idx, conf.timeout_ms / 10,
        function(socket) sockets[#sockets + 1] = socket; pending[socket] = ms() end)
    for _, socket in ipairs(sockets) do pending[socket] = nil end
    assert(ws, tostring(uid))
    clients[idx] = {ws = ws, uid = uid}
    stat.login[#stat.login + 1] = ms() - beginning
    assert(request(ws, "c2s_client_load_ok", "s2c_client_load_ok"))
    local ok, user = request(ws, "c2s_user_base_info", "s2c_user_base_info", nil, true)
    assert(ok)
    local fresh = conf.account_model == "fresh"
    assert(not fresh or not user.sex or user.sex == 0,
        string.format("fresh model requires a new account idx=%d uid=%s", idx, tostring(uid)))
    if not user.sex or user.sex == 0 then
        assert(request(ws, "c2s_user_create", "s2c_user_create", {name = "p" .. idx, sex = 1}))
    end
    if not fresh then gm(ws, "super") end
    local tickets = fresh and (math.ceil(conf.duration * 1000 / conf.interval_ms / 20) * 10 + 10) or 100000
    gm(ws, "add_item 103," .. tickets)
    local got_heroes, heroes = request(ws, "c2s_req_all_hero_base_info", "s2c_req_all_hero_base_info", nil, true)
    assert(got_heroes, "hero setup query rejected")
    if fresh and #(heroes.heroInfoList or {}) == 0 then
        gm(ws, "add_hero 1001") -- the configured starting hero, only if absent
        got_heroes, heroes = request(ws, "c2s_req_all_hero_base_info", "s2c_req_all_hero_base_info", nil, true)
        assert(got_heroes, "starting hero query rejected")
    end
    local initial_ids, initial_count = hero_ids(heroes.heroInfoList)
    assert(not fresh or initial_count == 1, "fresh model requires exactly one starting hero")
    clients[idx].hero_ids, clients[idx].hero_count = initial_ids, initial_count
    stat.hero_initial[tostring(uid)] = initial_count
    local hero = assert(heroes.heroInfoList and heroes.heroInfoList[1], "no prepared hero")
    if fresh then
        local soldiers = tonumber((user.soldierInfo or {}).count) or 0
        if soldiers < 100 then gm(ws, "add_soldier " .. (100 - soldiers)) end
    end
    -- An account reused by a later stage may still have its previous march. Keep its formation.
    local edited, edit = request(ws, "c2s_edit_troop", "s2c_edit_troop", {troopInfo = {troopIdx = 1,
        posMap = {{key = 1, value = {heroIdx = hero.heroId, soldier = {count = 100}}}}}}, true)
    local usable = edited and metrics.usable_troop(edit.troopInfo, 1)
    if not usable then
        local got_troops, troops = request(ws, "c2s_req_troop", "s2c_req_troop", nil, true)
        assert(got_troops, "existing formation query rejected")
        for _, troop in ipairs(troops.troopList or {}) do
            if metrics.usable_troop(troop, 1) then usable = true; break end
        end
    end
    assert(usable, "no usable prepared formation")
    ok, user = request(ws, "c2s_user_base_info", "s2c_user_base_info", nil, true)
    assert(ok, "city setup query rejected")
    clients[idx].city = assert(user.cityPos, "no birth position")
    local got_lottery, lottery = request(ws, "c2s_req_user_lottery_info", "s2c_req_user_lottery_info", nil, true)
    assert(got_lottery and type(lottery.lotteryTimes) == "number" and lottery.lotteryTimes >= 0
        and lottery.lotteryTimes % 1 == 0, "invalid lottery setup baseline")
    assert(not fresh or lottery.lotteryTimes == 0, "fresh model account already drew heroes")
    clients[idx].lottery_times = lottery.lotteryTimes
    stat.draw_final[tostring(uid)] = lottery.lotteryTimes
end
local function validate_route(idx)
    local client = clients[idx]
    -- All accounts have finished construction before this phase is requested.
    -- Re-read the city here; no earlier candidate is trusted across setup.
    local ok, user = request(client.ws, "c2s_user_base_info", "s2c_user_base_info", nil, true)
    assert(ok and user.cityPos, "route validation city query failed")
    local city, tried = user.cityPos, 0
    client.city = city
    for _, distance in ipairs({20, 8, 4, 2, 1}) do
        for _, direction in ipairs({{1,0},{0,1},{-1,0},{0,-1},{1,1},{-1,1},{-1,-1},{1,-1}}) do
            local pos = {x = city.x + direction[1] * distance, y = city.y + direction[2] * distance}
            if pos.x >= 0 and pos.y >= 0 and pos.x < 1000 and pos.y < 1000 then
                tried, stat.route_queries = tried + 1, stat.route_queries + 1
                local accepted, route = request(client.ws, "c2s_req_march_route", "s2c_req_march_route",
                    {troopIdx = 1, targetType = 4, targetPos = pos}, true)
                if accepted and route.path and #route.path >= 2 then client.target = pos; return end
                stat.route_rejected = stat.route_rejected + 1
            end
        end
    end
    error(string.format("no reachable route idx=%d uid=%s city=(%s,%s) candidates=%d",
        idx, tostring(client.uid), tostring(city.x), tostring(city.y), tried), 0)
end
local QUERIES = {
    {"c2s_user_base_info", "s2c_user_base_info"},
    {"c2s_req_user_res", "s2c_req_user_res"},
    {"c2s_req_troop", "s2c_req_troop"},
    {"c2s_req_all_hero_base_info", "s2c_req_all_hero_base_info"},
    {"c2s_req_task_list", "s2c_req_task_list", {taskType = 0}},
    {"c2s_req_rank_list", "s2c_req_rank_list", {rankType = 1, start = 1, count = 20}},
    {"c2s_req_march_list", "s2c_req_march_list"},
}
local function workload(idx)
    local client = clients[idx]
    local ws, returning = client.ws, false
    local plan, slot = assert(plans[idx]), 0
    while not aborted and slot < plan.expected do
        local due = plan.first + slot * plan.interval
        while not aborted and ms() < due do
            skynet.sleep(math.max(1, metrics.wait_ticks(due, ms())))
        end
        if aborted then break end
        -- The window bounds planned due times, not timer wakeups. Keep its
        -- final slot even when the 10ms clock wakes after the deadline; that
        -- lateness remains visible in scheduled_latency. A longer pause skips
        -- stale intermediate slots instead of replaying their backlog.
        slot = math.min(plan.expected - 1, metrics.next_slot(plan, slot, ms()))
        due = plan.first + slot * plan.interval
        local step = idx % 20 + slot
        if step % 10 == 0 then
            local target_type, sent_at = returning and 1 or 4, ms()
            local ok, reason = request(ws, "c2s_march", "s2c_march", {troopIdx = 1, targetType = target_type,
                targetId = 0, targetPos = client.target}, true, due)
            if ok then returning = not returning
            elseif #stat.march_rejects < 20 then
                local target = returning and client.city or client.target
                stat.march_rejects[#stat.march_rejects + 1] = {at = sent_at, idx = idx, uid = client.uid,
                    target_type = target_type, x = target.x, y = target.y, returning = returning, msg = reason}
            end
        elseif step % 20 == 5 then
            local expected = client.lottery_times + 10
            local additions = {}
            local ok = request(ws, "c2s_user_lottery", "s2c_user_lottery", {useLotteryTimes = 10}, true, due, function(draw)
                if draw.useLotteryTimes ~= 10 or draw.lotteryTimes ~= expected
                    or not draw.rewardList or #draw.rewardList == 0 then return false end
                if conf.account_model == "fresh" then
                    for _, reward in ipairs(draw.rewardList) do
                        if reward.rewardType == 3 then
                            local id = reward.itemId
                            if type(id) ~= "number" or id <= 0 or reward.itemCount ~= 1
                                or client.hero_ids[id] or additions[id] then return false end
                            additions[id] = true
                        end
                    end
                end
                return true
            end)
            assert(ok, "draw did not succeed")
            for id in pairs(additions) do client.hero_ids[id], client.hero_count = true, client.hero_count + 1 end
            client.lottery_times = expected
            stat.draws, stat.draw_requests = stat.draws + 10, stat.draw_requests + 1
            stat.draw_final[tostring(client.uid)] = expected
        elseif step % 10 == 7 then
            P.send(ws, "c2s_aoi_focus", {pos = client.city})
            request(ws, "c2s_req_march_list", "s2c_req_march_list", nil, false, due)
        elseif step % 10 == 9 then
            request(ws, "c2s_heart_beat", "s2c_heart_beat", nil, false, due)
        else
            local query = QUERIES[step % #QUERIES + 1]
            request(ws, query[1], query[2], query[3], false, due)
        end
        slot = slot + 1
        if slot < plan.expected then
            slot = math.min(plan.expected - 1, metrics.next_slot(plan, slot, ms()))
        end
    end
end
local function verify_heroes(idx)
    local client = clients[idx]
    local ok, reply = request(client.ws, "c2s_req_all_hero_base_info", "s2c_req_all_hero_base_info", nil, true)
    assert(ok, "final hero roster query rejected")
    local actual, count = hero_ids(reply.heroInfoList)
    assert(count == client.hero_count, "final hero count disagrees with acknowledged lottery rewards")
    for id in pairs(client.hero_ids) do assert(actual[id], "acknowledged new hero is missing") end
    local uid = tostring(client.uid)
    local sorted_ids = {}
    for id in pairs(actual) do sorted_ids[#sorted_ids + 1] = id end
    table.sort(sorted_ids)
    stat.hero_ids[uid] = sorted_ids
    stat.hero_final[uid] = count
    stat.hero_added = stat.hero_added + count - stat.hero_initial[uid]
    stat.hero_verified = stat.hero_verified + 1
end
local function run(idx, delay)
    skynet.sleep(delay)
    local was_ready, was_validated = false, false
    local ok, err = xpcall(function() prepare(idx) end, debug.traceback)
    prepare_done = prepare_done + 1
    if not ok then stat.setup_failed = stat.setup_failed + 1; failure(err)
    else
        ready = ready + 1
        was_ready = true
        local beat = ms()
        while not started and not aborted do
            if validation_requested and not was_validated then
                ok, err = xpcall(function() validate_route(idx) end, debug.traceback)
                validation_done = validation_done + 1
                if not ok then stat.validation_failed = stat.validation_failed + 1; break end
                was_validated = true
                validated = validated + 1
            end
            skynet.sleep(50)
            if ms() - beat >= 4000 then
                local alive, why = pcall(heartbeat, clients[idx].ws)
                if not alive then ok, err = false, why; break end
                beat = ms()
            end
        end
        if ok and not aborted then
            ok, err = xpcall(function()
                workload(idx)
                if conf.account_model == "fresh" and not aborted then verify_heroes(idx) end
            end, debug.traceback)
            if ok then stat.finished = stat.finished + 1 end
        end
        if not ok then stat.runtime_failed = stat.runtime_failed + 1; failure(err) end
    end
    if was_validated then validated = validated - 1 end
    if was_ready then ready = ready - 1 end
    if clients[idx] then P.close(clients[idx].ws); pending[clients[idx].ws] = nil; clients[idx] = nil end
    running = running - 1
end
function CMD.prepare(c, indices)
    conf = c
    assigned = indices
    for _, idx in ipairs(indices) do
        running = running + 1
        skynet.fork(run, idx, math.floor((idx - 1) / c.users * c.ramp * 100))
    end
    skynet.fork(function()
        while running > 0 do
            skynet.sleep(50)
            for ws, when in pairs(pending) do
                if ms() - when > conf.timeout_ms then
                    pending[ws] = nil; stat.timeouts = stat.timeouts + 1; P.close(ws)
                end
            end
        end
    end)
end
function CMD.progress()
    return {ready = ready, done = prepare_done, validated = validated, validation_done = validation_done,
        running = running, requests = stat.requests}
end
function CMD.validate_routes()
    assert(not started and not validation_requested, "route validation already requested")
    assert(prepare_done == #assigned and ready == #assigned, "accounts are not all prepared")
    validation_requested = true -- only the existing per-client coroutine reads its socket
end
function CMD.begin(at)
    assert(not started, "measurement already started")
    assert(validated == #assigned and ready == #assigned, "routes are not all validated")
    started, deadline = at, at + conf.duration * 1000
    for _, idx in ipairs(assigned) do
        plans[idx] = metrics.plan(at, conf.duration * 1000, conf.interval_ms, (idx % 100) / 100)
        stat.expected = stat.expected + plans[idx].expected
    end
end
function CMD.abort() aborted = true end
function CMD.results()
    stat.missed = stat.expected - stat.attempted
    assert(stat.missed >= 0, "more attempts than scheduled slots")
    return stat
end
skynet.start(function()
    P.init()
    skynet.dispatch("lua", function(session, _, command, ...)
        local result = assert(CMD[command], command)(...)
        if session ~= 0 then skynet.retpack(result) end
    end)
end)
