-- 联盟城池的纯数据规则。数据库和服务调用由 world 管理。
local M = {}

function M.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = M.copy(v) end
    return out
end

-- 战斗结果中站位表可能稀疏，Mongo 文档键必须是字符串；列表仍保持数组。
function M.dump(value)
    if type(value) ~= "table" then return value end
    local count, array = 0, true
    for k in pairs(value) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then array = false end
    end
    array = array and count == #value
    local out = {}
    for k, v in pairs(value) do out[array and k or tostring(k)] = M.dump(v) end
    return out
end

function M.new(conf)
    assert(conf.TeamCount > 0 and conf.Durability >= conf.TeamCount, "invalid city defence")
    return {alliance_id = 0, alliance_name = "", durability = conf.Durability,
        team_left = conf.TeamCount, round = 1, ranks = {}, receipts = {}, outbox = {}, deploys = {}}
end

function M.info(city, state, conf)
    local count = 0
    if state.alliance_id > 0 then
        for _, entry in pairs(state.deploys or {}) do if entry.active then count = count + 1 end end
    end
    return {entityId = city.id, cityType = city.city_type, level = city.level,
        pos = {x = city.x, y = city.y}, allianceId = state.alliance_id,
        allianceName = state.alliance_name, durability = state.durability,
        durabilityMax = conf.Durability, teamLeft = state.team_left, teamCount = conf.TeamCount, deployCount = count}
end

function M.ranks(state)
    local list = {}
    for _, row in pairs(state.ranks) do
        if row.damage > 0 then list[#list + 1] = M.copy(row) end
    end
    -- 同伤害按 uid 升序，重启和 pairs 遍历顺序不会影响名次。
    table.sort(list, function(a, b)
        if a.damage ~= b.damage then return a.damage > b.damage end
        return a.uid < b.uid
    end)
    for i, row in ipairs(list) do row.rank = i end
    return list
end

function M.defender(conf, monster, kind)
    local side = {owner_id = 0, name = conf.Name, power = 0, units = {}}
    for _, entry in ipairs(conf.Team) do
        local m = assert(monster(entry.mid), "missing city guard " .. tostring(entry.mid))
        side.units[#side.units + 1] = {pos = entry.pos, kind = kind, cfg_id = entry.mid,
            level = m.Level, soldier = m.Soldier, count = m.Soldier, hurt = 0}
        side.power = side.power + (m.Power or 0)
    end
    return side
end

function M.damage(def, result)
    local soldiers, damage, recorded = {}, 0, false
    for _, unit in ipairs(def.units) do soldiers[unit.pos] = unit.soldier end
    for _, action in ipairs(result.actions or {}) do
        for _, effect in ipairs(action.effects or {}) do
            if effect.target_side == 2 and soldiers[effect.target_pos] ~= nil then
                local before = soldiers[effect.target_pos]
                local after = math.max(0, effect.after_soldier)
                damage = damage + math.max(0, before - after)
                soldiers[effect.target_pos] = after
                recorded = true
            end
        end
    end
    if not recorded then
        for pos, before in pairs(soldiers) do
            local left = result.def_left[pos] or result.def_left[tostring(pos)] or before
            damage = damage + math.max(0, before - math.max(0, left))
        end
    end
    return math.floor(damage)
end

-- 沿用原有每轮城防扣除量，只把拆城放到守军清空之后。
function M.wall_damage(conf)
    return math.max(1, math.floor(conf.Durability / conf.TeamCount))
end

-- 离盟不删除贡献；同一玩家多次出战累加，联盟名片记录最近一次造成伤害时的所属联盟。
function M.settle(state, conf, actor, damage, won)
    local guards = state.team_left > 0
    if not guards then damage = won and math.min(state.durability, M.wall_damage(conf)) or 0 end
    if damage > 0 then
        local key = tostring(actor.uid)
        local previous = state.ranks[key]
        state.ranks[key] = {uid = actor.uid, name = actor.name, allianceId = actor.alliance.id,
            allianceName = actor.alliance.name, damage = (previous and previous.damage or 0) + damage}
    end
    if not won then return end
    if guards then
        state.team_left = math.max(0, state.team_left - 1)
        return -- 清守军不同时扣城防，最后一队打完后下一轮开始拆城。
    end
    state.durability = math.max(0, state.durability - damage)
    if state.durability > 0 then return end
    local ranks, round = M.ranks(state), state.round
    state.alliance_id, state.alliance_name = actor.alliance.id, actor.alliance.name
    state.team_left, state.durability = conf.TeamCount, conf.Durability
    state.round, state.ranks, state.deploys = round + 1, {}, {}
    local rewards = {}
    for _, entry in ipairs(conf.RankReward or {}) do rewards[entry.rank] = M.copy(entry.reward) end
    return {round = round, rankList = ranks, breakUid = actor.uid, breakName = actor.name, rewards = rewards}
end

-- 地图美术等级与攻城等级分开：美术可有 10 级，攻城使用该类型已配置的最高档。
function M.placements(campaign, configs, types, base, side)
    local list, seen = {}, {}
    local art_type = {town = types.COUNTY, county = types.COMMANDERY, capital = types.CAPITAL}
    local function add(row, city_type)
        city_type = row.cityType or city_type
        local levels = assert(configs[city_type], "missing city type")
        local max_level = 0
        for level in pairs(levels) do max_level = math.max(max_level, level) end
        local level = math.min(row.level, max_level)
        assert(levels[level], "missing siege level")
        local id = base + row.y * side + row.x
        assert(not seen[id], "duplicate campaign city")
        seen[id] = true
        -- 关隘未单列 footprintRadius 时，按客户端城墙美术等级取占地，不能一律当成 3×3。
        local radius = row.footprintRadius or (row.level >= 10 and 4 or row.level >= 8 and 3 or row.level >= 5 and 2 or 1)
        list[#list + 1] = {id = id, city_type = city_type, level = level, map_level = row.level,
            x = row.x, y = row.y, name = row.name, radius = radius}
    end
    for _, row in ipairs(campaign.cities or {}) do add(row, art_type[row.art]) end
    for _, row in ipairs(campaign.gates or {}) do add(row, types.PASS) end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

return M
