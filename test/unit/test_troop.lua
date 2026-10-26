-- 编队：count 是可用兵力，伤兵跟着武将走；校验失败要告诉客户端

local MGR_FILE = "logic/service/agent/module/troop/mgr.lua"
local BASE_FILE = "logic/service/agent/module/troop/base.lua"

local function plain_data(data)
	local march = data._march or {}
	local march_state = march._state or data._march_state or 0
	local t = {
		_user_id = data._user_id,
		_troop_idx = data._troop_idx,
		_pos_tbl = {},
		_troop_state = data._troop_state or (march_state ~= 0 and 1 or 0),
		_march = {
			_state = march_state,
			_target_type = march._target_type or 0,
			_target_id = march._target_id or 0,
			_path = march._path or {},
			_start_time = march._start_time or 0,
			_end_time = march._end_time or 0,
		},
	}
	for pos, info in pairs(data._pos_tbl or {}) do
		t._pos_tbl[pos] = {
			_hero_idx = info._hero_idx,
			_soldier_cnt = info._soldier_cnt,
			_hurt_cnt = info._hurt_cnt,
		}
	end
	return t
end

local function setup(opts)
	opts = opts or {}
	local env = setmetatable({}, {__index = _G})
	assert(loadfile("logic/base/common_class.lua", "t", env))()
	assert(loadfile("logic/base/class.lua", "t", env))()
	local doc = {_troops = opts.troops or {}}
	local user = {soldier = opts.soldier or 100, told = {}, synced = nil}
	function user:get_user_id() return 1 end
	function user:has_birth_pos() return false end
	function user:get_fd() return 7 end
	function user:get_soldier_cnt() return self.soldier end
	function user:set_soldier_cnt(n)
		if n < 0 then
			n = 0
		end
		self.soldier = n
	end
	function user:sync_soldier()
		self.synced = self.soldier
	end
	env.TROOP_MGR = env
	env.MONGO_SLAVE = {COL = {USER_TROOP = "user_troop"}, flush = function() end}
	env.ORM = {
		new = function(_, data) return plain_data(data) end,
		get = function() return doc end,
		load = function() return doc end,
	}
	env.CONST = {MARCH_STATE = {MOVING = 1, ARRIVED = 2}, EVENT = {ON_USER_LOGOUT = 1}}
	env.MARCH_PATH = {}
	env.skynet = {localname = function() end, call = function() end}
	local real_require = require
	env.require = function(name)
		if name == "skynet" then
			return env.skynet
		end
		return real_require(name)
	end
	assert(loadfile(BASE_FILE, "t", env))()
	env.TROOP_BASE = {cls_troop = env.cls_troop}
	env.DATA_COMMON = {
		get_troop_max_cnt = function() return 3 end,
		get_troop_pos_cnt = function() return 3 end,
	}
	env.HERO_MGR = {
		get_hero_by_type = function(_, hero_idx)
			return opts.heroes == nil or opts.heroes[hero_idx]
		end,
	}
	env.USER_MGR = {
		get_user_by_fd = function() return user end,
		get_user_id_by_fd = function() return 1 end,
		tell_me = function(_, msg) user.told[#user.told + 1] = msg end,
	}
	env.EVENT = {listen = function() end}
	env.for_maker = {}
	env.sent = {}
	env.for_caller = {
		s2c_edit_troop = function(_, pkt) env.sent[#env.sent + 1] = {"edit", pkt} end,
		s2c_req_troop = function(_, pkt) env.sent[#env.sent + 1] = {"req", pkt} end,
	}
	assert(loadfile(MGR_FILE, "t", env))()
	env.__init__()
	return env, user
end

local function edit(env, troop_idx, pos_map)
	env.for_maker.c2s_edit_troop(7, {
		troopInfo = {troopIdx = troop_idx, posMap = pos_map},
	})
end

local function kv(pos, hero_idx, count, hurt)
	return {
		key = pos,
		value = {
			heroIdx = hero_idx,
			soldier = {count = count, hurtCount = hurt or 0},
		},
	}
end

local function slot(pto, pos)
	for _, entry in ipairs(pto.posMap) do
		if entry.key == pos then
			return entry.value
		end
	end
end

local T = {}

function T.edit_takes_healthy_from_city()
	local env, user = setup()
	edit(env, 1, {kv(1, 1001, 40, 0)})
	assert(#user.told == 0, "no error")
	assert(user.soldier == 60)
	local pto = env.sent[1][2].troopInfo
	local one = slot(pto, 1)
	assert(one.heroIdx == 1001 and one.soldier.count == 40 and one.soldier.hurtCount == 0)
	local stored = env.get_troop(1, 1):get_pos_tbl()[1]
	assert(stored._soldier_cnt == 40 and stored._hurt_cnt == 0)
end

function T.hurt_stays_when_client_sends_zero()
	local env, user = setup({
		soldier = 50,
		troops = {
			[1] = {
				_user_id = 1,
				_troop_idx = 1,
				_march_state = 0,
				_pos_tbl = {
					[1] = {_hero_idx = 1001, _soldier_cnt = 100, _hurt_cnt = 40},
				},
			},
		},
	})
	edit(env, 1, {kv(1, 1001, 70, 0)})
	assert(#user.told == 0, "hurt above healthy is still valid")
	assert(user.soldier == 40, "only the extra 10 healthy leave the city")
	local one = slot(env.sent[1][2].troopInfo, 1)
	assert(one.soldier.count == 70 and one.soldier.hurtCount == 40)
	local stored = env.get_troop(1, 1):get_pos_tbl()[1]
	assert(stored._soldier_cnt == 110 and stored._hurt_cnt == 40)
end

function T.unknown_hero_is_told_and_kept()
	local env, user = setup({heroes = {}})
	edit(env, 1, {kv(1, 1001, 10, 0)})
	assert(user.told[1] == "没有这个武将")
	assert(#env.sent == 0)
	assert(user.soldier == 100)
	assert(env.get_troop(1, 1) == nil)
end

function T.short_soldiers_are_told()
	local env, user = setup({soldier = 5})
	edit(env, 1, {kv(1, 1001, 10, 0)})
	assert(user.told[1] == "兵力不足")
	assert(user.soldier == 5 and #env.sent == 0)
end

function T.move_hero_from_idle_troop()
	local env, user = setup({
		soldier = 100,
		troops = {
			[2] = {
				_user_id = 1,
				_troop_idx = 2,
				_march_state = 0,
				_pos_tbl = {
					[1] = {_hero_idx = 1001, _soldier_cnt = 30, _hurt_cnt = 0},
				},
			},
		},
	})
	edit(env, 1, {[1] = {heroIdx = 1001, soldier = {count = 30}}})
	assert(#user.told == 0)
	assert(user.soldier == 100)
	assert(env.get_troop(1, 2):get_pos_tbl()[1] == nil)
	local one = slot(env.sent[1][2].troopInfo, 1)
	assert(one.heroIdx == 1001 and one.soldier.count == 30)
	assert(env.sent[2][1] == "req")
end

function T.marching_troop_is_told()
	local env, user = setup({
		troops = {
			[1] = {
				_user_id = 1,
				_troop_idx = 1,
				_march_state = 1,
				_pos_tbl = {
					[1] = {_hero_idx = 1001, _soldier_cnt = 10, _hurt_cnt = 0},
				},
			},
		},
	})
	edit(env, 1, {kv(1, 1001, 10, 0)})
	assert(user.told[1] == "部队在城外")
	assert(user.soldier == 100 and #env.sent == 0)
	assert(env.get_troop(1, 1):get_pos_tbl()[1]._soldier_cnt == 10)
end

function T.clear_returns_healthy_and_hurt()
	local env, user = setup({
		soldier = 10,
		troops = {
			[1] = {
				_user_id = 1,
				_troop_idx = 1,
				_pos_tbl = {
					[1] = {_hero_idx = 1001, _soldier_cnt = 25, _hurt_cnt = 5},
				},
			},
		},
	})
	edit(env, 1, {})
	assert(#user.told == 0)
	assert(user.soldier == 35)
	assert(env.sent[1][2].troopInfo.troopIdx == 1)
	assert(#env.sent[1][2].troopInfo.posMap == 0)
end

function T.proto_roundtrip()
	local protobuf = require "protobuf"
	protobuf.register_file("game_common/pb/common.pb")
	protobuf.register_file("game_common/pb/world.pb")
	local env = setup()
	edit(env, 1, {kv(1, 1001, 40, 0), kv(2, 1002, 15, 0)})
	local pkt = env.sent[1][2]
	local bin = protobuf.encode("World.s2c_edit_troop", pkt)
	local back = protobuf.decode("World.s2c_edit_troop", bin)
	local got = {}
	for _, entry in ipairs(back.troopInfo.posMap) do
		got[entry.key] = entry.value.heroIdx
		assert(entry.value.soldier.count > 0)
	end
	assert(got[1] == 1001 and got[2] == 1002)
end

return T
