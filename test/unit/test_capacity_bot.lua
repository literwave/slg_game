local metrics = dofile("test/bench/capacity_metrics.lua")
local T = {}
local function setup(options)
    options = options or {}
    local s = {now = 0, forks = {}, sent = {}, closed = {}, lottery_times = options.lottery_times or 0,
        heroes = options.heroes or {{heroId = 7}}, hero_added = false}
    local skynet = {
        hpc = function() return s.now * 1e6 end,
        sleep = function(ticks) return coroutine.yield(ticks) end,
        fork = function(fn, ...)
            local args = {...}
            local co = coroutine.create(function() fn(table.unpack(args)) end)
            s.forks[#s.forks + 1] = co
            return co
        end,
        start = function(fn) fn() end,
        dispatch = function(_, fn) s.dispatch = fn end,
        retpack = function(value) s.result = value end,
    }
    local troop = {troopIdx = 1, troopState = 1,
        posMap = {{key = 1, value = {heroIdx = 7, soldier = {count = 100}}}}}
    local proto = {
        init = function() end,
        login = function(_, _, _, _, on_conn) on_conn(1); return 1, 99 end,
        close = function(ws) s.closed[ws] = true end,
        send = function(_, name, body)
            s.last, s.last_body = name, body
            s.sent[#s.sent + 1] = {name = name, body = body, at = s.now}
        end,
        recv_match = function()
            local name = s.last
            if name == "c2s_gm_command" then
                if s.last_body.cmd == "add_hero 1001" then s.heroes = {{heroId = 1001}} end
                return "s2c_tell_me", {msg = "指令使用成功"}
            end
            if name == "c2s_user_base_info" then
                return "s2c_user_base_info", {sex = options.fresh and not options.old_account and 0 or 1,
                    soldierInfo = {count = options.soldiers or 8000}, cityPos = {x = 500, y = 500}}
            end
            if name == "c2s_req_all_hero_base_info" then
                local heroes = options.omit_earned_hero and s.hero_added and {{heroId = 7}} or s.heroes
                return "s2c_req_all_hero_base_info", {heroInfoList = heroes}
            end
            if name == "c2s_edit_troop" then
                if options.reject_edit then return "s2c_tell_me", {msg = "formation locked"} end
                return "s2c_edit_troop", {troopInfo = troop}
            end
            if name == "c2s_req_troop" then return "s2c_req_troop", {troopList = options.no_troop and {} or {troop}} end
            if name == "c2s_req_march_route" then
                if options.pause_route then coroutine.yield("route") end
                local pos = s.last_body.targetPos
                if options.no_route or (options.only_diagonal_one and (pos.x ~= 501 or pos.y ~= 501)) then
                    return "s2c_tell_me", {msg = "unreachable"}
                end
                return "s2c_req_march_route", {path = {{x = 500, y = 500}, pos}}
            end
            if name == "c2s_req_user_lottery_info" then
                if options.reject_lottery_info then return "s2c_tell_me", {msg = "no baseline"} end
                return "s2c_req_user_lottery_info", {lotteryTimes = s.lottery_times}
            end
            if name == "c2s_heart_beat" and s.fail_heartbeat then return nil, "closed" end
            if name == "c2s_march" and (s.reject_marches or 0) > 0 then
                s.reject_marches = s.reject_marches - 1
                return "s2c_tell_me", {msg = "troop depleted"}
            end
            if s.reject_runtime then return "s2c_tell_me", {msg = "business rejected"} end
            if name == "c2s_user_lottery" then
                if not s.duplicate_draw then s.lottery_times = s.lottery_times + 10 end
                local rewards = {{}}
                if options.new_hero and not s.hero_added then
                    s.heroes[#s.heroes + 1], s.hero_added = {heroId = options.new_hero}, true
                    rewards = {{rewardType = 3, itemId = options.new_hero, itemCount = 1}}
                end
                return "s2c_user_lottery", {useLotteryTimes = 10, lotteryTimes = s.lottery_times, rewardList = rewards}
            end
            return name:gsub("^c2s_", "s2c_"), {}
        end,
    }
    local env = setmetatable({require = function(name)
        if name == "skynet" then return skynet end
        if name == "bench_proto" then return proto end
        if name == "capacity_metrics" then return metrics end
        return require(name)
    end}, {__index = _G})
    assert(loadfile("test/bench/capacity_bot.lua", "t", env))()
    function s.command(name, ...)
        s.result = nil
        s.dispatch(1, 0, name, ...)
        return s.result
    end
    function s.resume(now)
        s.now = now
        local ok, why = coroutine.resume(s.forks[1])
        assert(ok, why)
        return why
    end
    s.command("prepare", {users = options.idx or 1, duration = options.duration or 2, ramp = 0, interval_ms = 500,
        timeout_ms = 15000, prefix = "offline_", account_model = options.fresh and "fresh" or "super"}, {options.idx or 1})
    s.resume(0) -- initial ramp sleep
    s.resume(0) -- setup, then wait for measurement start
    if not options.defer_validation and s.command("progress").ready == 1 then
        s.command("validate_routes")
        s.resume(0)
    end
    return s
end

function T.ready_user_lost_before_start_is_removed_and_setup_is_not_load()
    local s = setup()
    assert(s.command("progress").ready == 1)
    s.fail_heartbeat = true
    s.resume(4500)
    local progress, result = s.command("progress"), s.command("results")
    assert(progress.ready == 0 and progress.running == 0 and s.closed[1])
    assert(result.runtime_failed == 1 and result.requests == 0 and result.successful == 0 and result.attempted == 0)
end

function T.rejected_edit_requires_a_real_usable_existing_formation()
    local bad = setup({reject_edit = true, no_troop = true})
    assert(bad.command("progress").ready == 0 and bad.command("results").setup_failed == 1)
    local valid = setup({reject_edit = true})
    assert(valid.command("progress").ready == 1 and valid.command("results").setup_failed == 0)
    valid.command("abort")
    valid.resume(500)
    assert(valid.command("progress").ready == 0 and valid.closed[1])
end

function T.actual_bot_never_sends_early_and_skips_stale_middle_slots()
    local s = setup()
    s.command("begin", 1000)
    assert(s.resume(1000) == 1) -- phase=5ms, so wait one whole tick
    local sent = #s.sent
    assert(s.resume(1001) == 1 and #s.sent == sent, "early wake must wait again")
    s.resume(1010)
    assert(#s.sent == sent + 1 and s.sent[#s.sent].at >= 1005)
    -- A long stall skips the middle slots; the final planned slot still runs,
    -- with its full late arrival recorded instead of hiding the overload.
    s.resume(4000)
    local result = s.command("results")
    assert(result.expected == 4 and result.attempted == 2 and result.missed == 2)
    assert(result.requests == 2 and result.successful == 2 and result.elapsed[1] == 5)
    assert(result.elapsed[2] == 1495 and result.finished == 1)
end

function T.final_planned_slot_survives_ten_ms_wakeup_at_deadline()
    local s = setup({idx = 99})
    s.command("begin", 1000)
    assert(s.resume(1000) == 50) -- first due=1495ms, rounded wait wakes at 1500ms
    for _, now in ipairs({1500, 2000, 2500, 3000}) do s.resume(now) end
    local result = s.command("results")
    assert(result.expected == 4 and result.attempted == 4 and result.missed == 0)
    assert(result.requests == 4 and result.successful == 4 and result.finished == 1)
    for _, latency in ipairs(result.elapsed) do assert(latency == 5) end
    assert(s.sent[#s.sent].at == 3000, "due=2995ms remains valid after the nominal deadline")
end

function T.lottery_uses_setup_baseline_and_reports_only_validated_increments()
    local s = setup({idx = 5, lottery_times = 70})
    assert(s.command("results").draw_final["99"] == 70)
    s.command("begin", 1000)
    s.resume(1000)
    s.resume(1030) -- slot zero is this account's first ten-pull
    local result = s.command("results")
    assert(result.draws == 10 and result.draw_requests == 1 and result.draw_final["99"] == 80)
    assert(result.successful == 1 and result.runtime_failed == 0)
end

function T.duplicate_draw_response_is_rejected_and_keeps_last_valid_expectation()
    local s = setup({idx = 5, lottery_times = 70, duration = 12})
    s.command("begin", 1000)
    s.resume(1000)
    s.resume(1030)
    assert(s.command("results").draw_final["99"] == 80)
    s.duplicate_draw = true
    -- A late timer wake skips straight to slot 20, another draw. Its repeated
    -- lotteryTimes must fail, not count success or replay intervening queries.
    s.resume(11030)
    local result = s.command("results")
    assert(result.runtime_failed == 1 and result.finished == 0)
    assert(result.draws == 10 and result.draw_requests == 1 and result.draw_final["99"] == 80)
    assert(result.rejects.c2s_user_lottery == 1 and result.successful == 1 and result.requests == 2)
    assert(result.reject_reasons.c2s_user_lottery["invalid or duplicate response"] == 1)
end

function T.failed_lottery_baseline_never_marks_user_ready()
    local s = setup({reject_lottery_info = true})
    assert(s.command("progress").ready == 0)
    local result = s.command("results")
    assert(result.setup_failed == 1 and result.successful == 0 and next(result.draw_final) == nil)
end

function T.route_validation_is_a_second_phase_on_the_existing_socket_reader()
    local s = setup({defer_validation = true, pause_route = true})
    for _, sent in ipairs(s.sent) do assert(sent.name ~= "c2s_req_march_route") end
    assert(s.command("progress").ready == 1 and s.command("progress").validated == 0)
    assert(not pcall(s.command, "begin", 1000), "unvalidated users must never enter measurement")
    local forks, sent = #s.forks, #s.sent
    s.command("validate_routes")
    assert(#s.sent == sent and #s.forks == forks, "command must not create a second socket reader")
    assert(s.resume(0) == "route")
    assert(s.command("progress").validation_done == 0)
    s.resume(0)
    assert(s.command("progress").validated == 1 and s.command("progress").validation_done == 1)
    assert(s.command("results").requests == 0, "route setup is outside measured throughput")
end

function T.routes_try_bounded_distances_and_diagonals_until_really_reachable()
    local s = setup({only_diagonal_one = true})
    local progress, result = s.command("progress"), s.command("results")
    assert(progress.validated == 1 and result.route_queries == 37 and result.route_rejected == 36)
    assert(result.requests == 0 and result.successful == 0 and result.runtime_failed == 0)
    assert(next(result.reject_reasons) == nil, "setup route rejects must not enter measured reasons")
    local candidates = {}
    for _, sent in ipairs(s.sent) do
        if sent.name == "c2s_req_march_route" then candidates[#candidates + 1] = sent.body.targetPos end
    end
    assert(candidates[1].x == 520 and candidates[9].x == 508 and candidates[17].x == 504)
    assert(candidates[25].x == 502 and candidates[33].x == 501)
    assert(candidates[37].x == 501 and candidates[37].y == 501)
end

function T.all_unreachable_candidates_fail_validation_with_account_and_city()
    local s = setup({no_route = true, idx = 1000})
    local progress, result = s.command("progress"), s.command("results")
    assert(progress.ready == 0 and progress.validated == 0 and progress.validation_done == 1)
    assert(result.route_queries == 40 and result.route_rejected == 40 and result.validation_failed == 1)
    assert(result.finished == 0 and result.runtime_failed == 1 and result.successful == 0)
    local message = next(result.errors)
    assert(message:find("idx=1000", 1, true) and message:find("uid=99", 1, true)
        and message:find("city=(500,500)", 1, true))
end

function T.fresh_default_hero_and_soldiers_need_only_tickets_then_verify_new_hero()
    local s = setup({fresh = true, idx = 5, new_hero = 3})
    local commands = {}
    for _, sent in ipairs(s.sent) do
        if sent.name == "c2s_gm_command" then commands[#commands + 1] = sent.body.cmd end
    end
    assert(#commands == 1 and commands[1] == "add_item 103,20")
    assert(s.command("results").hero_initial["99"] == 1)
    s.command("begin", 1000)
    s.resume(1000)
    for _, now in ipairs({1030, 1530, 2030, 2530}) do s.resume(now) end
    local result = s.command("results")
    assert(result.finished == 1 and result.runtime_failed == 0)
    assert(result.draw_final["99"] == 10 and result.draws == 10)
    assert(result.hero_final["99"] == 2 and result.hero_added == 1 and result.hero_verified == 1)
    assert(#result.hero_ids["99"] == 2 and result.hero_ids["99"][1] == 3 and result.hero_ids["99"][2] == 7,
        "final observed hero IDs must be numerically sorted for database comparison")
    assert(result.requests == 4, "final roster verification must not inflate timed throughput")
end

function T.fresh_model_rejects_old_accounts_and_full_or_previously_drawn_rosters()
    for _, options in ipairs({{old_account = true}, {heroes = {{heroId = 7}, {heroId = 8}}}, {lottery_times = 10}}) do
        options.fresh = true
        local s = setup(options)
        assert(s.command("progress").ready == 0 and s.command("results").setup_failed == 1)
    end
end

function T.fresh_missing_starting_resources_use_only_one_hero_and_soldier_shortfall()
    local s = setup({fresh = true, heroes = {}, soldiers = 20})
    local commands = {}
    for _, sent in ipairs(s.sent) do
        if sent.name == "c2s_gm_command" then commands[sent.body.cmd] = true end
    end
    assert(commands["add_hero 1001"] and commands["add_soldier 80"])
    assert(not commands.super and not commands.full_hero and not commands.full_build)
    assert(s.command("progress").ready == 1 and s.command("results").hero_initial["99"] == 1)
end

function T.fresh_final_roster_must_include_every_acknowledged_new_hero()
    local s = setup({fresh = true, idx = 5, new_hero = 8, omit_earned_hero = true})
    s.command("begin", 1000)
    s.resume(1000)
    for _, now in ipairs({1030, 1530, 2030, 2530}) do s.resume(now) end
    local result = s.command("results")
    assert(result.finished == 0 and result.runtime_failed == 1 and result.hero_verified == 0)
    assert(result.draw_final["99"] == 10 and result.hero_final["99"] == nil)
    assert(result.hero_ids["99"] == nil, "a failed roster verification must not publish a verified ID set")
end


function T.rejected_march_retains_direction_and_records_only_measured_reasons()
    local s = setup({idx = 20, duration = 12})
    s.reject_marches = 1
    s.command("begin", 1000)
    s.resume(1000)
    for slot = 0, 23 do s.resume(1100 + slot * 500) end
    local result = s.command("results")
    assert(result.requests == 24 and result.successful == 23 and result.rejects.c2s_march == 1)
    assert(result.reject_reasons.c2s_march["troop depleted"] == 1)
    assert(result.finished == 1 and result.missed == 0)
    local marches = {}
    for _, sent in ipairs(s.sent) do if sent.name == "c2s_march" then marches[#marches + 1] = sent end end
    assert(#marches == 3)
    assert(marches[1].body.targetType == 4 and marches[2].body.targetType == 4,
        "a rejected outward march must not switch the next action to return")
    assert(marches[3].body.targetType == 1, "successful outward march switches to return")
    local sample = assert(result.march_rejects[1])
    assert(#result.march_rejects == 1 and sample.idx == 20 and sample.uid == 99)
    assert(sample.target_type == 4 and sample.x == 520 and sample.y == 500 and not sample.returning)
    assert(sample.msg == "troop depleted")
end

function T.rejected_requests_never_increment_success_and_samples_are_bounded()
    local s = setup({idx = 20, duration = 110})
    s.reject_marches = 100
    s.command("begin", 1000)
    s.resume(1000)
    for slot = 0, 219 do s.resume(1100 + slot * 500) end
    local result = s.command("results")
    assert(result.requests == 220 and result.successful == 198)
    assert(result.rejects.c2s_march == 22 and result.reject_reasons.c2s_march["troop depleted"] == 22)
    assert(#result.march_rejects == 20, "sample cap must not cap the complete reason counts")
end

return T
