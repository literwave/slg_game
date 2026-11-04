local zset = require "zset"

server_doc = nil
-- [rank_type] = zset，成员是 user_id 的字符串
rank_tbl = {}

local function entry_tbl(rank_type)
	if rank_type == DATA_COMMON.RANK_TYPE.POWER then
		return server_doc._power_tbl
	end
	if rank_type == DATA_COMMON.RANK_TYPE.CITY_LEVEL then
		return server_doc._city_tbl
	end
	if rank_type == DATA_COMMON.RANK_TYPE.KILL then return server_doc._kill_tbl end
	if rank_type == DATA_COMMON.RANK_TYPE.ALLIANCE_POWER then return server_doc._alliance_power_tbl end
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
		end
		return
	end
	local entry = tbl[user_id]
	if entry and entry._score == score then
		if name then
			entry._name = name
		end
		if head_icon then
			entry._head_icon = head_icon
		end
		return
	end
	tbl[user_id] = {
		_score = score,
		_time = TIME.os_bj_sec(),
		_name = name or (entry and entry._name) or "",
		_head_icon = head_icon or (entry and entry._head_icon) or 0,
	}
	zadd(z, user_id, tbl[user_id])
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
	server_doc = ORM.load(MONGO_SLAVE.COL.SERVER, 1, ORM.CLS_SERVER_DATA)
	for _, rank_type in pairs(DATA_COMMON.RANK_TYPE) do
		build_rank(rank_type)
	end
end
