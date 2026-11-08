-- 同格遭遇：按进入时间配对，同一玩家不打，打输的不在原地再打一次

local function load_path()
	local env = setmetatable({}, {__index = _G})
	assert(loadfile("common/march_path.lua", "t", env))()
	return env
end

local function load_encounter()
	local env = setmetatable({MARCH_PATH = load_path(), DATA_COMMON = {TARGET_TYPE = dofile("game_common/server/enum/TargetTypeEnum.lua")}}, {__index = _G})
	assert(loadfile("logic/service/world/module/encounter/mgr.lua", "t", env))()
	return env
end

local function troop(id, user_id, x, y, path, t0, t1)
	return {
		id = id,
		user_id = user_id,
		troop_idx = 1,
		moving = path and true or false,
		path = path,
		start_time = t0 or 0,
		end_time = t1 or 0,
		scan_time = t0 or 0,
		x = x,
		y = y,
	}
end

local function line(x0, x1)
	return {{_x = x0, _y = 0}, {_x = x1, _y = 0}}
end

local T = {}

function T.redeploy_does_not_start_or_join_encounters()
    local E = load_encounter()
    local camp = troop(1, 10, 2, 0)
    E.index_at(camp, 2, 0)
    local mover = troop(2, 20, 0, 0, line(0, 4), 0, 4)
    mover.target_type = 6
    E.index_at(mover, 0, 0)
    local fights, stops = E.advance({mover}, 3)
    assert(#fights == 0 and #stops == 0 and not mover.fighting and not camp.fighting)
    E.index_at(mover, 2, 0)
    assert(not E.touch(mover) and not E.touch(camp))
end
function T.return_city_never_fights_at_start_crossing_or_arrival()
    local E = load_encounter()
    local camp = troop(1, 10, 2, 0)
    E.index_at(camp, 2, 0)
    local mover = troop(2, 20, 2, 0, line(2, 6), 0, 4)
    mover.target_type = 1
    E.index_at(mover, 2, 0)
    assert(not E.touch(mover) and not E.touch(camp), "return cannot attack or be attacked at departure")
    E.MARCH_PATH.cells_crossed = function() error("return must skip collision scanning") end
    local fights, stops = E.advance({mover}, 4)
    assert(#fights == 0 and #stops == 0 and mover.moving and not camp.fighting)
    E.index_at(camp, 6, 0); E.index_at(mover, 6, 0)
    assert(not E.touch(mover) and not E.touch(camp), "return cannot fight at arrival")
end

function T.return_city_can_pass_an_enemy_in_the_opposite_direction()
    local E = load_encounter()
    local home = troop(1, 10, 0, 0, line(0, 4), 0, 4)
    home.target_type = 1
    local enemy = troop(2, 20, 4, 0, line(4, 0), 0, 4)
    E.index_at(home, 0, 0); E.index_at(enemy, 4, 0)
    local fights, stops = E.advance({home, enemy}, 4)
    assert(#fights == 0 and #stops == 0 and home.moving and enemy.moving)
    assert(not home.fighting and not enemy.fighting)
end

function T.return_order_removes_previous_encounter_index()
    local E = load_encounter()
    local home = troop(1, 10, 2, 0)
    E.index_at(home, 2, 0)
    home.target_type = 1
    E.index_at(home, 2, 0)
    local enemy = troop(2, 20, 2, 0)
    E.index_at(enemy, 2, 0)
    assert(not E.touch(enemy) and not E.touch(home))
end

function T.meet_stationary()
	local E = load_encounter()
	local camp = troop(1, 10, 2, 0)
	E.index_at(camp, 2, 0)
	local mover = troop(2, 20, 0, 0, line(0, 4), 0, 4)
	E.index_at(mover, 0, 0)
	local fights = E.advance({mover}, 4)
	assert(#fights == 1, "walker should hit the troop standing on the cell")
	assert(fights[1].atk == mover and fights[1].def == camp)
	assert(mover.fighting and camp.fighting)
	assert(not mover.moving and not camp.moving)
end

function T.same_alliance_passes()
	local E = load_encounter()
	E.set_user_alliance(10, 7)
	E.set_user_alliance(20, 7)
	local a = troop(1, 10, 2, 0)
	E.index_at(a, 2, 0)
	local b = troop(2, 20, 0, 0, line(0, 4), 0, 4)
	E.index_at(b, 0, 0)
	local fights = E.advance({b}, 4)
	assert(#fights == 0, "same alliance does not fight")
end

function T.no_alliance_fights()
	local E = load_encounter()
	local a = troop(1, 10, 2, 0)
	E.index_at(a, 2, 0)
	local b = troop(2, 20, 0, 0, line(0, 4), 0, 4)
	E.index_at(b, 0, 0)
	local fights = E.advance({b}, 4)
	assert(#fights == 1, "players without an alliance still fight")
end

function T.one_has_alliance_still_fights()
	local E = load_encounter()
	E.set_user_alliance(10, 7)
	local a = troop(1, 10, 2, 0)
	E.index_at(a, 2, 0)
	local b = troop(2, 20, 0, 0, line(0, 4), 0, 4)
	E.index_at(b, 0, 0)
	local fights = E.advance({b}, 4)
	assert(#fights == 1, "a member still fights a player with no alliance")
end

function T.same_user_passes()
	local E = load_encounter()
	local a = troop(1, 10, 2, 0)
	E.index_at(a, 2, 0)
	local b = troop(2, 10, 0, 0, line(0, 4), 0, 4)
	E.index_at(b, 0, 0)
	local fights = E.advance({b}, 4)
	assert(#fights == 0, "own troops do not fight")
end

function T.head_on()
	local E = load_encounter()
	local a = troop(1, 10, 0, 0, line(0, 4), 0, 4)
	local b = troop(2, 20, 4, 0, {{_x = 4, _y = 0}, {_x = 0, _y = 0}}, 0, 4)
	E.index_at(a, 0, 0)
	E.index_at(b, 4, 0)
	local fights = E.advance({a, b}, 4)
	assert(#fights == 1, "opposite marches share a cell")
	local pair = fights[1]
	assert(pair.atk.user_id ~= pair.def.user_id)
	assert(pair.atk.fighting and pair.def.fighting)
end

function T.loser_does_not_refight_on_same_cell()
	local E = load_encounter()
	local a = troop(1, 10, 1, 0)
	local b = troop(2, 20, 1, 0)
	E.index_at(a, 1, 0)
	E.index_at(b, 1, 0)
	local fight = E.touch(b)
	assert(fight and fight.atk == b and fight.def == a)
	E.conclude(fight.atk, fight.def, fight.gen, false)
	assert(E.foe_of(a) == nil, "winner stays, loser already left the cell")
	E.index_at(b, 1, 0)
	assert(E.foe_of(b) == nil, "loser walks off this cell before fighting again")
	E.index_at(b, 2, 0)
	local c = troop(3, 30, 2, 0)
	E.index_at(c, 2, 0)
	assert(E.foe_of(b) == c, "next cell is a new encounter")
end

return T
