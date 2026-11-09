local skynet = require "skynet"
local queue = require "skynet.queue"
local protobuf = require "protobuf"

local CMD = {}
local RPC_CMD = {}
local is_closing = false
local offline_retries = {}
local pending_continuations = {}

local user_queues = {
	-- [userId] = {lock = queue(), active = running and waiting calls},
}

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = skynet.unpack
}

skynet.register_protocol {
	name = "rpc",
	id = skynet.PTYPE_RPC,
	unpack = skynet.unpack
}

-- 坏包、未知协议号、pb 解码失败都只丢掉这一包，不能抛到 skynet.dispatch
local function decode_pack(packet)
	local ok, id, pos = pcall(string.unpack, ">I2", packet, 3)
	if not ok then
		return nil, nil, id
	end
	local pto_name = ID_TO_PTONAME[id]
	local pack_name = ID_TO_PACK_NAME[id]
	if not pack_name then
		return nil, nil, string.format("unknown proto %s", id)
	end
	local msg, err
	ok, msg, err = pcall(protobuf.decode, pack_name, packet:sub(pos))
	if not ok or not msg then
		return nil, pto_name, ok and err or msg
	end
	return msg, pto_name
end

local get_user_queue
local function retry_offline_cleanup(user_id, err)
    if is_closing then return end
    local retry = offline_retries[user_id]
    if not retry then
        retry = {}
        offline_retries[user_id] = retry
        skynet.error("offline cache retained for persistence retry: " .. tostring(err))
    end
    if retry.scheduled then return end
    retry.scheduled = true
    skynet.timeout(100, function()
        if is_closing or offline_retries[user_id] ~= retry then return end
        retry.scheduled = false
        local ok, failure = pcall(function() get_user_queue(user_id)(function() end) end)
        if not ok then retry_offline_cleanup(user_id, failure) end
    end)
end

get_user_queue = function(user_id, allow_closing)
    assert(not is_closing or allow_closing, "server is closing")
    local entry = user_queues[user_id]
    if not entry then
        entry = {lock = queue(), active = 0, depth = 0}
        entry.run = function(fn, ...)
            -- Count waiters too; keep one lock until the last call has finished.
            entry.active = entry.active + 1
            local result = table.pack(pcall(entry.lock, function(...)
                entry.depth = entry.depth + 1
                local outcome = table.pack(pcall(fn, ...))
                entry.depth = entry.depth - 1
                if entry.depth == 0 then
                    if not USER_MGR.get_fd_by_user_id(user_id) then
                        local saved, failure = pcall(USER_MGR.release_offline_cache, user_id)
                        if saved then offline_retries[user_id] = nil
                        else retry_offline_cleanup(user_id, failure) end
                    else
                        offline_retries[user_id] = nil
                    end
                end
                if not outcome[1] then error(outcome[2], 0) end
                return table.unpack(outcome, 2, outcome.n)
            end, ...))
            entry.active = entry.active - 1
            if entry.active == 0 and user_queues[user_id] == entry then user_queues[user_id] = nil end
            if not result[1] then error(result[2], 0) end
            return table.unpack(result, 2, result.n)
        end
        user_queues[user_id] = entry
    end
    return entry.run
end

-- 顶号：旧连接可能在另一个 gate_worker 上，先解绑旧 fd 再踢，之后旧 fd 的 disconnect 会被忽略
local function kick_old_conn(user_id, new_fd)
	local old_fd = USER_MGR.get_fd_by_user_id(user_id)
	if not old_fd or old_fd == new_fd then
		return
	end
	local user = USER_MGR.get_user_by_id(user_id)
	local old_gate_srv = user and user:get_gate_srv()
	USER_MGR.del_user_id_by_vfd(old_fd)
	if old_gate_srv then
		skynet.send(old_gate_srv, "lua", "kick", old_fd)
	end
	LOG._debug("relogin kick old conn", user_id, old_fd, new_fd)
end

local function do_login(gate_srv, fd, user_id, addr, account, server_id, token)
	LOG._debug("login step 3-agent", fd, user_id, addr, account)
	kick_old_conn(user_id, fd)
	local user = false
	local is_first_login = false
	if USER_MGR.is_new_user(user_id) then
		user = USER_MGR.create_new_user(gate_srv, fd, user_id, server_id)
		is_first_login = true
	else
		user = USER_MGR.try_init_user(user_id)
		USER_MGR.ref_login(user_id, fd, user)
		user:set_fd(fd)
		user:set_gate_srv(gate_srv)
	end
	user:set_token(token)
	user:set_account(account)
	user:set_login_addr(addr)
	local cross = USER_MGR.module_on_user_login(user, is_first_login)
	EVENT.fire(CONST.EVENT.ON_USER_LOGIN, user_id, fd, gate_srv, is_first_login)
	-- 各模块在 ON_USER_LOGIN 里加载好数据后再补发离线期间的跨周期
	USER_MGR.dispatch_cross(user_id, cross)
