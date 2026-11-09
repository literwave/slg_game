-- 使用真实 navigation C/JPS，验证占领通行与攻城停靠，不修改玩家数据。
local T = {}
local navigation = require 'navigation'
local siege = require 'city_siege'

local function fixture(w, h, obstacles, cities)
    local blocked = {}
    for _, p in ipairs(obstacles) do blocked[p[2] * w + p[1] + 1] = true end
    local fake_skynet = {getenv = function() return nil end, sleep = function() error("unguarded sleep") end}
    local shared = {skynet = fake_skynet, ENCOUNTER_MGR = {alliance_of = {[9] = 1, [10] = 2}}, require = function(name)
        if name == 'skynet' then return fake_skynet end
        return require(name)
    end}
    local env = setmetatable({}, {__index = function(_, k) return shared[k] or _G[k] end})
    assert(loadfile('logic/service/world/module/map/mgr.lua', 't', env))()
    env.map_obj = {get_width = function() return w end, get_height = function() return h end,
        is_block = function(_, index) return blocked[index] end}
    env.terrain_obstacles, env.alliance_cities = obstacles, cities
    env.rebuild_city_navigation()
    return env, shared
end

local function gate_fixture()
    local terrain = {{9, 4}}
    for y = 0, 11 do if y < 4 or y > 6 then terrain[#terrain + 1] = {10, y} end end
    local city = {id = 101, x = 10, y = 5, radius = 1}
    local env, shared = fixture(21, 12, terrain, {city})
    return env, shared, city
end

local function misses_city(path, city)
    for i = 2, #path do
        local a, b = path[i - 1], path[i]
        local steps = math.max(1, math.ceil(math.max(math.abs(b._x-a._x), math.abs(b._y-a._y)) * 12))
        for j = 0, steps do
            local x, y = math.floor(a._x+(b._x-a._x)*j/steps), math.floor(a._y+(b._y-a._y)*j/steps)
            assert(math.abs(x-city.x) > city.radius or math.abs(y-city.y) > city.radius,
                string.format('route crosses closed city at %d,%d', x, y))
        end
    end
end

function T.neutral_enemy_and_unallied_gate_is_closed()
    local m = gate_fixture()
    for _, owner in ipairs({0, 2}) do
        m.set_alliance_city_owner(101, owner)
        assert(not m.find_march_path(9, 2, 5, 18, 5))
        assert(not m.find_march_path(9, 18, 5, 2, 5))
        assert(not m.find_march_path(99, 2, 5, 18, 5))
    end
end

function T.capture_and_loss_refresh_existing_cached_navigation()
    local m = gate_fixture()
    assert(not m.find_march_path(9, 2, 5, 18, 5)) -- 先缓存关闭的视图。
    m.set_alliance_city_owner(101, 1)
    assert(m.find_march_path(9, 2, 5, 18, 5), 'own alliance may pass')
    assert(m.nav_of_alliance[1]:is_obstacle({x=9,y=4}), 'capture must not erase terrain')
    assert(not m.find_march_path(10, 2, 5, 18, 5), 'other alliance remains blocked')
    m.set_alliance_city_owner(101, 2)
    assert(not m.find_march_path(9, 2, 5, 18, 5), 'losing the pass invalidates cached permission')
    assert(m.find_march_path(10, 2, 5, 18, 5))
    assert(not m.find_march_path(99, 2, 5, 18, 5))
end

function T.siege_stays_on_reachable_side_from_both_directions()
    local m, _, city = gate_fixture()
    for _, origin in ipairs({2, 18}) do
        local path = assert(m.find_city_approach(9, origin, 5, city))
        assert((origin < city.x) == (path[#path]._x < city.x))
        misses_city(path, city)
        assert(not m.find_march_path(9, 2, 5, 18, 5), 'finding an approach must not open the gate')
    end
end

function T.departing_closed_city_does_not_leave_a_permanent_opening()
    local m = gate_fixture()
    for _, x in ipairs({2, 18}) do
        assert(m.find_march_path(9, 10, 5, x, 5), 'already inside may retreat to either reachable side')
        assert(not m.find_march_path(9, 2, 5, 18, 5), 'temporary departure exemption must be restored')
        assert(not m.find_march_path(9, 18, 5, 2, 5), 'both cached areas must be restored')
    end
end

function T.ownership_cannot_clear_an_overlapping_enemy_player_city()
    local m, shared = gate_fixture()
    shared.ENCOUNTER_MGR.alliance_of[20] = 2
    m.set_city(20, 11, 5)
    m.set_alliance_city_owner(101, 1)
    assert(not m.find_march_path(9, 2, 5, 18, 5))
end

function T.real_tongguan_route_does_not_cross_uncaptured_walls()
    local campaign = dofile('res/map/campaign-map.lua')
    local placements = siege.placements(campaign, dofile('game_common/server/res/City.lua'),
        dofile('game_common/server/enum/CityTypeEnum.lua'), 5000000000000000, 1000)
    local terrain = {}
    for _, id in ipairs(dofile('res/map/terrain.lua').blockedCells) do terrain[#terrain+1] = {id%1000, id//1000} end
    local m = fixture(1000, 1000, terrain, placements)
    local target
    for _, city in ipairs(placements) do
        if city.name == '朔方隘' or city.name == '玉门关' then m.set_alliance_city_owner(city.id, 1) end
        if city.name == '潼关' then target = city end
    end
    assert(target.radius == 2, 'level 6 gate must cover the same 5x5 footprint as the client')
    assert(not m.find_march_path(9, 463, 331, 440, 331), 'uncaptured pass must not provide a route to the other region')
    local path = assert(m.find_city_approach(9, 284, 149, target), 'owned Yumen pass still provides the approach')
    misses_city(path, target)
    assert(path[#path]._x >= 449, 'approaching from Yumen must stop east of Tongguan, not behind the gate')
end

function T.alliance_cache_is_bounded_lru_and_reuses_native_buffers()
    local m, shared = fixture(40, 30, {{20, 20}}, {})
    for uid = 1, 20 do shared.ENCOUNTER_MGR.alliance_of[uid] = uid end
    local function query(uid) assert(m.find_march_path(uid, 1, 1, 10, 1)) end
    for uid = 1, 4 do query(uid) end
    local first, second, third = m.nav_of_alliance[1], m.nav_of_alliance[2], m.nav_of_alliance[3]
    query(1); query(5)
    assert(m.nav_of_alliance[1] == first and m.nav_of_alliance[2] == nil)
    assert(m.nav_of_alliance[5] == second, "LRU eviction must reuse the native allocation")
    query(2)
    assert(m.nav_of_alliance[2] == third and m.nav_of_alliance[3] == nil)
    for uid = 6, 20 do
        query(uid)
        assert(m.navigation_stats().cache_size == 4)
        assert(m.nav_of_alliance[uid]:is_obstacle({x=20,y=20}), "reuse must preserve terrain")
    end
end

function T.spatial_occupancy_handles_overlaps_moves_and_alliance_changes()
    local m, shared = fixture(40, 30, {}, {})
    shared.ENCOUNTER_MGR.alliance_of[20] = 2
    shared.ENCOUNTER_MGR.alliance_of[21] = 1
    m.set_city(20, 5, 5); m.set_city(21, 5, 5)
    assert(m.find_march_path(9, 1, 1, 10, 1))
    local nav = m.nav_of_alliance[1]
    assert(nav:is_obstacle({x=5,y=5}), "overlapping enemy footprint remains blocked")
    m.set_city(20, 15, 5)
    assert(not nav:is_obstacle({x=5,y=5}) and nav:is_obstacle({x=15,y=5}))
    assert(m.city_of(15,5) == 20 and m.city_of(5,5) == 21)
    shared.ENCOUNTER_MGR.alliance_of[20] = 1
    m.on_user_alliance(20, 2, 1)
    assert(not nav:is_obstacle({x=15,y=5}))
    shared.ENCOUNTER_MGR.alliance_of[20] = nil
    m.on_user_alliance(20, 1, nil)
    assert(nav:is_obstacle({x=15,y=5}))
    m.set_city(21, 25, 5)
    assert(m.city_of(5,5) == nil and not nav:is_obstacle({x=5,y=5}))
    m.set_city(22,39,0)
    assert(m.city_of(-1,1)==nil and m.city_of(40,0)==nil, "outside coordinates cannot alias the spatial index")
end

function T.lru_permission_deltas_preserve_moves_membership_and_gate_ownership()
    local gate = {id=701,x=25,y=5,radius=1}
    local m, shared = fixture(45,30,{{20,20}},{gate})
    for uid=1,12 do shared.ENCOUNTER_MGR.alliance_of[uid]=uid end
    m.set_city(1,15,5); m.set_city(2,5,5)
    local function query(uid) assert(m.find_march_path(uid,1,1,10,1)); return m.nav_of_alliance[uid] end
    local first=query(1)
    assert(not first:is_obstacle({x=15,y=5}) and first:is_obstacle({x=5,y=5}))
    for uid=2,5 do query(uid) end
    local fifth=m.nav_of_alliance[5]
    assert(fifth==first and fifth:is_obstacle({x=15,y=5}), "eviction must close old alliance's cells")
    m.set_alliance_city_owner(701,5)
    assert(not fifth:is_obstacle({x=25,y=5}))
    m.set_city(1,35,5)
    assert(not fifth:is_obstacle({x=15,y=5}) and fifth:is_obstacle({x=35,y=5}))
    for uid=6,9 do query(uid) end
    assert(m.nav_of_alliance[9]==fifth and fifth:is_obstacle({x=25,y=5}), "new alliance cannot inherit old gate access")
    shared.ENCOUNTER_MGR.alliance_of[2]=1
    m.on_user_alliance(2,2,1)
    m.set_alliance_city_owner(701,1)
    local rebuilt=query(1)
    for _,x in ipairs({5,25,35}) do assert(not rebuilt:is_obstacle({x=x,y=5})) end
    assert(rebuilt:is_obstacle({x=20,y=20}) and m.navigation_stats().cache_size==4)
end

function T.native_ignore_setup_failure_does_not_erase_own_city_obstacles()
    local terrain={}
    for y=0,29 do for x=0,29 do
        if math.abs(x-15)>1 or math.abs(y-15)>1 then terrain[#terrain+1]={x,y} end
    end end
    local m=fixture(30,30,terrain,{})
    m.set_city(99,15,15)
    local ok,err=pcall(m.find_march_path,99,15,15,0,0)
    assert(not ok and tostring(err):find("get_neighbor_area_id failed",1,true))
    for y=14,16 do for x=14,16 do assert(m.nav_alone:is_obstacle({x=x,y=y})) end end
    assert(m.nav_alone:is_obstacle({x=0,y=0}))
end

function T.departure_permission_rolls_back_on_yield_rpc_and_reentry()
    local m, shared = gate_fixture()
    assert(not m.find_march_path(9, 2, 5, 18, 5))
    local nav, old = m.nav_of_alliance[1], m.nav_of_alliance[1].find_path
    local injections = {
        function() coroutine.yield("invalid suspension") end,
        function() shared.skynet.sleep(1) end,
        function() m.find_march_path(9, 2, 5, 18, 5) end,
        function() m.set_alliance_city_owner(101, 1) end,
        function() error("native path error") end,
        function(self, ...) old(self, ...); error("Lua error after native search") end,
    }
    for _, inject in ipairs(injections) do
        nav.find_path = inject
        local ok = pcall(m.find_march_path, 9, 10, 5, 2, 5)
        nav.find_path = old
        assert(not ok, "suspended/reentrant navigation must fail immediately")
        assert(not m.find_march_path(9, 2, 5, 18, 5), "departure exception leaked a permanent passage")
        assert(m.find_march_path(9, 10, 5, 2, 5), "error must release the navigation guard")
    end
end

return T
