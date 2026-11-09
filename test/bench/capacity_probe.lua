-- Test-only observer, loaded by the private capacity configuration.
local skynet = require "skynet"
local json = require "capacity_json"
local function call(name, command, ...)
    local address = type(name) == "number" and name or skynet.localname(name)
    if not address then return nil end
    local ok, result = pcall(skynet.call, address, "lua", command, ...)
    return ok and result or nil
end
skynet.start(function()
    local file = assert(io.open(assert(skynet.getenv("capacity_metrics_file")), "a"))
    local sample = 0
    while true do
        local start = skynet.hpc()
        local row = {time = os.time(), sample = sample, world = call(".world", "performance_stats"), agents = {}}
        for _, agent in ipairs(call(".gated", "get_agent_list") or {}) do
            row.agents[#row.agents + 1] = call(agent, "performance_stats") or {}
        end
        row.sample_ms = (skynet.hpc() - start) / 1e6
        file:write(json.encode(row), "\n"); file:flush()
        sample = sample + 1
        skynet.sleep(100)
    end
end)