end

-- 和协议、下线走同一个玩家队列，避免登录和旧连接下线交错
function CMD.login(gate_srv, fd, user_id, addr, account, server_id, token)
	assert(not is_closing, "server is closing")
    return get_user_queue(user_id)(function(...)
        assert(not is_closing, "server is closing")
        return do_login(...)
    end, gate_srv, fd, user_id, addr, account, server_id, token)
end

local function do_disconnect(fd, user_id)
	-- 顶号后旧连接的断开：玩家已经在新 fd 上，只清旧 fd
	if USER_MGR.get_fd_by_user_id(user_id) ~= fd then
		if USER_MGR.get_user_id_by_fd(fd) == user_id then
			USER_MGR.del_user_id_by_vfd(fd)
		end
		return
	end
	return USER_MGR.disconnect(fd, user_id)
end

-- 进玩家的消息队列里下线，等正在处理的协议跑完再存盘
function CMD.disconnect(fd, user_id)
    return get_user_queue(user_id)(do_disconnect, fd, user_id)
end

function CMD.kick_user(fd, user_id, from_heart_beat)
    return get_user_queue(user_id)(USER_MGR.kick_user_in_queue, fd, user_id, from_heart_beat)
end

function CMD.performance_stats()
    if skynet.getenv("performance_metrics") ~= "1" then return {enabled = false} end
    local function size(tbl)
        local n = 0
        for _ in pairs(tbl) do n = n + 1 end
        return n
    end
    local active_calls = 0
    for _, entry in pairs(user_queues) do active_calls = active_calls + entry.active end
    return {enabled = true,
        users = size(USER_MGR.all_user_tbl), hero_users = size(HERO_MGR.user_hero_tbl),
        item_users = size(ITEM_MGR.all_item_tbl), item_uid_users = size(ITEM_MGR.all_item_uid_tbl),
        item_kind_users = size(ITEM_MGR.all_item_kind_tbl),
        player_queues = size(user_queues), player_queue_calls = active_calls,
        offline_cache_retries = size(offline_retries),
        pending_continuations = size(pending_continuations)}
end

function CMD.hot_update(path_list)
	return hot_update(path_list)
end

function CMD.set_open_time(t)
	GAME.set_open_time(t)
end

function CMD.public_user_profile(user_id)
	return USER_MGR.get_public_profile(user_id)
end

function CMD.march_arrive(user_id, troop_idx, end_time)
	get_user_queue(user_id)(function()
		MARCH_MGR.on_arrive(user_id, troop_idx, end_time)
	end)
end

-- 其它服务扣玩家消耗（创建联盟扣令牌等），只扣在线玩家
function CMD.cost_items(user_id, cost_list, reason_list)
	return get_user_queue(user_id)(function()
		if not USER_MGR.get_fd_by_user_id(user_id) then
			return false
		end
		return ITEM_MGR.del_cost_list(user_id, cost_list, reason_list)
	end)
end

function CMD.gather_full(user_id, troop_idx, end_time)
	get_user_queue(user_id)(function()
		MARCH_MGR.on_gather_full(user_id, troop_idx, end_time)
	end)
end

function CMD.occupy_done(user_id, troop_idx, gather_end)
	get_user_queue(user_id)(function()
		MARCH_MGR.on_occupy_done(user_id, troop_idx, gather_end)
	end)
end

function CMD.land_displaced(user_id, troop_idx, entity_id)
	get_user_queue(user_id)(function()
		MARCH_MGR.on_land_displaced(user_id, troop_idx, entity_id)
	end)
end

function CMD.encounter_snap(user_id, troop_idx)
	return get_user_queue(user_id)(function()
		return BATTLE_MGR.snap_troop(user_id, troop_idx)
	end)
end

local function consume_continuation(item)
    if not pending_continuations[item] or item.claimed then return end
    item.claimed = true
    -- This narrowly admits an already accepted continuation while closing.
    local ok, err = pcall(function() get_user_queue(item.user_id, true)(item.run) end)
    pending_continuations[item] = nil
    item.run = nil
    if not ok then error(err, 0) end
end

function CMD.encounter_result(user_id, troop_idx, pack)
    get_user_queue(user_id)(function()
        local defer = BATTLE_MGR.on_encounter(user_id, troop_idx, pack)
        if defer then
            -- Register before the outer queue can yield for its offline save ACK.
            -- The battle continuation re-reads the troop and checks its stamp.
            local item = {user_id = user_id, run = defer}
            pending_continuations[item] = true
            skynet.timeout(0, function() consume_continuation(item) end)
        end
    end)
