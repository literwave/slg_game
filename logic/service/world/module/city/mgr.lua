local skynet = require "skynet"
local queue = require "skynet.queue"
local siege = require "city_siege"

-- 每城一个写队列，战斗计算可以让出服务，但同城结算不可交叉。
cities = cities or {}
states = states or {}
locks = locks or {}
pending = pending or {}
needs_sync = needs_sync or {}
retry_started = retry_started or false
agent_list = agent_list or nil

local function conf_of(city)
    return assert(DATA_COMMON.get_city_conf(city.city_type, city.level))
end

local function durable(id, state)
    states[id], pending[id] = state, true
    MONGO_SLAVE.save_doc(MONGO_SLAVE.COL.CITY, id, siege.dump(state))
    MONGO_SLAVE.flush_sync()
    pending[id] = nil
end

local function locked(id, fn)
    if not cities[id] then return nil, "城池不存在" end
    locks[id] = locks[id] or queue()
    return locks[id](function()
        -- 上次写入失败时先完成原事务，不能再次战斗或先推送未落盘的城池。
        if pending[id] then MONGO_SLAVE.flush_sync(); pending[id] = nil end
        return fn(cities[id], states[id])
    end)
end

local function send(uid, name, packet)
    agent_list = agent_list or skynet.call(".gated", "lua", "get_agent_list")
    local agents = agent_list
    if agents and #agents > 0 then
        skynet.send(agents[uid % #agents + 1], "lua", "city_push", uid, name, packet)
    end
end

local function show(city, state)
	MAP_MGR.set_alliance_city_owner(city.id, state.alliance_id)
    local info = siege.info(city, state, conf_of(city))
    AOI_MGR.upsert_alliance_city(info)
    return info
end

local function sync(city, state, extra_ranks, previous_owner)
    local info = show(city, state)
    local alliances, recipients = {}, AOI_MGR.city_watchers(city.id)
    if state.alliance_id > 0 then alliances[tostring(state.alliance_id)] = true end
    if previous_owner and previous_owner > 0 then alliances[tostring(previous_owner)] = true end
    for _, ranks in ipairs({siege.ranks(state), extra_ranks or {}}) do
        for _, row in ipairs(ranks) do
            recipients[row.uid] = true
            if row.allianceId > 0 then alliances[tostring(row.allianceId)] = true end
        end
    end
    local ok, members = pcall(skynet.call, ".union", "lua", "city_audience", alliances)
    if ok then for _, uid in ipairs(members) do recipients[uid] = true end end
    for uid in pairs(recipients) do send(uid, "s2c_sync_city", {cityInfo = info}) end
    needs_sync[city.id] = nil
end

local function deliver(city, state)
    local keys = {}
    for round in pairs(state.outbox) do keys[#keys + 1] = tonumber(round) end
    table.sort(keys)
    for _, round in ipairs(keys) do
        local event = state.outbox[tostring(round)]
        for _, row in ipairs(event.rankList) do
            local rewards = event.rewards[row.rank] or event.rewards[tostring(row.rank)] or {}
            if #rewards > 0 then
                -- 邮件本身和来源去重标记同属一个玩家文档，持久化成功后才确认。
                assert(skynet.call(".mail", "lua", "send_user_mail_once", row.uid,
                    "city:" .. tostring(city.id), round, CONST.MAIL_ID.RANK_REWARD,
                    {city.name .. "攻城", tostring(row.rank)}, rewards), "city reward mail not saved")
            end
        end
        for _, row in ipairs(event.rankList) do
            local reward_list = {}
            for _, r in ipairs(event.rewards[row.rank] or event.rewards[tostring(row.rank)] or {}) do
                reward_list[#reward_list + 1] = {rewardType = r.reward_type, itemId = r.item_id, itemCount = r.item_count}
            end
            -- 奖励通知可能延后重试；排名保持占领时快照，城池状态使用当前账本，避免回退驻留人数。
            send(row.uid, "s2c_city_occupy", {cityInfo = siege.info(city, state, conf_of(city)), breakUid = event.breakUid,
                breakName = event.breakName, rankList = event.rankList, rewardList = reward_list})
        end
        local next_state = siege.copy(state)
        next_state.outbox[tostring(round)] = nil
        durable(city.id, next_state)
        state = next_state
    end
end

function list()
    local list = {}
    for id in pairs(cities) do list[#list + 1] = info(id).cityInfo end
    table.sort(list, function(a, b) return a.entityId < b.entityId end)
    return {cityList = list}
end

function info(id)
    return locked(id, function(city, state)
        return {cityInfo = siege.info(city, state, conf_of(city)), rankList = siege.ranks(state)}
    end)
end

function target(id, uid)
    return locked(id, function(city, state)
        local alliance = skynet.call(".union", "lua", "public_user_alliance", uid)
        if not alliance or alliance.id == 0 then return nil, "请先加入联盟" end
        if state.alliance_id == alliance.id then return nil, "不能攻打本盟城池" end
        return {x = city.x, y = city.y, radius = city.radius, round = state.round}
    end)
end

-- 预览协议只带目的格；仅按真实城池中心查找，不能凭客户端坐标构造城池。
function target_at(x, y, uid)
    for id, city in pairs(cities) do
        if city.x == x and city.y == y then return target(id, uid) end
    end
end

-- 调动与攻城分别校验；只接受本盟城池的真实实体，不使用客户端传入的终点。
function redeploy_target(id, uid, round)
    return locked(id, function(city, state)
        local alliance = skynet.call(".union", "lua", "public_user_alliance", uid)
        if not alliance or alliance.id == 0 or state.alliance_id ~= alliance.id then
            return nil, "只能调动至本盟城池"
        end
        if round and round ~= state.round then return nil, "城池归属已变化，调动取消" end
        return {x = city.x, y = city.y, round = state.round}
    end)
end

function redeploy_target_at(x, y, uid)
    for id, city in pairs(cities) do
        if city.x == x and city.y == y then return redeploy_target(id, uid) end
    end
end

local function save_deploys(city, state)
    needs_sync[city.id] = true
    durable(city.id, state)
    local ok, err = pcall(sync, city, state)
    if not ok then skynet.error("city deploy sync retained for retry", city.id, err) end
end

-- 以部队和行军流水号去重，保留离开标记，迟到/重登回调不能把旧驻留加回来。
function arrive_redeploy(march)
    return locked(march.target_id, function(city, state)
        if march.target_type ~= DATA_COMMON.TARGET_TYPE.REDEPLOY
            or march.state ~= CONST.MARCH_STATE.ARRIVED or (march.serial or 0) <= 0 then return false end
        local alliance = skynet.call(".union", "lua", "public_user_alliance", march.user_id)
        if not alliance or alliance.id == 0 or state.alliance_id ~= alliance.id
            or state.round ~= march.redeploy_round then return false end
        local key = tostring(march.user_id) .. ":" .. tostring(march.troop_idx)
        local old = (state.deploys or {})[key]
        if old and old.seq >= march.serial then return old.seq == march.serial and old.active == true end
        local next_state = siege.copy(state)
        next_state.deploys = next_state.deploys or {}
        next_state.deploys[key] = {uid = march.user_id, idx = march.troop_idx, seq = march.serial, active = true}
        save_deploys(city, next_state)
        return true
    end)
end

-- AOI 从已提交的驻留账本取得城池身份，不信任坐标巧合，也无需重启入口服务。
function deployed_city(uid, idx, serial)
    local key = tostring(uid) .. ":" .. tostring(idx)
    for id, state in pairs(states) do
        local entry = (state.deploys or {})[key]
        if entry and entry.active and entry.seq == serial then return id end
    end
end

function leave_redeploy(uid, idx)
    local key = tostring(uid) .. ":" .. tostring(idx)
    for id, state in pairs(states) do
        if state.deploys and state.deploys[key] and state.deploys[key].active then
            local ok, err = pcall(locked, id, function(city, current)
                if not current.deploys or not current.deploys[key] or not current.deploys[key].active then return end
                local next_state = siege.copy(current)
                next_state.deploys[key].active = false
                save_deploys(city, next_state)
            end)
            -- 行军已成功启动，落库失败由 pending 重试，不能因此回滚已启动的部队。
            if not ok then skynet.error("city departure retained for retry", id, err) end
        end
    end
end

function on_user_alliance(uid, alliance_id)
    for id, state in pairs(states) do
        if state.alliance_id ~= alliance_id then
            local remove = false
            for _, entry in pairs(state.deploys or {}) do
                if entry.active and entry.uid == uid then remove = true; break end
            end
            if remove then
                locked(id, function(city, current)
                    local next_state = siege.copy(current)
                    for _, entry in pairs(next_state.deploys or {}) do
                        if entry.uid == uid then entry.active = false end
                    end
                    save_deploys(city, next_state)
                end)
            end
        end
    end
end

function attack(id, actor)
    return locked(id, function(city, state)
        assert(actor.uid > 0 and actor.troop_idx > 0 and actor.seq > 0, "invalid siege identity")
        local key = tostring(actor.uid) .. ":" .. tostring(actor.troop_idx)
        local old = state.receipts[key]
        if old and old.seq >= actor.seq then
            if old.seq == actor.seq and old.result then return siege.copy(old) end
            return nil, "本次攻城已结算"
        end
        -- 先取回同流水号回执，再检查归属轮次，保证最后一击也能断线恢复。
        if (actor.city_round or 0) > 0 and actor.city_round ~= state.round then
            return nil, "城池归属已变化，攻城结束"
        end
        actor.alliance = skynet.call(".union", "lua", "public_user_alliance", actor.uid)
        if not actor.alliance or actor.alliance.id == 0 then return nil, "请先加入联盟" end
        if state.alliance_id == actor.alliance.id then return nil, "不能攻打本盟城池" end
        local healthy = 0
        for _, unit in ipairs(actor.side.units) do healthy = healthy + unit.soldier end
        if healthy <= 0 then return nil, "部队没有可用兵力" end
        local conf = conf_of(city)
        local guards = state.team_left > 0
        local def, res
        if guards then
            def = siege.defender(conf, DATA_COMMON.get_monster_conf, CONST.BATTLE_UNIT.MONSTER)
            local count = tonumber(skynet.getenv("battle_cnt")) or 1
            res = skynet.call(".battle" .. (id % count + 1), "lua", "fight_batch", def, {actor.side})[1]
        else
            -- 守军已清空，仅按轮拆城，不虚构守军战斗、战损或空战报。
            def = {owner_id = 0, name = conf.Name, power = 0, units = {}}
            res = {result = CONST.BATTLE_RESULT.WIN, atk_left = {}, def_left = {}, max_round = 0, actions = {}}
            for _, unit in ipairs(actor.side.units) do res.atk_left[unit.pos] = unit.soldier end
        end
        local next_state, previous_owner = siege.copy(state), state.alliance_id
        local receipt = {seq = actor.seq, atk = siege.copy(actor.side), def = def, result = res,
            x = city.x, y = city.y, time = TIME.os_bj_sec(), city_round = state.round,
            phase = guards and "guards" or "wall"}
        local event = siege.settle(next_state, conf, actor, siege.damage(def, res), res.result == CONST.BATTLE_RESULT.WIN)
        if event then
            event.previous_owner = previous_owner
            event.cityInfo = siege.info(city, next_state, conf)
            next_state.outbox[tostring(event.round)] = event
        end
        local survivors = 0
        for _, left in pairs(res.atk_left or {}) do survivors = survivors + math.max(0, left) end
        receipt.continue_siege = not event and res.result == CONST.BATTLE_RESULT.WIN and survivors > 0
        receipt.captured = event ~= nil
        receipt.wall_damage = guards and 0 or math.min(state.durability, siege.wall_damage(conf))
        next_state.receipts[key] = receipt
        -- 守军、伤害榜、归属、战斗回执和奖励待发记录同文档落盘。
        needs_sync[id] = true
        durable(id, next_state)
        local ok, err = pcall(sync, city, next_state, event and event.rankList, previous_owner)
        if not ok then skynet.error("city sync retry on next change", err) end
        -- 发奖由独立重试器处理，邮件服务暂不可用不能阻塞部队回城。
        return siege.copy(receipt)
    end)
end

function ack(id, uid, troop_idx, seq)
    return locked(id, function(_, state)
        local key = tostring(uid) .. ":" .. tostring(troop_idx)
        local old = state.receipts[key]
        if old and old.seq == seq and old.result then
            local next_state = siege.copy(state)
            next_state.receipts[key] = {seq = seq}
            durable(id, next_state)
        end
        return true
    end)
end

function retry_rewards()
    for id, state in pairs(states) do
        if pending[id] or needs_sync[id] or next(state.outbox) then
            local ok, err = pcall(locked, id, function(city, current)
                if needs_sync[id] then
                    local event = current.outbox[tostring(current.round - 1)]
                    sync(city, current, event and event.rankList, event and event.previous_owner)
                end
                deliver(city, current)
            end)
            if not ok then skynet.error("city reward retained for retry", id, err) end
        end
    end
end

function init()
    -- 城池账本持久化，但启动时仍与已落库部队和联盟成员表核对，排除停机时未完成的离开操作。
    local troops = {}
    for _, doc in pairs(MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.USER_TROOP)) do
        for _, troop in pairs(doc._troops or {}) do
            troops[tostring(troop._user_id) .. ":" .. tostring(troop._troop_idx)] = troop
        end
    end
    local saved = MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.CITY)
    for _, city in ipairs(MAP_MGR.alliance_cities) do
        cities[city.id] = city
        states[city.id] = saved[city.id] or siege.new(conf_of(city))
        local state, changed = states[city.id], false
        for key, entry in pairs(state.deploys or {}) do
            local troop = troops[key]
            local march = troop and troop._march
            if entry.active and (not march or march._state ~= CONST.MARCH_STATE.ARRIVED
                or march._target_type ~= DATA_COMMON.TARGET_TYPE.REDEPLOY or march._target_id ~= city.id
                or troop._march_serial ~= entry.seq or troop._redeploy_round ~= state.round
                or ENCOUNTER_MGR.alliance_of[entry.uid] ~= state.alliance_id) then
                entry.active, changed = false, true
            end
        end
        if changed then durable(city.id, state) end
        show(city, state)
    end
    if not retry_started then
        retry_started = true
        local function tick()
            retry_rewards()
            skynet.timeout(500, tick)
        end
        skynet.timeout(500, tick)
    end
end
