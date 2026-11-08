local siege = require "city_siege"
local T = {}
local conf = {Name = "试验城", Durability = 101, TeamCount = 3,
    Team = {{mid = 21, pos = 1}}, RankReward = {
        {rank = 1, reward = {{reward_type = 1, item_id = 1, item_count = 100}}},
        {rank = 2, reward = {{reward_type = 1, item_id = 2, item_count = 50}}},
        {rank = 3, reward = {{reward_type = 1, item_id = 3, item_count = 10}}}}}
local function actor(uid, aid, seq)
    return {uid = uid, troop_idx = 1, seq = seq or 1, name = "玩家" .. uid,
        alliance = {id = aid, name = "联盟" .. aid}, side = {owner_id = uid, name = "玩家" .. uid,
            power = 100, units = {{pos = 1, kind = 1, cfg_id = 1001, level = 1, soldier = 100, count = 100, hurt = 0}}}}
end

function T.shared_damage_last_blow_and_remainder()
    local s = siege.new(conf)
    assert(not siege.settle(s, conf, actor(1, 11), 90, true))
    assert(s.team_left == 2 and s.durability == 101)
    siege.settle(s, conf, actor(2, 22), 100, false)
    assert(s.team_left == 2 and s.durability == 101)
    siege.settle(s, conf, actor(3, 33), 50, true)
    assert(s.team_left == 1 and s.durability == 101)
    assert(not siege.settle(s, conf, actor(4, 44), 20, true))
    assert(s.team_left == 0 and s.durability == 101, "清完守军后才能开始拆城")
    for i=1,3 do
        assert(not siege.settle(s, conf, actor(4,44), 0, true))
        assert(s.team_left==0 and s.durability==101-33*i)
    end
    local event = siege.settle(s, conf, actor(4, 44), 0, true)
    assert(s.alliance_id == 44 and s.team_left == 3 and s.durability == 101)
    assert(s.round == 2 and not next(s.ranks) and event.round == 1)
    assert(event.rankList[1].uid == 4 and event.rankList[4].uid == 3)
    assert(event.rewards[1][1].item_count == 100 and not event.rewards[4])
end

function T.departed_members_keep_damage_and_ties_are_stable()
    local s = siege.new(conf)
    siege.settle(s, conf, actor(2, 11), 20, false)
    siege.settle(s, conf, actor(1, 22), 20, false)
    local ranks = siege.ranks(s)
    assert(ranks[1].uid == 1 and ranks[2].allianceId == 11)
    siege.settle(s, conf, actor(2, 33), 10, false)
    ranks = siege.ranks(s)
    assert(ranks[1].uid == 2 and ranks[1].damage == 30 and ranks[1].allianceId == 33)
end

function T.actual_damage_excludes_overkill_and_friendly_effects()
    local def = {units = {{pos = 1, soldier = 50}, {pos = 3, soldier = 40}}}
    local result = {actions = {{effects = {
        {target_side = 2, target_pos = 1, value = 900, after_soldier = 10},
        {target_side = 1, target_pos = 1, value = 200, after_soldier = 0},
        {target_side = 2, target_pos = 1, value = 100, after_soldier = 0},
        {target_side = 2, target_pos = 3, value = 5, after_soldier = 35}}}}}
    assert(siege.damage(def, result) == 55)
    assert(siege.damage(def, {def_left = {['1'] = 0, ['3'] = 30}}) == 60)
end

