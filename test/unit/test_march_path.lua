-- common/march_path.lua 折线匀速插值；配合 vendor/slg-navigation 绕开障碍

local navigation = require "navigation"

local function load_path_mod()
	local env = setmetatable({}, {__index = _G})
	assert(loadfile("common/march_path.lua", "t", env))()
	return env
end

local function near(a, b)
	return math.abs(a - b) < 1e-6
end

local T = {}

function T.fractional_cell_speed()
	local M = load_path_mod()
	local far = {{_x = 0, _y = 0}, {_x = 10, _y = 0}}
	assert(M.march_seconds(far, 0.5) == 20)
	assert(M.march_seconds({{_x = 0, _y = 0}, {_x = 1, _y = 0}}, 0.25) == 4)
end

function T.pos_along_polyline()
	local M = load_path_mod()
	-- (0,0) -> (3,0) -> (3,4)，总长 7，用 7 秒走完
	local path = {{_x = 0, _y = 0}, {_x = 3, _y = 0}, {_x = 3, _y = 4}}
	assert(near(M.length(path), 7))
	local x, y = M.pos_at(path, 100, 107, 102)
	assert(near(x, 2) and near(y, 0), "still on first segment")
	x, y = M.pos_at(path, 100, 107, 105)
	assert(near(x, 3) and near(y, 2), "turned the corner")
	x, y = M.pos_at(path, 100, 107, 99)
	assert(x == 0 and y == 0, "before start")
	x, y = M.pos_at(path, 100, 107, 200)
	assert(x == 3 and y == 4, "after end")
end

function T.cells_along_fast_march()
	local M = load_path_mod()
	-- 1 秒走 5 格，不能只看到终点
	local path = {{_x = 0, _y = 0}, {_x = 5, _y = 0}}
	local cells = M.cells_crossed(path, 0, 1, 0, 1)
	local seen = {}
	for _, c in ipairs(cells) do
		seen[c.x .. ":" .. c.y] = true
		assert(c.y == 0)
	end
	for x = 0, 5 do
		assert(seen[x .. ":0"], "missing cell " .. x)
	end
end

function T.cells_stop_at_query_end()
	local M = load_path_mod()
	local path = {{_x = 0, _y = 0}, {_x = 10, _y = 0}}
	local cells = M.cells_crossed(path, 0, 10, 2, 4)
	assert(cells[1].x == 2, "starts where the second ends")
	assert(cells[#cells].x == 4, "stops at the fourth second")
end

function T.empty_path_is_origin()
	local M = load_path_mod()
	local x, y = M.pos_at({}, 0, 10, 5)
	assert(x == 0 and y == 0)
end

function T.nav_detours_around_wall()
	local M = load_path_mod()
	local wall = {}
	for x = 5, 15 do
		wall[#wall + 1] = {x, 10}
	end
	local nav = navigation.new(20, 20, wall)
	local raw = nav:find_path({x = 10, y = 15}, {x = 10, y = 5})
	assert(#raw >= 3, "needs a turn")
	local path = {}
	for i, p in ipairs(raw) do
		path[i] = {_x = p.x, _y = p.y}
	end
	assert(path[1]._x == 10 and path[1]._y == 15 and path[#path]._x == 10 and path[#path]._y == 5)
	assert(M.length(path) > 10, "longer than straight line through the wall")
	for t = 0, 100 do
		local x, y = M.pos_at(path, 0, 100, t)
		assert(not nav:is_obstacle({x = x, y = y}), string.format("walked into wall at %.2f,%.2f", x, y))
	end
end

function T.nav_unreachable_is_empty()
	local nav = navigation.new(10, 10, {{5, 5}})
	assert(#nav:find_path({x = 1, y = 1}, {x = 5, y = 5}) == 0)
end

return T
