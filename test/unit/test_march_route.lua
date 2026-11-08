-- 执行真实 agent 请求处理器；所有写操作一旦发生立即使测试失败。
local T = {}
local function load_mod(path, shared)
    local env = setmetatable({}, {__index = function(_, k) return shared[k] or _G[k] end})
    assert(loadfile(path, 't', env))()
    return env
end
local function fixture()
    local F = {state = 0, troop_state = 0, calls = {}, replies = {}, online = true}
    local function no_write() error('preview performed a mutation') end
    local user = {get_user_id = function() return 9 end, has_birth_pos = function() return true end,
        get_birth_x = function() return 10 end, get_birth_y = function() return 20 end}
    local troop = {get_march_state = function() return F.state end,
        get_troop_state = function() return F.troop_state end, has_hero = function() return true end,
        get_end_pos = function() return 12, 23 end,
        calc_pos = function(_, now) assert(now == 100); return 10.25, 21.75 end,
        set_march = no_write, clear_march = no_write, is_gathering = no_write}
    local sky = {localname = function() return '.world' end, error = function() end,
        call = function(_, _, cmd, ...)
            assert(cmd == 'find_march_route', 'unexpected world operation: ' .. cmd)
            local args = {...}; F.calls[#F.calls + 1] = args
            if F.disconnect then F.online = false end
            if F.throw then error('world unavailable') end
            if F.blocked then return nil end
            return {{_x = args[2], _y = args[3]}, {_x = args[2] + 1, _y = args[3] + 1}}
        end}
    local shared = {require = function(name) if name == 'skynet' then return sky end; return require(name) end,
        USER_MGR = {get_user_by_fd = function(fd) return fd == 7 and F.online and user or nil end},
        TROOP_MGR = {get_troop = function(uid, idx) if uid == 9 and idx == 2 then return troop end end},
        CONST = {MARCH_STATE = {MOVING = 1, ARRIVED = 2}, EVENT = {ON_USER_LOGIN = 1}}, TIME = {now = function() return 100 end},
        DATA_COMMON = {TARGET_TYPE = {RETURN_CITY = 1, ATTACK_CITY = 5, REDEPLOY = 6}, TROOP_STATE = {SIEGE = 4},
            get_march_speed = function(kind) return kind == 6 and 1.2 or kind == 1 and 1 or .6 end},
        MONGO_SLAVE = {flush_sync = no_write}, EVENT = {listen = function() end, dispatch = no_write},
        for_maker = {}, for_caller = {s2c_req_march_route = function(fd, reply)
            assert(fd == 7); F.replies[#F.replies + 1] = reply end}}
    shared.MARCH_PATH = load_mod('common/march_path.lua', {})
    local mod = load_mod('logic/service/agent/module/march/mgr.lua', shared); mod.__init__()
    F.request = function(packet) shared.for_maker.c2s_req_march_route(7, packet or {
        troopIdx = 2, targetType = 4, targetPos = {x = 40, y = 50}}) end
    return F
end
function T.origin_and_cost_all_states_without_mutation()
    for _, row in ipairs({{0, 0, 10, 20}, {1, 1, 10.25, 21.75}, {2, 2, 12, 23}, {2, 3, 12, 23}}) do
        local f = fixture(); f.state, f.troop_state = row[1], row[2]; f.request()
        local r = f.replies[1]
        assert(r.troopIdx == 2 and r.targetType == 4 and r.targetPos.x == 40 and r.targetPos.y == 50)
        assert(r.path[1].x == row[3] and r.path[1].y == row[4], 'origin must be current position')
        assert(math.abs(r.costTime - math.sqrt(2) / .6) < 1e-8, 'costTime must retain fractional seconds')
    end
end
function T.redeploy_preview_is_twice_normal_speed()
    local f = fixture(); f.request(); local normal = f.replies[1].costTime
    f.request({troopIdx=2,targetType=6,targetPos={x=40,y=50}})
    assert(math.abs(f.replies[2].costTime * 2 - normal) < 1e-8)
end
function T.invalid_target_or_foreign_troop_does_not_pathfind()
    for _, packet in ipairs({{troopIdx=99,targetType=4,targetPos={x=1,y=1}},
        {troopIdx=2,targetType=99,targetPos={x=1,y=1}}, {troopIdx=2,targetType=4},
        {troopIdx=2,targetType=4,targetPos={x=-1,y=1}}, {troopIdx=2,targetType=4,targetPos={x=1000,y=1}},
        {troopIdx=2,targetType=4,targetPos={x=1.5,y=1}}}) do
        local f = fixture(); f.request(packet)
        assert(#f.calls == 0 and #f.replies == 1 and #f.replies[1].path == 0 and f.replies[1].costTime == 0)
    end
end
function T.siege_only_allows_return_preview_without_settlement()
    local f = fixture(); f.state, f.troop_state = 2, 4; f.request(); assert(#f.calls == 0)
    f.request({troopIdx=2,targetType=1,targetPos={x=10,y=20}})
    assert(#f.calls == 0 and math.abs(f.replies[2].costTime - math.sqrt(13)) < 1e-8)
end
function T.unreachable_and_world_failure_return_empty_reply()
    for _, reason in ipairs({'blocked', 'throw'}) do
        local f = fixture(); f[reason] = true; f.request()
        assert(#f.replies == 1 and #f.replies[1].path == 0 and f.replies[1].costTime == 0)
    end
end
function T.disconnected_during_pathfinding_discards_reply()
    local f = fixture(); f.disconnect = true; f.request(); assert(#f.replies == 0)
end

function T.city_preview_uses_same_approach_as_dispatch_and_enforces_ownership()
    local result, dispatch, approach_calls, ordinary_calls, alliance = nil, nil, 0, 0, 4
    local sky = {call = function() return {id = alliance} end, start = function(fn) fn() end,
        dispatch = function(_, fn) dispatch = fn end, register = function() end,
        pack = function(value) return value end, ret = function(value) result = value end}
    local shared = {require = function(name)
        if name == 'skynet' or name == 'skynet.manager' then return sky end
        if name == 'skynet.queue' then return function() return function(fn) return fn() end end end
        return require(name)
    end, DATA_COMMON = {TARGET_TYPE = {ATTACK_CITY = 5, REDEPLOY = 6}},
        cities = {[501] = {id=501,x=40,y=50,radius=3}}, states = {[501] = {alliance_id=0,round=1}},
        LOG = {_debug = function() end}, dofile = function() end,
        MAP_MGR = {find_city_approach = function(uid,sx,sy,city)
            assert(uid == 9 and sx == 10.25 and sy == 21.75 and city.radius == 3)
            approach_calls = approach_calls + 1; return {{_x=sx,_y=sy},{_x=36,_y=50}}
        end, find_march_path = function() ordinary_calls = ordinary_calls + 1; return {{_x=10,_y=20},{_x=40,_y=50}} end}}
    shared.CITY_MGR = load_mod('logic/service/world/module/city/mgr.lua', shared)
    load_mod('logic/service/world/world.lua', shared)
    dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,5)
    assert(result[2]._x == 36 and approach_calls == 1 and ordinary_calls == 0, 'preview must stop outside walls')
    dispatch(1,0,'find_city_march_path',9,10.25,21.75,501)
    assert(result[2]._x == 36 and approach_calls == 2, 'preview and dispatch must share approach')
    dispatch(1,0,'find_march_route',9,10.25,21.75,41,50,5); assert(result == nil, 'unknown center')
    alliance = 0; dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,5); assert(result == nil, 'no alliance')
    alliance = 4; shared.states[501].alliance_id = 4
    dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,5); assert(result == nil, 'own alliance city')
    dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,4); assert(ordinary_calls == 1)
    dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,6); assert(ordinary_calls == 2)
    dispatch(1,0,'find_redeploy_path',9,10.25,21.75,501,1); assert(ordinary_calls == 3)
    dispatch(1,0,'find_redeploy_path',9,10.25,21.75,501,2); assert(result == nil)
    alliance=0; dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,6); assert(result == nil)
    alliance=9; dispatch(1,0,'find_march_route',9,10.25,21.75,40,50,6); assert(result == nil)
    assert(ordinary_calls == 3, 'invalid ownership must not enter pathfinding')
end
function T.return_preview_is_direct_even_when_navigation_has_no_route()
    local f=fixture(); f.state=1; f.blocked=true
    f.request({troopIdx=2,targetType=1,targetPos={x=999,y=999}})
    local r=f.replies[1]
    assert(#f.calls==0 and #r.path==2, 'return preview must bypass world navigation')
    assert(r.path[1].x==10.25 and r.path[1].y==21.75, 'retain current fractional position')
    assert(r.path[2].x==10 and r.path[2].y==20, 'server home overrides client coordinates')
    assert(math.abs(r.costTime-math.sqrt(.25^2+1.75^2))<1e-8)
end

function T.protobuf_roundtrip_matches_new_contract()
    local pb = require 'protobuf'
    pb.register_file('game_common/pb/common.pb'); pb.register_file('game_common/pb/world.pb')
    local request = {troopIdx=2,targetType=5,targetPos={x=40,y=50}}
    local back = pb.decode('World.c2s_req_march_route',pb.encode('World.c2s_req_march_route',request))
    assert(back.troopIdx==2 and back.targetType==5 and back.targetPos.x==40)
    request.path={{x=12.25,y=20.5},{x=36,y=50}};request.costTime=16.25
    back=pb.decode('World.s2c_req_march_route',pb.encode('World.s2c_req_march_route',request))
    assert(back.path[1].x==12.25 and back.costTime==16.25)
end
return T
