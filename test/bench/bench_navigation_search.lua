-- Same-script before/after benchmark for native search scratch cleanup.
-- lua test/bench/bench_navigation_search.lua [native_root] [queries]
package.path="vendor/slg-navigation/?.lua;"..package.path
package.cpath=(arg[1] or "skynet/luaclib").."/?.so;"..package.cpath
local navigation=require "navigation"
local queries=tonumber(arg[2] or "2000")
local terrain,blocked={},{}
for _,id in ipairs(dofile("res/map/terrain.lua").blockedCells) do
    terrain[#terrain+1]={id%1000,id//1000};blocked[id]=true
end
local nav=navigation.new(1000,1000,terrain)
local seed,cases=12345,{}
local function rand(n) seed=(seed*48271)%2147483647;return seed%n end
for i=1,queries+100 do
    local x,y,ex,ey
    repeat
        x,y=rand(960)+20,rand(960)+20
        ex,ey=x+rand(41)-20,y+rand(41)-20
    until not blocked[y*1000+x] and not blocked[ey*1000+ex]
    cases[i]={x+.5,y+.5,ex+.5,ey+.5}
end
local samples,checksum,found={},2166136261,0
local function digest(n) checksum=((checksum ~ n)*16777619)&0xffffffff end
collectgarbage("collect")
for i,c in ipairs(cases) do
    local started=os.clock()
    local path=nav.core:find_path(table.unpack(c))
    local elapsed=(os.clock()-started)*1000
    if i>100 then
        samples[#samples+1]=elapsed
        digest(path and #path or 0)
        if path then found=found+1;for _,pos in ipairs(path) do digest(math.floor(pos[1]*1000000));digest(math.floor(pos[2]*1000000)) end end
    end
end
table.sort(samples)
local total=0;for _,v in ipairs(samples) do total=total+v end
local function percentile(p)return samples[math.ceil(#samples*p)] end
print(string.format("queries=%d found=%d digest=%08x total_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f",queries,found,checksum,total,percentile(.5),percentile(.95),percentile(.99),percentile(1)))
