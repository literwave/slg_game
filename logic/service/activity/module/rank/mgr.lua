local zset = require "zset"

-- Each persisted document is one (rank_type, user_id), independent of board size.
rank_entries = {}
-- [rank_type] = zset，成员是 user_id 的字符串
rank_tbl = {}

local function entry_tbl(rank_type)
	return rank_entries[rank_type]
end

local function doc_key(rank_type, user_id)
	return string.format("%d:%d", rank_type, user_id)
end

-- 同分时 zset 的反向排名里 ts 小的靠前，传达到分数的时间，先到的排前面
local function zadd(z, user_id, entry)
	z:add(entry._score, tostring(user_id), entry._time)
end

function set_score(rank_type, user_id, score, name, head_icon)
	local tbl = entry_tbl(rank_type)
	local z = rank_tbl[rank_type]
	if not tbl or not z or not user_id then
		return
	end
	if score <= 0 then
		if tbl[user_id] then
			tbl[user_id] = nil
			z:rem(tostring(user_id))
			MONGO_SLAVE.del_doc(MONGO_SLAVE.COL.RANK_ENTRY, doc_key(rank_type, user_id))
		end
		return
	end
	local entry = tbl[user_id]
	if entry and entry._score == score then
		if (name == nil or name == entry._name) and (head_icon == nil or head_icon == entry._head_icon) then
			return
		end
	end
	-- Never mutate a queued snapshot: an earlier save may be awaiting its ACK.
	-- Save/delete/re-add all go through the same ordered producer queue.
	local updated = {
		_rank_type = rank_type,
		_user_id = user_id,
		_score = score,
		_time = entry and entry._score == score and entry._time or TIME.os_bj_sec(),
		_name = name or (entry and entry._name) or "",
		_head_icon = head_icon or (entry and entry._head_icon) or 0,
	}
	tbl[user_id] = updated
	if not entry or entry._score ~= score then zadd(z, user_id, updated) end
	MONGO_SLAVE.save_doc(MONGO_SLAVE.COL.RANK_ENTRY, doc_key(rank_type, user_id), updated)
end

local function item_of(rank, user_id, entry)
	return {rank = rank, uid = user_id, name = entry._name, head_icon = entry._head_icon, score = entry._score}
end

-- 名次从 1 起；返回 {list, self}，自己没上榜时 rank = 0、score = 0
function get_rank_list(rank_type, start, count, self_id)
	local tbl = entry_tbl(rank_type)
	local z = rank_tbl[rank_type]
	if not tbl or not z then
		return
	end
	local list = {}
	local total = math.min(z:count(), DATA_COMMON.get_rank_max(rank_type))
	start = math.max(1, math.floor(start or 1))
	count = math.max(0, math.floor(count or 0))
	if start <= total then
		local last = math.min(total, start + count - 1)
		for i, member in ipairs(z:rev_range(start, last)) do
			local user_id = tonumber(member)
			list[#list + 1] = item_of(start + i - 1, user_id, tbl[user_id])
		end
	end
	local self_rank = {rank = 0, uid = self_id, name = "", head_icon = 0, score = 0}
	if tbl[self_id] then
		self_rank = item_of(get_rank(rank_type, self_id), self_id, tbl[self_id])
	end
	return {list = list, self = self_rank}
end

-- 没上榜返回 0
function get_rank(rank_type, user_id)
	local z = rank_tbl[rank_type]
	if not z then
		return 0
	end
	local rank = z:rev_rank(tostring(user_id)) or 0
	return rank <= DATA_COMMON.get_rank_max(rank_type) and rank or 0
end

local function build_rank(rank_type)
	local z = zset.new()
	for user_id, entry in pairs(entry_tbl(rank_type)) do
		zadd(z, user_id, entry)
	end
	rank_tbl[rank_type] = z
end

function __init__()
	MONGO_SLAVE.system_startup()
	-- Startup reads only the new collection; old SERVER/1 data is not migrated.
	local saved = MONGO_SLAVE.common_load_tbl(MONGO_SLAVE.COL.RANK_ENTRY)
	for _, rank_type in pairs(DATA_COMMON.RANK_TYPE) do
		rank_entries[rank_type] = {}
	end
	for key, entry in pairs(saved) do
		local tbl = rank_entries[entry._rank_type]
		assert(tbl and key == doc_key(entry._rank_type, entry._user_id), "invalid rank entry identity")
		assert(type(entry._score) == "number" and type(entry._time) == "number", "invalid rank entry score/time")
		assert(type(entry._name) == "string" and type(entry._head_icon) == "number", "invalid rank entry profile")
		if entry._score > 0 then tbl[entry._user_id] = entry end
	end
	for _, rank_type in pairs(DATA_COMMON.RANK_TYPE) do
		build_rank(rank_type)
	end
end
