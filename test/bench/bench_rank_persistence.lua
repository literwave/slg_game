-- Offline only; no service connection or database mutation.
-- Usage: skynet/3rd/lua/lua test/bench/bench_rank_persistence.lua [rounds=20]
-- Compare the old SERVER/1 ORM dump+BSON with real rank manager + Mongo
-- producer + controlled transport + BSON. Startup population is excluded.
package.path = "lualib/?.lua;lualib/?/init.lua;vendor/lua-zset/?.lua;" .. package.path
package.cpath = "skynet/luaclib/?.so;" .. package.cpath
local store = dofile("test/helpers/rank_store.lua")
local bson = require "bson"
local batch = require "mongo_batch"
local typedef = require "orm.typedef"
local rounds = assert(tonumber(arg[1] or "20"))
assert(rounds >= 1 and rounds % 1 == 0)
local fields = {"_power_tbl", "_city_tbl", "_kill_tbl", "_alliance_power_tbl"}

local function measure(run)
    collectgarbage("collect")
    local times, bytes, count = {}, nil, nil
    for iteration = 1, rounds do
        local started = os.clock()
        local size, operations = run(iteration)
        times[#times + 1] = (os.clock() - started) * 1000
        bytes, count = size, operations
    end
    table.sort(times)
    return times[math.ceil(#times * 0.95)], times[#times], bytes, count
end

print("boards=4; legacy=dump+BSON only; entry=real change+flush+stub storage+BSON; startup excluded")
for _, members in ipairs({100, 1000, 10000}) do
    local rows, old_data = {}, {}
    for kind, field in ipairs(fields) do
        old_data[field] = {}
        for uid = 1, members do
            local name = "player" .. uid
            old_data[field][uid] = {_score = uid, _time = 1000, _name = name, _head_icon = 1}
            rows[string.format("%d:%d", kind, uid)] = {_rank_type = kind, _user_id = uid,
                _score = uid, _time = 1000, _name = name, _head_icon = 1}
        end
    end
    local orm = assert(loadfile("lualib/orm/init.lua"))()
    orm.init(typedef.parse("server.td", "orm/schema"))
    local old_doc = orm.new("server_data", old_data)
    orm.bind(old_doc, "server_col", 1)
    local old_p95, old_max, old_bytes = measure(function(iteration)
        old_doc._power_tbl[1]._score = members + iteration
        local docs = orm.drain(64)
        assert(#docs == 1)
        local _, operation = batch.operation({key = 1, op_type = "$set", field_str = "dat", value = docs[1].dat})
        return #bson.encode(operation), 1
    end)
    local rank, state = store.setup(rows)
    rows, old_data, old_doc, orm = nil, nil, nil, nil
    local bytes, operations
    state.on_save = function(commands)
        bytes, operations = 0, 0
        for _, cmd in ipairs(commands.rank_entry_col) do
            local _, operation = batch.operation(cmd)
            bytes, operations = bytes + #bson.encode(operation), operations + 1
        end
    end
    local new_p95, new_max, new_bytes, new_count = measure(function(iteration)
        rank.set_score(1, 1, members + iteration)
        state.mongo.flush_sync()
        assert(state.rows["1:1"]._score == members + iteration)
        state.calls = {}
        return bytes, operations
    end)
    assert(new_count == 1, "one score change must write one entry regardless of board size")
    print(string.format("members_per_board=%d total_entries=%d rounds=%d legacy_p95_ms=%.3f legacy_max_ms=%.3f legacy_bytes=%d entry_p95_ms=%.3f entry_max_ms=%.3f entry_bytes=%d entry_ops=%d",
        members, members * 4, rounds, old_p95, old_max, old_bytes, new_p95, new_max, new_bytes, new_count))
end
