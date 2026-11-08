-- 使用真实 navigation C/JPS，验证占领通行与攻城停靠，不修改玩家数据。
local T = {}
local navigation = require 'navigation'
local siege = require 'city_siege'

local function fixture(w, h, obstacles, cities)
    local blocked = {}
    for _, p in ipairs(obstacles) do blocked[p[2] * w + p[1] + 1] = true end
    local shared = {ENCOUNTER_MGR = {alliance_of = {[9] = 1, [10] = 2}}, require = function(name)
        if name == 'skynet' then return {} end
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

return T
