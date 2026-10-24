-- 迁城占格：先占新格子，失败时旧格子仍占用

local function load_map()
	local env = setmetatable({}, {__index = _G})
	local const = {}
	assert(loadfile("logic/define/const.lua", "t", const))()
	env.CONST = const
	assert(loadfile("logic/base/common_class.lua", "t", env))()
	assert(loadfile("logic/base/class.lua", "t", env))()
	local bitset = setmetatable({
		CONST = const,
		cls_object = env.cls_object,
		Super = env.Super,
	}, {__index = env})
	assert(loadfile("logic/service/world/module/bit_set/base.lua", "t", bitset))()
	env.Import = function()
		return bitset
	end
	assert(loadfile("logic/service/world/module/map/base.lua", "t", env))()
	return env
end

local function new_map(env)
	local map = env.cls_map:New({_width = 3, _height = 3})
	map:set_block(1)
	for idx = 2, 9 do
		assert(map:allow_birth(idx))
	end
	return map
end

local T = {}

function T.move_releases_old_cell()
	local map = new_map(load_map())
	assert(map:hold_birth_idx(2))
	assert(map:relocate_birth(2, 3))
	assert(map:hold_birth_idx(2))
	assert(not map:hold_birth_idx(3))
end

function T.blocked_cell_keeps_old()
	local map = new_map(load_map())
	assert(map:hold_birth_idx(2))
	assert(not map:relocate_birth(2, 1))
	assert(not map:relocate_birth(2, 99))
	assert(map:hold_birth_idx(4))
	assert(not map:relocate_birth(2, 4))
	assert(not map:hold_birth_idx(2))
end

function T.same_cell_stays()
	local map = new_map(load_map())
	assert(map:hold_birth_idx(5))
	assert(map:relocate_birth(5, 5))
	assert(not map:hold_birth_idx(5))
end

function T.birth_uses_any_free_cell()
	local map = new_map(load_map())
	assert(map:mark_spawn(2))
	local got = {}
	for _ = 1, 8 do
		local idx = map:alloc_birth_idx()
		assert(idx and idx ~= 1 and not got[idx])
		got[idx] = true
	end
	assert(map:alloc_birth_idx() == nil)
	assert(map:relocate_birth(2, 2))
	assert(not map:alloc_birth_idx())
	map:release_birth_idx(4)
	assert(map:alloc_birth_idx() == 4)
end

function T.wild_skips_spawn_slot()
	local map = new_map(load_map())
	assert(map:mark_spawn(2))
	local got = {}
	for _ = 1, 7 do
		local wild = map:alloc_wild_idx()
		assert(wild and wild ~= 2 and not got[wild])
		got[wild] = true
	end
	assert(map:alloc_wild_idx() == nil)
	assert(map:alloc_birth_idx() == 2)
end

return T
