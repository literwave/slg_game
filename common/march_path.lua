-- 行军路径：拐点列表 {{_x, _y}, ...}，含起点和终点。整条路按路程匀速走
-- agent 的部队和 world 的 AOI 实体都用这里算位置，保证两边一致

local function seg_len(a, b)
	local dx = b._x - a._x
	local dy = b._y - a._y
	return math.sqrt(dx * dx + dy * dy)
end

function length(path)
	local total = 0
	for i = 2, #path do
		total = total + seg_len(path[i - 1], path[i])
	end
	return total
end

-- cells_per_sec 可以是小数。路程是格子坐标上的长度，耗时向上取整，最少 1 秒
function march_seconds(path, cells_per_sec)
	if not cells_per_sec or cells_per_sec <= 0 then
		return 1
	end
	return math.max(1, math.ceil(length(path) / cells_per_sec))
end

function first_pos(path)
	local p = path[1]
	if not p then
		return 0, 0
	end
	return p._x, p._y
end

function last_pos(path)
	local p = path[#path]
	if not p then
		return 0, 0
	end
	return p._x, p._y
end

function pos_at(path, start_time, end_time, now)
	if now <= start_time then
		return first_pos(path)
	end
	if now >= end_time then
		return last_pos(path)
	end
	local walk = length(path) * (now - start_time) / (end_time - start_time)
	for i = 2, #path do
		local a, b = path[i - 1], path[i]
		local len = seg_len(a, b)
		if walk <= len then
			local rate = len > 0 and walk / len or 0
			return a._x + (b._x - a._x) * rate, a._y + (b._y - a._y) * rate
		end
		walk = walk - len
	end
	return last_pos(path)
end

-- 协议里的 repeated p_pos_f
function to_pto(path)
	local ret = {}
	for i, p in ipairs(path) do
		ret[i] = {x = p._x, y = p._y}
	end
	return ret
end

-- 转成不带 orm 元表的纯 table，跨服务传
function copy(path)
	local ret = {}
	for i, p in ipairs(path) do
		ret[i] = {_x = p._x, _y = p._y}
	end
	return ret
end

-- 线段经过的格子。t0/t1 是在这条线段上的比例。只记录停留时间大于 0 的格子，终点落在新格子上时补一格
local function segment_cells(x0, y0, x1, y1)
	local cells = {}
	local cx = math.floor(x0)
	local cy = math.floor(y0)
	local dx = x1 - x0
	local dy = y1 - y0
	local ex = math.floor(x1)
	local ey = math.floor(y1)
	if dx == 0 and dy == 0 then
		cells[1] = {x = cx, y = cy, t0 = 0, t1 = 1}
		return cells
	end
	local step_x, step_y = 0, 0
	local t_max_x, t_max_y = math.huge, math.huge
	local t_dx, t_dy = math.huge, math.huge
	if dx > 0 then
		step_x = 1
		t_dx = 1 / dx
		t_max_x = (cx + 1 - x0) * t_dx
	elseif dx < 0 then
		step_x = -1
		t_dx = 1 / -dx
		t_max_x = (x0 - cx) * t_dx
	end
	if dy > 0 then
		step_y = 1
		t_dy = 1 / dy
		t_max_y = (cy + 1 - y0) * t_dy
	elseif dy < 0 then
		step_y = -1
		t_dy = 1 / -dy
		t_max_y = (y0 - cy) * t_dy
	end
	local t = 0
	for _ = 1, 512 do
		local t_next = t_max_x < t_max_y and t_max_x or t_max_y
		local go_x = t_max_x < t_max_y
		if t_next > 1 then
			t_next = 1
		end
		if t_next > t then
			cells[#cells + 1] = {x = cx, y = cy, t0 = t, t1 = t_next}
		end
		if t_next >= 1 or (cx == ex and cy == ey) then
			break
		end
		if go_x then
			cx = cx + step_x
			t = t_max_x
			t_max_x = t_max_x + t_dx
		else
			cy = cy + step_y
			t = t_max_y
			t_max_y = t_max_y + t_dy
		end
		if t >= 1 then
			break
		end
	end
	local last = cells[#cells]
	if not last or last.x ~= ex or last.y ~= ey then
		cells[#cells + 1] = {x = ex, y = ey, t0 = 1, t1 = 1}
	end
	return cells
end

-- (t0, t1] 内走过的格子，按进入顺序。enter/leave 是行军时间轴上的时刻
-- 速度再快也按格子列出来，调用方不用逐帧采样
function cells_crossed(path, start_time, end_time, t0, t1)
	if not path or not path[1] or not t1 or not t0 or t1 <= t0 then
		return {}
	end
	if t0 < start_time then
		t0 = start_time
	end
	if t1 > end_time then
		t1 = end_time
	end
	if t1 <= t0 then
		return {}
	end
	local total = length(path)
	local dur = end_time - start_time
	if dur <= 0 or total <= 0 then
		local x, y = first_pos(path)
		return {{x = math.floor(x), y = math.floor(y), enter = t0, leave = t1}}
	end
	local d0 = total * (t0 - start_time) / dur
	local d1 = total * (t1 - start_time) / dur
	local cells = {}
	local walked = 0
	for i = 2, #path do
		local a, b = path[i - 1], path[i]
		local len = seg_len(a, b)
		local seg_end = walked + len
		if len > 0 and seg_end > d0 and walked < d1 then
			local local0 = math.max(0, d0 - walked)
			local local1 = math.min(len, d1 - walked)
			local span = local1 - local0
			local x0 = a._x + (b._x - a._x) * (local0 / len)
			local y0 = a._y + (b._y - a._y) * (local0 / len)
			local x1 = a._x + (b._x - a._x) * (local1 / len)
			local y1 = a._y + (b._y - a._y) * (local1 / len)
			for _, c in ipairs(segment_cells(x0, y0, x1, y1)) do
				local enter_d = walked + local0 + span * c.t0
				local leave_d = walked + local0 + span * c.t1
				local enter_t = start_time + dur * enter_d / total
				local leave_t = start_time + dur * leave_d / total
				local prev = cells[#cells]
				if prev and prev.x == c.x and prev.y == c.y then
					if leave_t > prev.leave then
						prev.leave = leave_t
					end
				else
					cells[#cells + 1] = {x = c.x, y = c.y, enter = enter_t, leave = leave_t}
				end
			end
		end
		walked = seg_end
		if walked >= d1 then
			break
		end
	end
	return cells
end
