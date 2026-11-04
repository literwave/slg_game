-- activity/rank/mgr.lua：zset 排名，同分先到的靠前，重启后从持久化分数重建

local MGR_FILE = "logic/service/activity/module/rank/mgr.lua"

local POWER = 1

local function setup(doc)
	local env = setmetatable({}, {__index = _G})
	local clock = {now = 1000}
	doc = doc or {_power_tbl = {}, _city_tbl = {}, _kill_tbl = {}, _alliance_power_tbl = {}}
	env.DATA_COMMON = {RANK_TYPE = dofile("game_common/server/enum/RankTypeEnum.lua"),
		get_rank_max = function(kind) return kind == 4 and 50 or 100 end}
	env.TIME = {os_bj_sec = function() return clock.now end}
	env.ORM = {load = function() return doc end}
	env.MONGO_SLAVE = {COL = {}, system_startup = function() end}
	assert(loadfile(MGR_FILE, "t", env))()
	env.__init__()
	return env, doc, clock
end

local T = {}

function T.higher_score_first()
	local M = setup()
	M.set_score(POWER, 1, 100)
	M.set_score(POWER, 2, 300)
	M.set_score(POWER, 3, 200)
	assert(M.get_rank(POWER, 2) == 1 and M.get_rank(POWER, 3) == 2 and M.get_rank(POWER, 1) == 3)
	assert(M.get_rank(POWER, 99) == 0, "not on board")
end

function T.tie_earlier_first_and_update_moves()
	local M, _, clock = setup()
	M.set_score(POWER, 1, 100)
	clock.now = 2000
	M.set_score(POWER, 2, 100)
	assert(M.get_rank(POWER, 1) == 1, "reached first ranks higher")
	clock.now = 3000
	M.set_score(POWER, 2, 150)
	assert(M.get_rank(POWER, 2) == 1 and M.get_rank(POWER, 1) == 2)
	M.set_score(POWER, 2, 0)
	assert(M.get_rank(POWER, 2) == 0 and M.get_rank(POWER, 1) == 1, "score 0 leaves board")
end

function T.rebuild_from_doc()
	local _, doc = setup()
	doc._power_tbl[1] = {_score = 100, _time = 5}
	doc._power_tbl[2] = {_score = 100, _time = 3}
	local M = setup(doc)
	assert(M.get_rank(POWER, 2) == 1 and M.get_rank(POWER, 1) == 2)
end

function T.rank_list_page_and_self()
	local M, _, clock = setup()
	for uid = 1, 5 do
		clock.now = clock.now + 1
		M.set_score(POWER, uid, uid * 100, "p" .. uid, uid)
	end
	local ret = M.get_rank_list(POWER, 2, 2, 1)
	assert(#ret.list == 2)
	assert(ret.list[1].rank == 2 and ret.list[1].uid == 4 and ret.list[1].name == "p4")
	assert(ret.list[2].rank == 3 and ret.list[2].uid == 3 and ret.list[2].head_icon == 3)
	assert(ret.self.rank == 5 and ret.self.score == 100)
	assert(#M.get_rank_list(POWER, 6, 10, 1).list == 0, "start past the end")
	assert(#M.get_rank_list(POWER, 4, 10, 1).list == 2, "page cut at the end")
	local outsider = M.get_rank_list(POWER, 1, 10, 99).self
	assert(outsider.rank == 0 and outsider.score == 0 and outsider.uid == 99)
end

function T.name_kept_when_score_changes()
	local M = setup()
	M.set_score(POWER, 1, 100, "old", 1)
	M.set_score(POWER, 1, 100, "new", 2)
	M.set_score(POWER, 1, 200)
	local item = M.get_rank_list(POWER, 1, 1, 1).list[1]
	assert(item.name == "new" and item.head_icon == 2 and item.score == 200)
end

function T.new_boards_limit_and_restart()
	local M, doc = setup()
	for uid = 1, 105 do M.set_score(3, uid, uid, "p" .. uid, 1) end
	for uid = 1, 55 do M.set_score(4, uid, uid * 10, "a" .. uid, 0) end
	assert(#M.get_rank_list(3, 1, 200, 1).list == 100)
	assert(M.get_rank_list(3, 1, 20, 1).self.rank == 0)
	assert(M.get_rank_list(3, 1, 20, 1).self.score == 1, "未上榜仍带真实分数")
	assert(#M.get_rank_list(4, 45, 20, 55).list == 6)
	assert(#M.get_rank_list(4, 51, 20, 55).list == 0)
	local restarted = setup(doc)
	assert(restarted.get_rank(4, 55) == 1)
	restarted.set_score(4, 55, 0)
	assert(restarted.get_rank(4, 55) == 0)
end

return T
