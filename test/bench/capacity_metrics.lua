-- Pure scheduling/accounting helpers; no sockets, services or database access.
local M = {}
function M.plan(started, duration_ms, interval_ms, phase)
    assert(duration_ms > 0 and interval_ms > 0 and phase >= 0 and phase < 1)
    local first, deadline = started + phase * interval_ms, started + duration_ms
    return {first = first, deadline = deadline, interval = interval_ms,
        expected = math.max(0, math.ceil((deadline - first) / interval_ms))}
end
function M.next_slot(plan, after, now)
    if now >= plan.deadline then return plan.expected end
    -- Keep at most the current late slot, never replay earlier overdue slots.
    return math.min(plan.expected, math.max(after, math.floor((now - plan.first) / plan.interval)))
end
function M.wait_ticks(due, now)
    return math.max(0, math.ceil((due - now) / 10))
end
function M.response(stat, name, begin, finished, due, rejected)
    if due == nil then return end -- setup/keepalive responses are not measured load
    stat.requests = stat.requests + 1
    stat.req[name] = stat.req[name] or {}
    stat.req[name][#stat.req[name] + 1] = finished - begin
    stat.elapsed[#stat.elapsed + 1] = finished - due
    if rejected then stat.rejects[name] = (stat.rejects[name] or 0) + 1
    else stat.successful = stat.successful + 1 end
end
function M.usable_troop(troop, index)
    if not troop or troop.troopIdx ~= index or (troop.troopState or 0) > 3 then return false end
    for _, value in pairs(troop.posMap or {}) do
        local pos = value.value or value -- pbc map entries / already-decoded map
        if (tonumber(pos.heroIdx) or 0) > 0 and (tonumber((pos.soldier or {}).count) or 0) > 0 then return true end
    end
    return false
end
return M
