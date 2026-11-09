-- Offline only: serialize synthetic ORM documents; no Skynet service or database.
-- Usage: skynet/3rd/lua/lua test/bench/bench_orm_flush.lua [orm.lua] [batch_limit]
package.path = "lualib/?.lua;lualib/?/init.lua;" .. package.path
package.cpath = "skynet/luaclib/?.so;" .. package.cpath
local orm = assert(loadfile(arg[1] or "lualib/orm/init.lua"))()
local typedef = require "orm.typedef"
orm.init(typedef.parse("hero.td", "orm/schema"))
local limit = tonumber(arg[2] or "64")
if limit == 0 then limit = nil end
local docs, heroes = 256, 80
for uid = 1, docs do
    local bag = {}
    for hero = 1, heroes do
        bag[hero] = {_hero_type = hero, _user_id = uid, _level = 30,
            _exp = 200, _star = 5, _equip_tbl = {[1] = 120}, _skill_tbl = {[1] = 9}}
    end
    local doc = orm.new("user_hero_doc", {_heroes = bag})
    orm.bind(doc, "benchmark_heroes", uid)
    orm.touch(doc)
end
collectgarbage("collect")
local count, batches, peak, total, first = 0, 0, 0, 0, nil
while true do
    local started = os.clock()
    local rows = orm.drain(limit)
    local elapsed = (os.clock() - started) * 1000
    if #rows == 0 then break end
    first = first or elapsed
    count, batches = count + #rows, batches + 1
    peak, total = math.max(peak, elapsed), total + elapsed
end
assert(count == docs)
print(string.format("docs=%d heroes_each=%d limit=%s batches=%d first_ms=%.3f peak_ms=%.3f total_ms=%.3f",
    docs, heroes, tostring(limit or "all"), batches, first, peak, total))
