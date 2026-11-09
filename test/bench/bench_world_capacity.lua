-- Offline capacity checks against actual world modules and native navigation.
-- lua test/bench/bench_world_capacity.lua nav|aoi [module.lua] [static_count] [alliances|movers]
-- No live services, sockets or database. Each invocation has its own Lua state.
package.path = "lualib/?.lua;lualib/?/init.lua;vendor/slg-navigation/?.lua;" .. package.path
package.cpath = "skynet/luaclib/?.so;" .. package.cpath
local mode = assert(arg[1], "expected nav or aoi")
local function load_env(path, initial)
    local env = setmetatable(initial or {}, {__index=_G})
    assert(loadfile(path, "t", env))()
    return env
end
local function rss()
    local f = assert(io.open("/proc/self/status")); local data=f:read("a"); f:close()
    return tonumber(data:match("VmRSS:%s+(%d+)")) or 0
end
local function summary(samples)
    table.sort(samples)
    local function at(p) return samples[math.max(1,math.ceil(#samples*p))] or 0 end
    return string.format("samples=%d p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f",#samples,at(.5),at(.95),at(.99),at(1))
end
local function noop() end
if mode == "nav" then
    local source = arg[2] or "logic/service/world/module/map/mgr.lua"
    local city_count, alliances = tonumber(arg[3] or "1000"), tonumber(arg[4] or "24")
    local navigation = require "navigation"
    local native_created = 0
    local counted = {new=function(...)
        native_created = native_created+1
        return navigation.new(...)
    end}
    local blocked, terrain = {}, {}
    for _, id in ipairs(dofile("res/map/terrain.lua").blockedCells) do
        blocked[id+1]=true; terrain[#terrain+1]={id%1000,id//1000}
    end
    local env = load_env(source, {require=function(name)
        if name=="skynet" then return {getenv=function() return nil end} end
        if name=="navigation" then return counted end
        return require(name)
    end, ENCOUNTER_MGR={alliance_of={}}})
    env.map_obj={get_width=function() return 1000 end,get_height=function() return 1000 end,
        is_block=function(_,idx) return blocked[idx] end}
    env.terrain_obstacles,env.alliance_cities=terrain,{}
    local setup_start=os.clock()
    env.rebuild_city_navigation()
    env.begin_nav_batch()
    local placed=0
    for y=100,899,5 do
        for x=100,899,5 do
            if placed < city_count and not blocked[y*1000+x+1] then
                placed=placed+1
                env.ENCOUNTER_MGR.alliance_of[1000+placed]=placed%alliances+1
                env.set_city(1000+placed,x,y)
            end
        end
    end
    assert(placed==city_count,"not enough synthetic city positions")
    env.end_nav_batch()
    local setup_ms=(os.clock()-setup_start)*1000
    local sx,sy
    for y=1,90 do
        for x=1,90 do
            if not sx and not blocked[y*1000+x+1] and not blocked[y*1000+x+2] then sx,sy=x,y end
        end
    end
    assert(sx)
    collectgarbage("collect")
    local samples={}
    for round=1,2 do
        for id=1,alliances do
            env.ENCOUNTER_MGR.alliance_of[id]=id
            local started=os.clock()
            assert(env.find_march_path(id,sx,sy,sx+1,sy),"short route unexpectedly unreachable")
            samples[#samples+1]=(os.clock()-started)*1000
        end
    end
    local cached=0;for _ in pairs(env.nav_of_alliance) do cached=cached+1 end
    print(string.format("mode=nav cities=%d alliances=%d native_created=%d cached=%d setup_ms=%.3f rss_kb=%d %s",city_count,alliances,native_created,cached,setup_ms,rss(),summary(samples)))
elseif mode == "aoi" then
    local source=arg[2] or "logic/service/world/module/aoi/mgr.lua"
    local static_count,movers=tonumber(arg[3] or "100000"),tonumber(arg[4] or "100")
    local now=0
    local fake_skynet={getenv=noop,timeout=noop,fork=noop,send=noop,error=error}
    local march=load_env("common/march_path.lua")
    local data={TROOP_STATE={MARCH=1,STAY=2,SIEGE=4},ENTITY_TYPE={CITY=1,TROOP=2,ALLIANCE_CITY=5},
        TARGET_TYPE=dofile("game_common/server/enum/TargetTypeEnum.lua")}
    local encounter=load_env("logic/service/world/module/encounter/mgr.lua",{MARCH_PATH=march,DATA_COMMON=data})
    local env=load_env(source,{require=function(name) if name=="skynet" then return fake_skynet end return require(name) end,
        CONST=load_env("logic/define/const.lua"),MARCH_PATH=march,DATA_COMMON=data,ENCOUNTER_MGR=encounter,
        TIME={now=function() return now end},agent_list={"unused"}})
    for i=1,static_count do env.upsert_city(i,(i%1000),i//1000,{name="city",level=1}) end
    for i=1,movers do
        encounter.alliance_of[i]=1
        env.start_march({user_id=i,troop_idx=1,target_type=5,path={{_x=0,_y=i},{_x=900,_y=i}},start_time=0,end_time=900})
    end
    collectgarbage("collect")
    local gc_mode = arg[5] or "normal"
    if gc_mode == "stop" then collectgarbage("stop") end
    local samples, boundaries, regular = {}, {}, {}
    local peak, peak_frame, previous = 0, 0, 0
    for frame=1,500 do
        now=frame*.05
        local started=os.clock();env.step(now);local elapsed=(os.clock()-started)*1000
        if frame>100 then
            samples[#samples+1]=elapsed
            local group = math.floor(now) ~= math.floor(previous) and boundaries or regular
            group[#group+1] = elapsed
            if elapsed > peak then peak,peak_frame=elapsed,frame end
        end
        previous=now
    end
    print(string.format("mode=aoi static=%d movers=%d gc=%s peak_frame=%d lua_kb=%.0f rss_kb=%d %s",static_count,movers,gc_mode,peak_frame,collectgarbage("count"),rss(),summary(samples)))
    print("cell_boundary "..summary(boundaries))
    print("between_cells "..summary(regular))
else error("unknown benchmark mode") end
