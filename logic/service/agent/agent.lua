local skynet = require "skynet"
local queue = require "skynet.queue"
local protobuf = require "protobuf"

local CMD = {}
local RPC_CMD = {}

local user_queues = {
	-- [userId] = queue(),
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

local function get_user_queue(user_id)
	local user_queue = user_queues[user_id]
	if not user_queue then
		user_queue = queue()
		user_queues[user_id] = user_queue
	end
	return user_queue
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

local is_closing = false

-- 和协议、下线走同一个玩家队列，避免登录和旧连接下线交错
function CMD.login(gate_srv, fd, user_id, addr, account, server_id, token)
	assert(not is_closing, "server is closing")
	return get_user_queue(user_id)(do_login, gate_srv, fd, user_id, addr, account, server_id, token)
end

local function do_disconnect(fd, user_id)
	-- 顶号后旧连接的断开：玩家已经在新 fd 上，只清旧 fd
	if USER_MGR.get_fd_by_user_id(user_id) ~= fd then
		if USER_MGR.get_user_id_by_fd(fd) == user_id then
			USER_MGR.del_user_id_by_vfd(fd)
		end
		return
	end
	USER_MGR.disconnect(fd, user_id)
	-- 新连接的消息要等 login 返回后 worker 才会转发，这里删掉不会和新登录并发
	user_queues[user_id] = nil
end

-- 进玩家的消息队列里下线，等正在处理的协议跑完再存盘
function CMD.disconnect(fd, user_id)
	get_user_queue(user_id)(do_disconnect, fd, user_id)
end

function CMD.hot_update(path_list)
	return hot_update(path_list)
end

function CMD.set_open_time(t)
	GAME.set_open_time(t)
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

function CMD.encounter_result(user_id, troop_idx, pack)
	local defer = get_user_queue(user_id)(function()
		return BATTLE_MGR.on_encounter(user_id, troop_idx, pack)
	end)
	if defer then
		skynet.timeout(0, function()
			get_user_queue(user_id)(defer)
		end)
	end
end

function CMD.aoi_push(user_id, pack)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	MARCH_MGR.on_aoi_push(fd, pack)
end

function CMD.shutdown()
	is_closing = true
	local online = {}
	for user_id, fd in pairs(USER_MGR.user_id_to_fd) do
		online[user_id] = fd
	end
	for user_id, fd in pairs(online) do
		CMD.disconnect(fd, user_id)
	end
	MONGO_SLAVE.flush_sync()
	skynet.fork(skynet.exit)
end

local function sub_item_list_recv(id, taddr, user_id, item_list, reason_list)
	if not ITEM_MGR.check_cost_enough(user_id, item_list) then
		skynet.send(taddr, "rpc", id, false)
		return
	end
	local ok = skynet.call(taddr, "rpc", id, true)
	if not ok then
		return
	end
	assert(ITEM_MGR.del_cost_list(user_id, item_list, reason_list))
end

function RPC_CMD.sub_item_list(id, user_id, taddr, item_list, reason_list)
	if not ITEM_MGR.check_cost_enough(user_id, item_list) then
		skynet.send(taddr, "rpc", id, false)
		return
	end
	local q = queue()
	local ok = q(sub_item_list_recv, id, taddr, user_id, item_list, reason_list)
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
		local ok, err = xpcall(get_user_queue(user_id), error_handler, function()
			if USER_MGR.get_fd_by_user_id(user_id) ~= fd then
				return
			end
			handler(fd, msg)
		end)
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