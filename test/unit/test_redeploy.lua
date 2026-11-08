local T, siege = {}, require 'city_siege'
local function load_mod(path, shared)
    local env = setmetatable({}, {__index = function(_, k) return shared[k] or _G[k] end})
    assert(loadfile(path, 't', env))()
    return env
end

-- Real agent handlers, troop methods, world dispatcher, city ledger and protobuf.
-- Only RPC/clock/storage are isolated; a battle call is always a test failure.
local function fixture(saved, troop_doc)
    local F = {now=100, members={[9]=4,[10]=4}, writes={}, pushes={}, timers={}, starts={}, notices={}, parks=0, flushes=0}
    local conf = {TeamCount=5, Durability=20000}
    local state = siege.new(conf); state.alliance_id, state.round = 4, 2
    F.saved = saved or {[501]=state}
    local doc = troop_doc or {_troops={}}
    F.doc = doc
    local sky, dispatch, result = {}, nil, nil
    local shared = {
        CONST={MARCH_STATE={MOVING=1,ARRIVED=2}, EVENT={ON_USER_LOGIN=1,ON_MARCH=2}},
        DATA_COMMON={TARGET_TYPE=dofile('game_common/server/enum/TargetTypeEnum.lua'),
            TROOP_STATE=dofile('game_common/server/enum/TroopStateEnum.lua'), get_city_conf=function() return conf end,
            get_march_speed=function(kind) return kind==6 and 1.2 or kind==1 and 1 or .6 end},
        TIME={now=function() return F.now end, os_bj_sec=function() return F.now end},
        LOG={_debug=function() end}, dofile=function() end, cls_object={Inherit=function() return {} end},
        require=function(name)
            if name=='skynet' or name=='skynet.manager' then return sky end
            if name=='skynet.queue' then return function() return function(fn) return fn() end end end
            return require(name)
        end,
        MONGO_SLAVE={COL={CITY='city',USER_TROOP='troop'},
            common_load_tbl=function(kind) return kind=='city' and siege.copy(F.saved) or {[9]=doc} end,
            save_doc=function(_,id,data) F.writes[id]=siege.copy(data) end,
            flush_sync=function() F.flushes=F.flushes+1; if F.fail_db then error('db unavailable') end end},
        MAP_MGR={set_alliance_city_owner=function() end,alliance_cities={{id=501,x=12,y=0,city_type=4,level=5,name='试验关'}}},
        ENCOUNTER_MGR={alliance_of=F.members, set_user_alliance=function(uid,aid) F.members[uid]=aid end},
        AOI_MGR={upsert_alliance_city=function() end, city_watchers=function() return {[77]=true} end,
            start_march=function(info) F.starts[#F.starts+1]=siege.copy(info); return not F.fail_start end,
            park_troop=function(_,_,x,y) assert(x==12 and y==0); F.parks=F.parks+1 end,
            hide_troop=function() end, remove_troop=function() end},
        BATTLE_MGR=setmetatable({}, {__index=function() return function() error('redeploy entered battle') end end}),
        EVENT={listen=function() end,dispatch=function() end}, for_maker={},
        for_caller=setmetatable({}, {__index=function(_,name) return function(_,packet)
            F.pushes[#F.pushes+1]={name=name,packet=packet} end end}),
    }
    shared.MARCH_PATH=load_mod('common/march_path.lua',{})
    shared.MAP_MGR.find_march_path=function(_,sx,sy,ex,ey)
        if F.fail_path then return nil end
        return {{_x=sx,_y=sy},{_x=ex,_y=ey}}
    end
    function F.world(cmd,...)
        dispatch(1,0,cmd,...)
        return table.unpack(result,1,result.n)
    end
    sky.start=function(fn) fn() end; sky.dispatch=function(_,fn) dispatch=fn end
    sky.register=function() end; sky.pack=table.pack; sky.ret=function(r) result=r end
    sky.localname=function() return '.world' end; sky.self=function() return 'agent' end
    sky.timeout=function(_,fn) F.timers[#F.timers+1]=fn end; sky.error=function() end
    sky.send=function(_,_,cmd,uid,name,packet) F.pushes[#F.pushes+1]={name=name,packet=packet,uid=uid} end
    sky.call=function(service,_,cmd,...)
        local args={...}
        if service=='.world' then
            local reply=table.pack(F.world(cmd,...))
            if cmd=='arrive_redeploy' and F.after_arrival then
                local hook=F.after_arrival; F.after_arrival=nil; hook()
            end
            return table.unpack(reply,1,reply.n)
        end
        if cmd=='public_user_alliance' then return {id=F.members[args[1]] or 0} end
        if cmd=='city_audience' then return {9,10} end
        if cmd=='get_agent_list' then return {'agent'} end
        error('unexpected RPC '..cmd)
    end
    shared.CITY_MGR=load_mod('logic/service/world/module/city/mgr.lua',shared)
    shared.CITY_MGR.init()
    load_mod('logic/service/world/world.lua',shared)
    local base=load_mod('logic/service/agent/module/troop/base.lua',shared).cls_troop
    if not doc._troops[1] then
        doc._troops[1]={_user_id=9,_troop_idx=1,_troop_state=0,_march_serial=0,_siege_city=0,_siege_seq=0,_siege_round=0,_redeploy_round=0,
            _pos_tbl={[0]={_hero_idx=1001,_soldier_cnt=100,_hurt_cnt=0}},
            _march={_state=0,_target_type=0,_target_id=0,_path={},_start_time=0,_end_time=0}}
    end
    local troop=setmetatable({_data=doc._troops[1]}, {__index=base})
    local user={get_user_id=function() return 9 end,get_fd=function() return 7 end,has_birth_pos=function() return true end,
        get_birth_x=function() return 0 end,get_birth_y=function() return 0 end}
    shared.USER_MGR={try_init_user=function() return user end,get_user_by_fd=function() return user end,
        get_fd_by_user_id=function() return 7 end,get_user_id_by_fd=function() return 9 end,
        sync_city_aoi=function() end,tell_me=function(_,notice) F.notices[#F.notices+1]=notice end}
    shared.TROOP_MGR={get_troop=function(_,idx) return idx==1 and troop end,get_user_troops=function() return {troop} end}
    shared.MARCH_MGR=load_mod('logic/service/agent/module/march/mgr.lua',shared)
    shared.MARCH_MGR.__init__()
    F.C, F.S, F.troop = shared.CITY_MGR, shared, troop
    F.count=function() return F.C.info(501).cityInfo.deployCount end
    F.order=function(kind,id,pos) shared.for_maker.c2s_march(7,{troopIdx=1,targetType=kind or 6,targetId=id or 501,targetPos=pos or {x=999,y=999}}) end
    F.arrive=function() F.now=troop:get_end_time(); shared.MARCH_MGR.on_arrive(9,1,F.now) end
    return F
end

function T.agent_dispatch_arrival_relogin_and_departure_use_new_contract()
    local f=fixture(); f.order()
    local t=f.troop
    assert(t:get_target_type()==6 and t:get_target_id()==501 and t:get_troop_state()==1)
    assert(t:get_end_pos()==12 and t:get_end_time()==110, 'server city overrides forged client coordinate; speed 1.2')
    assert(f.count()==0 and #f.starts==1, 'travel is not counted')
    f.S.MARCH_MGR.on_arrive(9,1,110); assert(f.count()==0, 'early arrival ignored')
    f.arrive(); assert(f.count()==1 and t:get_march_state()==2 and t:get_troop_state()==2)
    assert(t:get_target_type()==6 and t:get_target_id()==501)
    local before=f.C.info(501).cityInfo
    f.arrive(); f.S.MARCH_MGR.on_user_login(9)
    assert(f.count()==1 and f.C.info(501).cityInfo.teamLeft==5 and before.durability==20000)
    local serial=t._data._march_serial
    f.order(); assert(t._data._march_serial==serial, 'duplicate command must not leave/re-enter')
    f.order(4,0,{x=24,y=0})
    assert(f.count()==0 and t:get_march_info().path[1]._x==12, 'next march originates at deployed city')
end

function T.failed_dispatch_keeps_deployment_and_recall_removes_it()
    local f=fixture(); f.order(); f.arrive()
    local old=f.troop:get_march_info()
    f.fail_start=true; f.order(4,0,{x=24,y=0})
    assert(f.count()==1 and f.troop:get_march_state()==2 and f.troop:get_target_type()==6)
    assert(f.troop._data._march_serial==old.serial and f.troop:get_end_pos()==12)
    f.fail_start=false; f.order(1,0,{x=0,y=0})
    assert(f.count()==0 and f.troop:get_target_type()==1)
    assert(not f.C.arrive_redeploy(old), 'late arrival cannot revive a departed deployment')
end

function T.two_troops_count_once_each_and_leave_alliance_invalidates_old_receipts()
    local f=fixture(); f.order(); f.arrive()
    local other=f.troop:get_march_info(); other.user_id=10; other.troop_idx=2
    assert(f.C.arrive_redeploy(other)); assert(f.C.arrive_redeploy(other)); assert(f.count()==2)
    local old=f.troop:get_march_info()
    f.world('set_user_alliance',9,0); assert(f.count()==1)
    f.world('set_user_alliance',9,4); assert(not f.C.arrive_redeploy(old)); assert(f.count()==1)
    f.C.leave_redeploy(10,2); assert(f.count()==0)
    assert(not f.C.arrive_redeploy(other))
    other.serial=other.serial+1; assert(f.C.arrive_redeploy(other)); assert(f.count()==1)
end

function T.ownership_change_clears_counts_and_rejects_even_recaptured_city()
    local f=fixture(); f.order(); f.arrive()
    local old=f.troop:get_march_info()
    local s=f.C.states[501]; s.team_left=0; s.durability=1
    siege.settle(s,{Durability=20000,TeamCount=5}, {uid=12,name='敌方',alliance={id=8,name='敌盟'}},0,true)
    assert(f.count()==0 and s.alliance_id==8 and s.round==3)
    assert(not f.C.arrive_redeploy(old))
    s.alliance_id=4; s.round=4
    assert(not f.C.arrive_redeploy(old), 'matching alliance alone cannot revive an old epoch')
end

function T.changed_owner_on_way_returns_without_battle_and_invalid_targets_do_not_start()
    local f=fixture()
    for _,aid in ipairs({0,8}) do f.C.states[501].alliance_id=aid; f.order(); assert(#f.starts==0) end
    f.C.states[501].alliance_id=4; f.order(6,999); assert(#f.starts==0)
    f.order(); f.C.states[501].alliance_id=8; f.C.states[501].round=3
    f.arrive(); assert(f.count()==0 and f.troop:get_target_type()==1)
end

function T.restart_recovers_only_current_arrived_allied_troops()
    local f=fixture(); f.order(); f.arrive()
    local saved, doc = siege.copy(f.writes), siege.copy(f.doc)
    local restarted=fixture(saved,doc); assert(restarted.count()==1)
    restarted.S.MARCH_MGR.on_user_login(9); assert(restarted.count()==1)
    for _,kind in ipairs({'moving','target','serial','round'}) do
        local copy=siege.copy(doc); local t=copy._troops[1]
        if kind=='moving' then t._march._state=1 elseif kind=='target' then t._march._target_type=4
        elseif kind=='serial' then t._march_serial=t._march_serial+1 else t._redeploy_round=1 end
        local r=fixture(saved,copy); assert(r.count()==0, 'restart failed to reconcile '..kind)
    end
end

function T.database_failure_retries_arrival_without_double_count()
    local f=fixture(); f.order(); f.fail_db=true; f.arrive()
    assert(f.count()==0 and #f.timers>0)
    f.fail_db=false; f.arrive(); f.arrive(); assert(f.count()==1)
end

function T.moving_cancel_uses_current_path_position_and_stale_arrival_is_ignored()
    local f=fixture(); f.order(); local old_end=f.troop:get_end_time(); f.now=105
    f.S.for_maker.c2s_cancel_march(7,{troopIdx=1})
    assert(f.troop:get_target_type()==1 and f.count()==0)
    assert(math.abs(f.troop:get_march_info().path[1]._x-6)<1e-8)
    f.S.MARCH_MGR.on_arrive(9,1,old_end); assert(f.count()==0)
end

function T.stationed_return_ignores_blocked_navigation_and_client_target()
    local f=fixture(); f.order(); f.arrive()
    f.S.MAP_MGR.find_march_path=function() error('return invoked navigation') end
    f.order(1,0,{x=999,y=999})
    local path=f.troop:get_march_info().path
    assert(f.troop:get_target_type()==1 and #path==2 and f.count()==0)
    assert(path[1]._x==12 and path[1]._y==0 and path[2]._x==0 and path[2]._y==0)
    assert(f.troop:get_end_time()-f.troop:get_start_time()==12)
    f.arrive(); assert(f.troop:get_march_state()==0 and f.troop:get_troop_state()==0)
end

function T.moving_recall_is_a_direct_line_from_fractional_current_position()
    local f=fixture(); f.order(); f.now=104.25
    f.S.MAP_MGR.find_march_path=function() error('recall invoked navigation') end
    f.S.for_maker.c2s_cancel_march(7,{troopIdx=1})
    local path=f.troop:get_march_info().path
    assert(f.troop:get_target_type()==1 and #path==2)
    assert(math.abs(path[1]._x-5.1)<1e-8 and path[1]._y==0)
    assert(path[2]._x==0 and path[2]._y==0)
end

function T.invalidated_redeploy_returns_even_when_all_navigation_is_blocked()
    local f=fixture(); f.order(); f.C.states[501].alliance_id=8; f.C.states[501].round=3
    f.S.MAP_MGR.find_march_path=function() error('automatic return invoked navigation') end
    f.arrive()
    assert(f.troop:get_target_type()==1 and #f.troop:get_march_info().path==2)
end

function T.delayed_capture_notification_cannot_revert_deploy_count()
    local f=fixture(); f.order(); f.arrive()
    f.C.states[501].outbox['1']={round=1,rankList={{uid=9,rank=1}},rewards={},breakUid=9,breakName='盟友',
        cityInfo={entityId=501,deployCount=0}}
    f.C.retry_rewards()
    local found=false
    for _,p in ipairs(f.pushes) do
        if p.name=='s2c_city_occupy' then
            found=true; assert(p.packet.cityInfo.deployCount==1 and p.packet.cityInfo.teamLeft==5)
        end
    end
    assert(found)
end

function T.late_arrival_response_does_not_replace_new_order()
    local f=fixture(); f.order()
    f.C.states[501].alliance_id=8
    f.after_arrival=function() f.order(4,0,{x=24,y=0}) end
    f.arrive()
    assert(f.troop:get_target_type()==4 and f.troop:get_end_pos()==24, 'late rejected arrival must not force-return the new order')
end

function T.aoi_late_park_does_not_stop_a_newer_march()
    local shared={CONST={AOI_RADIUS=10,troop_entity_id=function(uid,idx) return uid*100+idx end},
        DATA_COMMON={ENTITY_TYPE={TROOP=2},TROOP_STATE={MARCH=1,STAY=2}},
        MARCH_PATH=load_mod('common/march_path.lua',{}), TIME={now=function() return 100 end}, agent_list={},
        ENCOUNTER_MGR={unindex=function() end,index_at=function() end,touch=function() end,clear_flee=function() end},
        require=function(name) if name=='skynet' then return {} end; return require(name) end}
    local aoi=load_mod('logic/service/world/module/aoi/mgr.lua',shared)
    assert(aoi.start_march({user_id=9,troop_idx=1,target_type=4,serial=2,
        path={{_x=12,_y=0},{_x=24,_y=0}},start_time=100,end_time=120}))
    aoi.park_troop(9,1,12,0,1)
    assert(#aoi.get_march_path(9,901)==2, 'old arrival must not clear the new AOI path')
    aoi.park_troop(9,1,24,0,2)
    assert(#aoi.get_march_path(9,901)==0)
end

function T.deploy_count_and_target_type_survive_real_wire_encoding()
    local pb=require 'protobuf'
    pb.register_file('game_common/pb/common.pb'); pb.register_file('game_common/pb/city.pb'); pb.register_file('game_common/pb/world.pb')
    local packet={cityInfo={entityId=5000000000269522,allianceId=4,deployCount=3,teamLeft=6,teamCount=6}}
    local back=pb.decode('City.s2c_sync_city',pb.encode('City.s2c_sync_city',packet))
    assert(back.cityInfo.deployCount==3 and back.cityInfo.teamLeft==6)
    back=pb.decode('World.c2s_march',pb.encode('World.c2s_march',{troopIdx=1,targetType=6,targetId=packet.cityInfo.entityId,targetPos={x=522,y=269}}))
    assert(back.targetType==6 and back.targetId==packet.cityInfo.entityId)
end
return T