function T.map_uses_real_cities_gates_and_valid_guards()
    local configs = dofile("game_common/server/res/City.lua")
    local types = dofile("game_common/server/enum/CityTypeEnum.lua")
    local campaign = dofile("res/map/campaign-map.lua")
    local list = siege.placements(campaign, configs, types, 5000000000000000, 1000)
    assert(#list == #campaign.cities + #campaign.gates)
    local monsters = {}
    for _, row in pairs(dofile("game_common/server/res/Monster.lua")) do monsters[row.Id] = row end
    local capital
    for _, city in ipairs(list) do
        local c = configs[city.city_type][city.level]
        assert(c and city.id == 5000000000000000 + city.y * 1000 + city.x)
        local def = siege.defender(c, function(id) return monsters[id] end, 2)
        assert(#def.units > 0 and def.power > 0)
        if city.city_type == types.CAPITAL then capital = city end
    end
    assert(capital and capital.level == 8 and capital.map_level == 10)
end

-- 使用真实 skynet.queue 和可暂停的战斗 RPC，模拟两支部队同时到达。
local function fixture(saved)
    local calls, sends, writes, mails, wakeups, timers = {}, {}, {}, {}, {}, {}
    local sky, fault, pause = {}, nil, false
    sky.wait = function() coroutine.yield("lock") end
    sky.wakeup = function(co) wakeups[#wakeups + 1] = co end
    local qenv = setmetatable({require = function() return sky end}, {__index = _G})
    local queue = assert(loadfile("skynet/lualib/skynet/queue.lua", "t", qenv))()
    sky.getenv = function() return 1 end
    sky.timeout = function(_, fn) timers[#timers + 1] = fn end
    sky.error = function() end
    local member = {[1] = 11, [2] = 22, [3] = 33, [4] = 44}
    sky.call = function(service, _, cmd, ...)
        local args = {...}
        if cmd == "public_user_alliance" then return {id = member[args[1]] or 0, name = "盟" .. (member[args[1]] or 0)} end
        if cmd == "city_audience" then return {8, 9} end
        if cmd == "get_agent_list" then return {"agent"} end
        if cmd == "send_user_mail_once" then
            if fault == "mail" then error("mail unavailable") end
            local uid, source, round = args[1], args[2], args[3]
            mails[source .. ":" .. round .. ":" .. uid] = args[6]
            return true
        end
        if cmd == "fight_batch" then
            calls[#calls + 1] = args[2][1].owner_id
            if pause then coroutine.yield("battle") end
            return {{result = 1, atk_left = {[1] = 60}, def_left = {[1] = 0}, max_round = 1, actions = {}}}
        end
        error("unexpected call " .. cmd)
    end
    sky.send = function(_, _, cmd, uid, name, packet) sends[#sends + 1] = {uid = uid, name = name, packet = packet} end
    local env = setmetatable({require = function(n)
        if n == "skynet" then return sky elseif n == "skynet.queue" then return queue else return require(n) end
    end, CONST = {BATTLE_UNIT = {MONSTER = 2}, BATTLE_RESULT = {WIN = 1}, MAIL_ID = {RANK_REWARD = 4}},
        DATA_COMMON = {get_city_conf = function() return conf end,
            get_monster_conf = function() return {Level = 1, Soldier = 100, Power = 100} end},
        MAP_MGR = {set_alliance_city_owner = function() end,
            alliance_cities = {{id = 101, city_type = 1, level = 1, x = 10, y = 20, name = "试验城", radius = 1}}},
        TIME = {os_bj_sec = function() return 123 end},
        AOI_MGR = {upsert_alliance_city = function() end, city_watchers = function() return {[7] = true} end},
        MONGO_SLAVE = {COL = {CITY = "city"}, common_load_tbl = function() return siege.copy(saved or {}) end,
            save_doc = function(_, id, state) writes[id] = siege.copy(state) end,
            flush_sync = function() if fault == "db" then error("database down") end end},
    }, {__index = _G})
    assert(loadfile("logic/service/world/module/city/mgr.lua", "t", env))()
    env.init()
    return env, calls, sends, writes, mails, member,
        function(kind) fault = kind end, function(value) pause = value end, wakeups
end

function T.permissions_duplicate_receipts_and_restart()
    local C, calls, _, writes, _, members = fixture()
    members[1] = 0
    assert(not C.target(101, 1) and not C.attack(101, actor(1, 0)))
    assert(not C.info(999))
    members[1] = 11
    local first = C.attack(101, actor(1, 11))
    assert(first.result.atk_left[1] == 60 and #calls == 1)
    C.attack(101, actor(1, 11))
    assert(#calls == 1 and C.info(101).cityInfo.teamLeft == 2)
    local restarted, newcalls = fixture(writes)
    local replay = restarted.attack(101, actor(1, 11))
    assert(replay.seq == 1 and #newcalls == 0)
    restarted.ack(101, 1, 1, 1)
    assert(not restarted.attack(101, actor(1, 11)) and #newcalls == 0)
end

function T.concurrent_arrivals_only_remove_each_team_once()
    local C, calls, _, _, _, _, _, pause, wakeups = fixture()
    pause(true)
    local a = coroutine.create(function() C.attack(101, actor(1, 11)) end)
    local b = coroutine.create(function() C.attack(101, actor(2, 22)) end)
    assert(coroutine.resume(a))
    assert(coroutine.resume(b))
    assert(#calls == 1, "第二场必须等待同城第一场提交")
    assert(coroutine.resume(a))
    assert(#wakeups == 1 and wakeups[1] == b)
    assert(coroutine.resume(b))
    assert(#calls == 2)
    assert(coroutine.resume(b))
    assert(C.info(101).cityInfo.teamLeft == 1)
end

function T.persistence_failure_retries_same_result_without_rebattle()
    local C, calls, sends, _, _, _, fault = fixture()
    fault("db")
    assert(not pcall(C.attack, 101, actor(1, 11)))
    assert(#sends == 0 and #calls == 1)
    fault(nil)
    assert(C.attack(101, actor(1, 11)).seq == 1)
    assert(#calls == 1 and C.info(101).cityInfo.teamLeft == 2)
end

function T.capture_reward_outbox_survives_restart_and_own_city_rejected()
    local C, _, _, writes, _, _, fault = fixture()
    C.attack(101, actor(1, 11))
    C.attack(101, actor(2, 22))
    C.attack(101, actor(3, 33))
    assert(C.info(101).cityInfo.teamLeft==0 and C.info(101).cityInfo.allianceId==0)
    for seq=2,5 do C.attack(101, actor(3,33,seq)) end
    assert(C.info(101).cityInfo.allianceId == 33)
    assert(not C.target(101, 3))
    fault("mail")
    C.retry_rewards()
    assert(next(C.states[101].outbox))
    local restarted, _, sends, _, mails = fixture(writes)
    restarted.retry_rewards()
    assert(not next(restarted.states[101].outbox))
    local count = 0
    for _ in pairs(mails) do count = count + 1 end
    assert(count == 3)
    local occupied = 0
    for _, push in ipairs(sends) do
        if push.name == "s2c_city_occupy" then
            occupied = occupied + 1
            assert(#push.packet.rankList == 3 and #push.packet.rewardList == 1)
        end
    end
    assert(occupied == 3)
    restarted.retry_rewards()
    assert(#sends == occupied)
end

function T.mongo_bson_roundtrip_preserves_sparse_battle_receipts()
    local bson = require "bson"
    local s = siege.new(conf)
    s.receipts['7:1'] = {seq = 3, result = {atk_left = {[1] = 25, [3] = 0}, def_left = {[2] = 4}}}
    s.ranks['7'] = {uid = 7, damage = 999, allianceId = 11, allianceName = "山河", name = "主公"}
    s.outbox['1'] = {rankList = siege.ranks(s), rewards = {[3] = {{reward_type = 1, item_id = 4, item_count = 50}}}}
    local back = bson.decode(bson.encode({dat = siege.dump(s)})).dat
    assert(back.receipts['7:1'].result.atk_left['3'] == 0)
    assert(back.ranks['7'].damage == 999 and back.outbox['1'].rewards['3'][1].item_count == 50)
end

function T.wall_rounds_have_no_guard_battle_and_stop_at_capture()
    local C, calls = fixture()
    local target=C.target(101,1)
    assert(target.round==1)
    for seq=1,3 do
        local a=actor(1,11,seq);a.city_round=1
        local r=C.attack(101,a)
        assert(r.phase=="guards" and r.continue_siege and not r.captured)
    end
    assert(#calls==3 and C.info(101).cityInfo.durability==101)
    for seq=4,7 do
        local a=actor(1,11,seq);a.city_round=1
        local r=C.attack(101,a)
        assert(r.phase=="wall" and #r.def.units==0 and r.result.atk_left[1]==100)
        assert(r.continue_siege==(seq<7) and r.captured==(seq==7))
        local duplicate=C.attack(101,a)
        assert(duplicate.seq==seq and duplicate.wall_damage==r.wall_damage)
    end
    assert(#calls==3, "拆城不能再次生成守军战斗")
    assert(C.info(101).cityInfo.allianceId==11)
    local stale=actor(2,22,1);stale.city_round=1
    assert(not C.attack(101,stale), "他人攻下城池后，旧攻城指令不能攻击新一轮守军")
    stale.city_round=C.target(101,2).round
    assert(stale.city_round==2 and C.attack(101,stale))
end

return T
