local M = dofile("test/bench/capacity_metrics.lua")
local T = {}
function T.phased_slots_count_only_due_times_inside_the_window()
    for _, duration in ipairs({30, 500, 750, 1000, 1501}) do
        for _, phase in ipairs({0, .01, .5, .99}) do
            local p = M.plan(100, duration, 500, phase)
            local count = 0
            for slot = 0, 100 do
                if p.first + slot * p.interval < p.deadline then count = count + 1 end
            end
            assert(p.expected == count)
        end
    end
end
function T.wait_never_rounds_down_and_expired_slots_never_exceed_plan()
    assert(M.wait_ticks(100.1, 100) == 1 and M.wait_ticks(110.1, 100) == 2)
    assert(M.wait_ticks(100, 100) == 0 and M.wait_ticks(90, 100) == 0)
    local p = M.plan(0, 2000, 500, .5)
    assert(p.expected == 4)
    assert(M.next_slot(p, 1, 260) == 1)
    assert(M.next_slot(p, 1, 1800) == 3)
    assert(M.next_slot(p, 1, 2000) == 4)
    assert(M.next_slot(p, 1, 20000) == 4, "must not count slots beyond the deadline")
    local attempted = 1
    assert(p.expected - attempted == 3, "tail slots remain missed even when a request spans the deadline")
end
function T.setup_responses_and_business_rejections_are_not_successes()
    local stat = {requests = 0, successful = 0, req = {}, elapsed = {}, rejects = {}}
    M.response(stat, "setup", 0, 10, nil, false)
    assert(stat.requests == 0 and stat.successful == 0 and #stat.elapsed == 0)
    M.response(stat, "draw", 10, 60, 0, true)
    assert(stat.requests == 1 and stat.successful == 0 and stat.rejects.draw == 1)
    assert(stat.elapsed[1] == 60 and stat.req.draw[1] == 50)
    M.response(stat, "draw", 100, 120, 95, false)
    assert(stat.requests == 2 and stat.successful == 1 and stat.elapsed[2] == 25)
end
function T.formation_requires_the_named_troop_with_hero_soldiers_and_no_siege()
    assert(not M.usable_troop(nil, 1))
    assert(not M.usable_troop({troopIdx = 1, posMap = {}}, 1))
    local p = {heroIdx = 9, soldier = {count = 100}}
    local troop = {troopIdx = 1, troopState = 1, posMap = {{key = 1, value = p}}}
    assert(M.usable_troop(troop, 1) and not M.usable_troop(troop, 2))
    troop.troopState = 4
    assert(not M.usable_troop(troop, 1))
    troop.troopState, troop.posMap = 0, {[1] = p}
    assert(M.usable_troop(troop, 1))
    p.soldier.count = 0
    assert(not M.usable_troop(troop, 1))
end
return T