end

function CMD.aoi_push(user_id, pack)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	MARCH_MGR.on_aoi_push(fd, pack)
end

function CMD.city_push(user_id, pto_name, packet)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if fd and (pto_name == "s2c_sync_city" or pto_name == "s2c_city_occupy") then
		for_caller[pto_name](fd, packet)
	end
end

function CMD.shutdown()
    is_closing = true
    -- Cold logins/offline jobs can be suspended before a connection is bound.
    -- Drain every existing queue, not just the currently connected player map.
    local pending = {}
    for user_id in pairs(user_queues) do pending[user_id] = true end
    for user_id in pairs(offline_retries) do pending[user_id] = true end
    for user_id in pairs(USER_MGR.all_user_tbl) do pending[user_id] = true end
    for user_id in pairs(pending) do get_user_queue(user_id, true)(function() end) end
    -- An admitted battle may register its immediate follow-up while the first
    -- barrier waits. A timer may already own it; then wait for that user's queue.
    while next(pending_continuations) do
        local batch = {}
        for item in pairs(pending_continuations) do batch[#batch + 1] = item end
        for _, item in ipairs(batch) do
            if pending_continuations[item] then
                if item.claimed then get_user_queue(item.user_id, true)(function() end)
                else consume_continuation(item) end
            end
        end
    end
    local online = {}
    for user_id, fd in pairs(USER_MGR.user_id_to_fd) do online[user_id] = fd end
    for user_id, fd in pairs(online) do get_user_queue(user_id, true)(do_disconnect, fd, user_id) end
    MONGO_SLAVE.flush_sync()
    skynet.fork(skynet.exit)
end

local function sub_item_list_recv(id, taddr, user_id, item_list, reason_list)
    local user, fd = USER_MGR.get_user_by_id(user_id), USER_MGR.get_fd_by_user_id(user_id)
    if not user or not fd or not ITEM_MGR.check_cost_enough(user_id, item_list) then
		skynet.send(taddr, "rpc", id, false)
		return
	end
	local ok = skynet.call(taddr, "rpc", id, true)
    if not ok or USER_MGR.get_user_by_id(user_id) ~= user or USER_MGR.get_fd_by_user_id(user_id) ~= fd then
        return
    end
    assert(ITEM_MGR.del_cost_list(user_id, item_list, reason_list))
end

function RPC_CMD.sub_item_list(id, user_id, taddr, item_list, reason_list)
    return get_user_queue(user_id)(sub_item_list_recv, id, taddr, user_id, item_list, reason_list)
end

local function error_handler(err)
	skynet.error("agent error：", err)
	skynet.error("stack: ", debug.traceback())
	return err
end

skynet.start(function()
	dofile "../logic/service/agent/preload.lua"
	skynet.dispatch("lua", function(seesion, _ , command, ...)
		local f = CMD[command]
		if seesion ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)

	skynet.dispatch("client", function(seesion, address, fd, packet, user_id)
		if is_closing then
			return
		end
		local msg, pto_name, err = decode_pack(packet)
		if not msg then
			skynet.error("decode client pack failed", fd, user_id, pto_name, err)
			return
		end
		assert(fd)
		if not for_maker[pto_name] then
			skynet.error("ptoName not registerptoName", pto_name)
			return
		end
		-- 分发数据；执行时再确认 fd 仍是当前连接，顶号后旧连接残留的包丢掉
		local handler = for_maker[pto_name]
		local queued_at, started_at = skynet.now(), nil
		local ok, err = xpcall(get_user_queue(user_id), error_handler, function()
			if USER_MGR.get_fd_by_user_id(user_id) ~= fd then
				return
			end
			started_at = skynet.now()
			handler(fd, msg)
		end)
		local finished_at = skynet.now()
		if started_at and finished_at - queued_at >= 10 then
			-- Log timings only: no player data or request payloads.
			skynet.error(string.format("slow client protocol=%s queue_ms=%d handler_ms=%d ok=%s",
				tostring(pto_name), (started_at - queued_at) * 10,
				(finished_at - started_at) * 10, tostring(ok)))
		end
		if not ok then
			LOG._error("userQueue error: %s", err)
		end
	end)

		skynet.dispatch("rpc", function(seesion, address, command,...)
			local f = RPC_CMD[command]
			if seesion ~= 0 then
				skynet.ret(skynet.pack(f(...)))
			else
				f(...)
			end
	end)
end)
