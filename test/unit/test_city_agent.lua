local T = {}
local function load_module(path, shared)
    local env = setmetatable({}, {__index = function(_, key) return shared[key] or _G[key] end})
    assert(loadfile(path, "t", env))()
    return env
end

local function fixture(options)
    options=options or {}
    local saved_reports = {_reports = {}, _next_id = 0}
    local pushes, calls, timers = {}, {}, {}
    local error_at, flushes, acked = nil, 0, 0
    local now = 10
    local C = load_module("logic/define/const.lua", {})
    local march = {state = 1, target_type = 5, target_id = 501, path = {{_x = 0, _y = 0}, {_x = 8, _y = 0}},
        start_time = 1, end_time = 9}
    local troop = {_data = {_march_serial = 1, _siege_city = 0, _siege_seq = 0},
        positions = {[1] = {_hero_idx = 1001, _soldier_cnt = 100, _hurt_cnt = 10}}, troop_state = 1}
    function troop:get_user_id() return 1 end
    function troop:get_troop_idx() return 1 end
    function troop:get_target_id() return march.target_id end
    function troop:get_target_type() return march.target_type end
    function troop:get_march_state() return march.state end
    function troop:get_troop_state() return self.troop_state end
    function troop:set_troop_state(value) self.troop_state = value end
    function troop:get_start_time() return march.start_time end
    function troop:get_end_time() return march.end_time end
    function troop:get_end_pos() return march.path[#march.path]._x, march.path[#march.path]._y end
    function troop:calc_pos() return self:get_end_pos() end
    function troop:get_pos_tbl() return self.positions end
    function troop:set_pos(pos, hero, count, hurt) self.positions[pos] = {_hero_idx = hero, _soldier_cnt = count, _hurt_cnt = hurt} end
    function troop:is_gathering() return false end
    function troop:has_hero() return true end
    function troop:set_siege(start, finish) march.state=2; march.start_time=start; march.end_time=finish; self.troop_state=4 end
    function troop:next_siege_round(start,finish,city_round)
        self._data._march_serial=self._data._march_serial+1
        self._data._siege_round=city_round
        self:set_siege(start,finish)
    end
    function troop:set_arrived() march.state = 2; self.troop_state = 2 end
    function troop:get_march_info()
        return {state = march.state, target_type = march.target_type, target_id = march.target_id,
            path = march.path, start_time = march.start_time, end_time = march.end_time,
            user_id=1, troop_idx=1, serial=self._data._march_serial, redeploy_round=march.redeploy_round}
    end
    function troop:set_march(value) march = value; self._data._march_serial = self._data._march_serial + 1; self.troop_state = 1 end
    function troop:clear_march() march.state = 0 end
    function troop:get_march_pto() return {state = march.state, targetType = march.target_type, troopState = self.troop_state, endTime = march.end_time} end
    function troop:get_pto_info() return {troopIdx = 1, troopState = self.troop_state} end
    local user = {}
    function user:get_user_id() return 1 end
    function user:get_name() return "攻城者" end
    function user:get_power() return 100 end
    function user:get_fd() return 7 end
    function user:has_birth_pos() return true end
    function user:get_birth_x() return 0 end
    function user:get_birth_y() return 0 end
    local receipts={}
    local sky = {localname = function() return ".world" end, self = function() return "agent" end,
        timeout = function(_, fn) timers[#timers + 1] = fn end, error = function() end,
        send = function(_, _, cmd, ...) calls[#calls + 1] = cmd end}
    sky.call = function(_, _, cmd, ...)
        calls[#calls + 1] = cmd
        local args = {...}
        if cmd == "redeploy_target" then
            if error_at == "deployment_lookup" then error("world unavailable") end
            if options.captured or options.allied_first then return {x=10,y=0,round=2} end
            return nil, "只能调动至本盟城池"
        end
        if cmd == "arrive_redeploy" then
            if error_at == "deployment_arrival" then error("world unavailable") end
            assert(args[1].target_type==6 and args[1].state==2 and args[1].redeploy_round==2)
            return true
        end
        if cmd == "siege_troop" then if error_at=="siege" then error("AOI unavailable") end; return true end
        if cmd == "attack_city" then
            if error_at == "battle" then error("world connection lost") end
            if options.allied_first then return nil,"不能攻打本盟城池" end
            local seq=args[2].seq
            local receipt=receipts[seq]
            if not receipt then
                receipt = {seq = seq, time = 9, x = 10, y = 0, atk = args[2].side,
                    def = {owner_id = 0, name = "守军", power = 100, units = {
                        {pos = 1, cfg_id = 21, level = 1, soldier = 50, count = 50, hurt = 0}}},
                    result = {result = 1, atk_left = {[1] = 50}, def_left = {[1] = 0}, actions = {}, max_round = 1}}
                receipt.city_round=1
                receipt.continue_siege=seq<(options.rounds or 1)
                receipt.phase=(options.wall_after and seq>options.wall_after) and "wall" or "guards"
                if seq>1 then receipt.result.atk_left[1]=math.max(0,args[2].side.units[1].soldier-10) end
                if receipt.phase=="wall" then receipt.result.atk_left[1]=args[2].side.units[1].soldier end
                if options.loss_at==seq then receipt.result.result=2;receipt.continue_siege=false end
                receipts[seq]=receipt
            end
            return receipt
        end
        if cmd == "find_march_path" then
            if error_at == "path" then return end
            return {{_x = 8, _y = 0}, {_x = 0, _y = 0}}
        end
        if cmd == "start_march" then if error_at == "start_rpc" then error("start RPC lost") end; return error_at ~= "start" end
        if cmd == "ack_city_attack" then acked = acked + 1; return true end
        error("unexpected world call " .. cmd)
    end
    local shared = {CONST = C, require = function(name) if name == "skynet" then return sky end; return require(name) end,
        TIME = {now = function() return now end, os_bj_sec = function() return now end},
        MONGO_SLAVE = {COL = {USER_REPORT = "reports"}, flush_sync = function() flushes = flushes + 1 end},
        ORM = {CLS_USER_REPORT_DOC = "report", load = function() return saved_reports end},
        DATA_COMMON = {TROOP_STATE = {IN_CITY=0, MARCH=1, STAY=2, GATHER=3, SIEGE=4}, TARGET_TYPE = {ATTACK_CITY = 5, ATTACK_MONSTER = 2, OCCUPY_RES_LAND = 3, RETURN_CITY = 1, MOVE = 4, REDEPLOY=6},
            REPORT_TYPE = {ATTACK_CITY = 5}, get_march_speed = function() return 1 end},
        HERO_MGR = {get_hero_by_type = function() return {get_battle_skills = function() return {} end,
            get_level = function() return 1 end} end},
        USER_MGR = {try_init_user = function() return user end, get_fd_by_user_id = function() return 7 end,
            tell_me = function() end, get_user_by_fd = function() return user end},
        TROOP_MGR = {get_troop = function() return troop end, get_user_troops = function() return {troop} end},
        for_caller = setmetatable({}, {__index = function(_, name) return function(_, packet)
            pushes[#pushes + 1] = {name = name, packet = packet} end end}),
        for_maker = {}, EVENT = {listen = function() end},
    }
    shared.MARCH_PATH = load_module("common/march_path.lua", shared)
    shared.REPORT_MGR = load_module("logic/service/agent/module/report/mgr.lua", shared)
    shared.BATTLE_MGR = load_module("logic/service/agent/module/battle/mgr.lua", shared)
    shared.MARCH_MGR = load_module("logic/service/agent/module/march/mgr.lua", shared)
    shared.clock = function(value) now=value end
    shared.MARCH_MGR.__init__()
    return shared, troop, saved_reports, pushes, calls, timers,
        function(value) error_at = value end, function() return flushes, acked end
end

local function finish_siege(S)
    if not S.started then
        S.started = true
        S.MARCH_MGR.on_arrive(1, 1, 9)
        S.clock(15)
    end
    S.MARCH_MGR.on_arrive(1, 1, 15)
end

function T.siege_phase_is_persisted_and_synced_before_settlement()
    local S, troop, reports, pushes = fixture()
    S.MARCH_MGR.on_arrive(1, 1, 9)
    assert(troop:get_march_state()==2 and troop:get_troop_state()==4)
    assert(troop:get_end_time()==15 and troop._data._march_serial==1)
    assert(reports._next_id==0 and troop.positions[1]._soldier_cnt==100)
    assert(pushes[#pushes].packet.marchInfo.troopState==4)
    S.clock(14.99); S.MARCH_MGR.on_arrive(1,1,15)
    assert(reports._next_id==0, "未到结算时间不能提前结算")
    S.clock(15); S.MARCH_MGR.on_arrive(1,1,15)
    assert(reports._next_id==1 and troop:get_target_type()==1)
end

function T.recall_during_siege_invalidates_old_timer_without_battle()
    local S, troop, reports = fixture()
    S.MARCH_MGR.on_arrive(1,1,9)
    S.for_maker.c2s_cancel_march(7,{troopIdx=1})
    assert(troop:get_target_type()==1 and troop:get_troop_state()==1)
    S.clock(15); S.MARCH_MGR.on_arrive(1,1,15)
    assert(reports._next_id==0 and troop.positions[1]._soldier_cnt==100)
end

function T.relogin_restores_phase_without_resetting_deadline()
    local S, troop, reports = fixture()
    S.USER_MGR.sync_city_aoi=function() end
    S.MARCH_MGR.on_arrive(1,1,9)
    S.clock(12); S.MARCH_MGR.on_user_login(1)
    assert(troop:get_troop_state()==4 and troop:get_end_time()==15 and reports._next_id==0)
    S.clock(16); S.MARCH_MGR.on_user_login(1)
    assert(troop:get_target_type()==1 and reports._next_id==1)
end

function T.retarget_during_siege_is_rejected()
    local S, troop = fixture()
    S.MARCH_MGR.on_arrive(1,1,9)
    S.for_maker.c2s_march(7,{troopIdx=1,targetType=4,targetPos={x=3,y=3}})
    assert(troop:get_target_type()==5 and troop:get_end_time()==15)
end

function T.arrival_records_losses_report_then_returns_and_acks()
    local S, troop, reports, _, _, _, _, stats = fixture()
    finish_siege(S)
    assert(troop:get_target_type() == 1 and troop:get_march_state() == 1)
    assert(troop.positions[1]._soldier_cnt == 80 and troop.positions[1]._hurt_cnt == 30)
    assert(reports._next_id == 1 and reports._reports[1]._target_id == 501)
    local flushes, acked = stats()
    assert(flushes >= 4 and acked == 1)
    finish_siege(S)
    assert(reports._next_id == 1, "重复到达不重复战报或扣兵")
end

function T.post_battle_return_ignores_blocked_navigation_without_repeating_losses()
    local S, troop, reports, _, calls, _, fault = fixture()
    fault("path")
    finish_siege(S)
    assert(troop:get_target_type() == 1 and troop:get_march_state() == 1 and reports._next_id == 1)
    local path=troop:get_march_info().path
    assert(#path==2 and path[1]._x==8 and path[2]._x==0)
    for _,cmd in ipairs(calls) do assert(cmd~="find_march_path", "automatic return invoked navigation") end
    assert(troop.positions[1]._soldier_cnt == 80 and troop.positions[1]._hurt_cnt == 30)
end

function T.failed_world_start_restores_siege_identity_for_retry()
    local S, troop, reports, _, _, _, fault = fixture()
    fault("start")
    finish_siege(S)
    assert(troop:get_target_type() == 5 and troop._data._march_serial == 1 and troop:get_end_time() == 15)
    fault(nil)
    finish_siege(S)
    assert(troop:get_target_type() == 1 and reports._next_id == 1)
end

function T.return_rpc_exception_restores_siege_identity()
    local S, troop, reports, _, _, _, fault = fixture()
    fault("start_rpc"); finish_siege(S)
    assert(troop:get_target_type()==5 and troop:get_troop_state()==4 and troop._data._march_serial==1)
    fault(nil); finish_siege(S)
    assert(troop:get_target_type()==1 and reports._next_id==1 and troop.positions[1]._soldier_cnt==80)
end

function T.battle_rpc_failure_keeps_march_and_schedules_retry()
    local S, troop, reports, _, _, timers, fault = fixture()
    fault("battle")
    finish_siege(S)
    assert(troop:get_march_state() == 2 and troop:get_troop_state() == 4 and reports._next_id == 0 and #timers == 2)
    assert(troop.positions[1]._soldier_cnt == 100)
    fault(nil)
    finish_siege(S)
    assert(troop:get_target_type() == 1 and reports._next_id == 1)
end

function T.city_binary_protocol_and_aoi_alliance_roundtrip()
    local pb = require "protobuf"
    pb.register_file("game_common/pb/common.pb")
    pb.register_file("game_common/pb/world.pb")
    pb.register_file("game_common/pb/city.pb")
    local id = 5000000000123456
    local info = {entityId = id, cityType = 3, level = 8, pos = {x = 456, y = 123},
        allianceId = 77, allianceName = "山河", durability = 1001, durabilityMax = 2000, teamLeft = 2, teamCount = 4}
    local packet = {cityInfo = info, rankList = {{rank = 1, uid = 123, name = "主公", allianceId = 77, allianceName = "山河", damage = 123456}},
        breakUid = 123, breakName = "主公", rewardList = {{rewardType = 1, itemId = 4, itemCount = 100}}}
    local back = pb.decode("City.s2c_city_occupy", pb.encode("City.s2c_city_occupy", packet))
    assert(back.cityInfo.entityId == id and back.rankList[1].damage == 123456 and back.rewardList[1].itemId == 4)
    local marching = pb.decode("World.s2c_sync_march", pb.encode("World.s2c_sync_march", {marchInfo={troopIdx=1,state=2,troopState=4,targetType=5,endTime=15}}))
    assert(marching.marchInfo.state==2 and marching.marchInfo.troopState==4)
    local troop = pb.decode("World.s2c_sync_troop", pb.encode("World.s2c_sync_troop", {troopInfo={troopIdx=1,troopState=4}}))
    assert(troop.troopInfo.troopState==4)
    local siege = pb.decode("World.s2c_aoi_update", pb.encode("World.s2c_aoi_update", {entities={{entityId=99,entityType=2,troopIdx=1,troopState=4,targetId=id,targetPos={x=456,y=123},startTime=10,endTime=15}}}))
    assert(siege.entities[1].troopState==4 and siege.entities[1].targetId==id and siege.entities[1].targetPos.x==456)
    local aoi = pb.decode("World.s2c_aoi_enter", pb.encode("World.s2c_aoi_enter", {entities = {
        {entityId = id, entityType = 5, pos = info.pos, ownerId = 0, allianceId = 77, cfgId = 308, level = 8, name = "山河"}}}))
    assert(aoi.entities[1].allianceId == 77 and aoi.entities[1].entityId == id)
    for _, name in ipairs({"City.c2s_req_city_list", "City.c2s_req_city_info", "City.s2c_req_city_list", "City.s2c_req_city_info", "City.s2c_sync_city"}) do
        assert(pb.decode(name, pb.encode(name, {})))
    end
end

function T.continuous_rounds_use_new_receipt_and_relogin_keeps_deadline()
    local S,troop,reports,_,_,_,_,stats=fixture({rounds=3})
    finish_siege(S)
    assert(troop:get_target_type()==5 and troop:get_troop_state()==4 and troop:get_end_time()==20)
    assert(troop._data._march_serial==2 and troop._data._siege_round==1 and reports._next_id==1)
    assert(troop.positions[1]._soldier_cnt==80 and troop.positions[1]._hurt_cnt==30)
    S.MARCH_MGR.on_arrive(1,1,15)
    assert(reports._next_id==1, "上一轮定时器不能重复结算")
    S.USER_MGR.sync_city_aoi=function() end
    S.clock(18);S.MARCH_MGR.on_user_login(1)
    assert(troop:get_end_time()==20 and reports._next_id==1)
    S.clock(20);S.MARCH_MGR.on_arrive(1,1,20)
    assert(troop:get_end_time()==25 and reports._next_id==2 and troop._data._march_serial==3)
    assert(troop.positions[1]._soldier_cnt==75 and troop.positions[1]._hurt_cnt==35)
    S.MARCH_MGR.on_arrive(1,1,20)
    assert(reports._next_id==2 and troop.positions[1]._soldier_cnt==75)
    S.clock(25);S.MARCH_MGR.on_arrive(1,1,25)
    assert(troop:get_target_type()==1 and reports._next_id==3)
    local _,acked=stats();assert(acked==3)
end

function T.recall_between_rounds_does_not_start_another_battle()
    local S,troop,reports=fixture({rounds=3})
    finish_siege(S)
    S.clock(18);S.for_maker.c2s_cancel_march(7,{troopIdx=1})
    assert(troop:get_target_type()==1 and reports._next_id==1)
    S.clock(20);S.MARCH_MGR.on_arrive(1,1,20)
    assert(reports._next_id==1 and troop.positions[1]._soldier_cnt==80)
end

function T.wall_ticks_do_not_create_empty_battle_reports()
    local S,troop,reports=fixture({rounds=3,wall_after=1})
    finish_siege(S)
    S.clock(20);S.MARCH_MGR.on_arrive(1,1,20)
    assert(troop:get_target_type()==5 and reports._next_id==1)
    S.clock(25);S.MARCH_MGR.on_arrive(1,1,25)
    assert(troop:get_target_type()==1 and reports._next_id==1 and troop.positions[1]._soldier_cnt==80)
end

function T.loss_stops_continuous_siege()
    local S,troop,reports=fixture({rounds=5,loss_at=2})
    finish_siege(S)
    S.clock(20);S.MARCH_MGR.on_arrive(1,1,20)
    assert(troop:get_target_type()==1 and reports._next_id==2)
end

function T.presentation_failure_preserves_next_round_and_previous_losses()
    local S,troop,reports,_,_,_,fault=fixture({rounds=3})
    finish_siege(S)
    fault("siege");S.clock(18);S.MARCH_MGR.on_arrive(1,1,20)
    assert(troop._data._march_serial==2 and reports._next_id==1)
    fault(nil);S.clock(20);S.MARCH_MGR.on_arrive(1,1,20)
    assert(troop._data._march_serial==3 and reports._next_id==2 and troop.positions[1]._soldier_cnt==75)
end

function T.captured_city_keeps_troop_deployed_instead_of_starting_return()
    local S,troop,reports,pushes,calls=fixture({captured=true})
    finish_siege(S)
    assert(troop:get_target_type()==6 and troop:get_march_state()==2 and troop:get_troop_state()==2)
    assert(troop:get_end_pos()==10 and troop:get_target_id()==501)
    assert(troop._data._march_serial==2 and troop:get_march_info().redeploy_round==2)
    assert(reports._next_id==1 and troop.positions[1]._soldier_cnt==80)
    assert(pushes[#pushes].packet.marchInfo.troopState==2)
    for _,cmd in ipairs(calls) do assert(cmd~="start_march", "胜利驻留不能偷偷发起回城") end
    S.MARCH_MGR.on_arrive(1,1,troop:get_end_time())
    assert(reports._next_id==1 and troop._data._march_serial==2)
end

function T.ally_captures_first_remaining_siege_troop_stays_without_another_battle()
    local S,troop,reports=fixture({allied_first=true})
    finish_siege(S)
    assert(troop:get_target_type()==6 and troop:get_troop_state()==2 and troop:get_end_pos()==10)
    assert(reports._next_id==0 and troop.positions[1]._soldier_cnt==100)
end

function T.defeated_troop_still_returns_even_if_alliance_now_owns_city()
    local S,troop,reports=fixture({captured=true,loss_at=1})
    finish_siege(S)
    assert(troop:get_target_type()==1 and troop:get_troop_state()==1 and reports._next_id==1)
end

function T.deployment_failure_resumes_persisted_stay_without_duplicate_battle()
    local S,troop,reports,_,_,_,fault=fixture({captured=true})
    fault("deployment_arrival"); finish_siege(S)
    assert(troop:get_target_type()==6 and troop:get_troop_state()==2 and reports._next_id==1)
    fault(nil); S.MARCH_MGR.on_arrive(1,1,troop:get_end_time())
    assert(troop:get_target_type()==6 and troop._data._march_serial==2 and reports._next_id==1)
    assert(troop.positions[1]._soldier_cnt==80)
end

function T.city_lookup_failure_keeps_original_receipt_for_stay_retry()
    local S,troop,reports,_,_,_,fault=fixture({captured=true})
    fault("deployment_lookup"); finish_siege(S)
    assert(troop:get_target_type()==5 and troop._data._march_serial==1 and reports._next_id==1)
    fault(nil); finish_siege(S)
    assert(troop:get_target_type()==6 and reports._next_id==1 and troop.positions[1]._soldier_cnt==80)
end

return T
