-- Real world user/AOI modules: connection changes invalidate only the view.
local function noop() end

local function load_module(path, env)
    env = setmetatable(env or {}, {__index = _G})
    assert(loadfile(path, "t", env))()
    return env
end

local function fixture()
    local skynet = {send=noop, error=noop, getenv=noop, hpc=function() return 0 end}
    local function req(name)
        if name == "skynet" then return skynet end
        return require(name)
    end
    local A = load_module("logic/service/world/module/aoi/mgr.lua", {
        require=req,
        agent_list={"agent"},
        CONST=load_module("logic/define/const.lua"),
        MARCH_PATH=load_module("common/march_path.lua"),
        DATA_COMMON={TROOP_STATE={MARCH=1, STAY=2, SIEGE=4}, ENTITY_TYPE={CITY=1, TROOP=2}},
        TIME={now=function() return 0 end},
        ENCOUNTER_MGR={unindex=noop, index_at=noop, touch=noop},
    })
    local U = load_module("logic/service/world/module/user/mgr.lua", {
        require=req, LOG={_debug=noop}, AOI_MGR=A,
    })
    A.upsert_city(8, 1, 0, {name="city", level=1})
    A.start_march({user_id=8, troop_idx=1, serial=17, target_type=5,
        path={{_x=0,_y=0},{_x=4,_y=0}}, start_time=0, end_time=10})
    U.on_user_login(8, 101, "gate-old", false)
    assert(#A.focus(8, 0, 0).enter == 2)
    return U, A
end

local T = {}

function T.same_connection_login_preserves_seen_and_watchers()
    local U, A = fixture()
    local focus = A.runtime.focus_tbl[8]
    U.on_user_login(8, 101, "gate-old", false)
    assert(A.runtime.focus_tbl[8] == focus)
    assert(A.city_watchers(A.CONST.city_entity_id(8))[8])
    local diff = A.focus(8, 0, 0)
    assert(#diff.enter == 0 and #diff.leave == 0)
    assert(U.get_fd_by_user_id(8) == 101 and U.get_user_id_by_fd(101) == 8)
end

function T.changed_connection_receives_full_initial_view_without_resetting_march()
    local U, A = fixture()
    local id = A.CONST.troop_entity_id(8, 1)
    local troop = A.runtime.entities[id]
    local path = troop.path
    U.on_user_login(8, 202, "gate-new", false)
    assert(A.runtime.focus_tbl[8] == nil)
    assert(not A.city_watchers(A.CONST.city_entity_id(8))[8])
    assert(U.get_user_id_by_fd(101) == nil and U.get_gate_srv_by_fd(101) == nil)
    assert(U.get_fd_by_user_id(8) == 202 and U.get_user_id_by_fd(202) == 8)
    assert(U.get_gate_srv_by_fd(202) == "gate-new")
    assert(A.runtime.entities[id] == troop and A.runtime.active_movers[id] == troop)
    assert(troop.moving and troop.path == path and troop.march_serial == 17)
    local diff = A.focus(8, 0, 0)
    assert(#diff.enter == 2 and #diff.leave == 0)
    local seen = {}
    for _, entity in ipairs(diff.enter) do seen[entity.entityId] = entity end
    assert(seen[A.CONST.city_entity_id(8)] and seen[id].path)
    assert(A.city_watchers(A.CONST.city_entity_id(8))[8])
end

function T.old_connection_logout_or_kick_does_not_clear_the_new_view()
    for _, command in ipairs({"on_user_logout", "kick_user", "disconnect"}) do
        local U, A = fixture()
        U.on_user_login(8, 202, "gate-new", false)
        assert(#A.focus(8, 0, 0).enter == 2)
        local focus = A.runtime.focus_tbl[8]
        if command == "on_user_logout" then U[command](8, 101)
        else U[command](101, 8) end
        assert(A.runtime.focus_tbl[8] == focus, command .. " removed the new focus")
        assert(A.city_watchers(A.CONST.city_entity_id(8))[8])
        assert(U.get_fd_by_user_id(8) == 202 and U.get_user_id_by_fd(202) == 8)
        assert(U.get_gate_srv_by_fd(202) == "gate-new")
        assert(#A.focus(8, 0, 0).enter == 0)
    end
end

function T.current_connection_logout_clears_view_and_relogin_gets_full_enter()
    local U, A = fixture()
    U.on_user_logout(8, 101)
    assert(A.runtime.focus_tbl[8] == nil)
    assert(not A.city_watchers(A.CONST.city_entity_id(8))[8])
    assert(U.get_fd_by_user_id(8) == nil and U.get_user_id_by_fd(101) == nil)
    assert(U.get_gate_srv_by_fd(101) == nil)
    U.on_user_logout(8, 101) -- duplicate notification is harmless
    U.on_user_login(8, 202, "gate-new", false)
    assert(#A.focus(8, 0, 0).enter == 2)
end

return T
