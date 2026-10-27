local skynet = require "skynet"
local socket = require "skynet.socket"
local socketdriver = require "skynet.socketdriver"
local websocket = require "http.websocket"
local protobuf = require "protobuf"
local PROTOCOL = skynet.getenv("protocol")

-- 由 .gated 创建；.gated 只 accept，连接的读写、登录校验、转发都在这里
-- 玩家固定落到 user_id % agent 数 的 agent，换网关重连也是同一个 agent，不会双开

local CMD = {}

CONNECTION = {
	-- [fd] = {agent = *, userId = *}
}

local fd_to_addr = {}
local agent_list = {}
local is_closing = false

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	pack = skynet.pack
}

local handle = {}

local function decode_verify_login_pack(msg)
	if #msg < 4 then
		return nil, "short pack"
	end
	local ok, _, pos = pcall(string.unpack, ">I4", msg)
	if not ok then
		return nil, _
	end
	local decoded, err
	ok, decoded, err = pcall(protobuf.decode, "Login.c2s_verify_login", msg:sub(pos))
	if not ok or not decoded then
		return nil, ok and err or decoded
	end
	return decoded
end

local function encode_login_ok_pack(msg)
	local pack_name = "Login.s2c_user_login_ok"
	local pack_id = PACK_NAME_TO_ID[pack_name]
	if not pack_id then
		return nil, "pack id missing"
	end
	local ok, body = pcall(protobuf.encode, pack_name, msg)
	if not ok then
		return nil, body
	end
	local pack_data = string.pack(">I2", pack_id) .. body
	pack_data = string.pack(">I2", #pack_data) .. pack_data
	return pack_data
end

local function get_user_agent(user_id)
	return agent_list[user_id % #agent_list + 1]
end

local function first_login(packet, fd)
	local token = packet.token
	local user_id = tonumber(packet.userId)
	local passwd = packet.passwd
	local user_info = LREDIS.hgetall(token)
	user_info.userId = tonumber(user_info.userId)
	user_info.serverId = tonumber(user_info.serverId)
	if not user_id or user_id ~= user_info.userId or passwd ~= user_info.passwd then
		skynet.error("token error", user_id)
		websocket.close(fd)
		return
	end
	local agent = get_user_agent(user_id)
	local addr = fd_to_addr[fd]
	skynet.call(agent, "lua", "login", skynet.self(), fd, user_id, addr, user_info.account, user_info.serverId, token)
	CONNECTION[fd] = {
		agent = agent,
		userId = user_id,
	}
	local send_packet, err = encode_login_ok_pack({
		userId = user_id,
		serverId = user_info.serverId,
	})
	if not send_packet then
		skynet.error("login ok encode failed", fd, err)
		websocket.close(fd)
		return
	end
	websocket.write(fd, send_packet, "binary")
	LOG._debug("login ok", user_id, fd)
end

function handle.connect(id)
	print("gate ws connect from: " .. tostring(id))
end

function handle.handshake(id, header, url)
	print("gate ws handshake from: " .. tostring(id), "url", url, "addr:", fd_to_addr[id])
end

function handle.message(fd, msg)
	if is_closing then
		return
	end
	local function error_handler(err)
		skynet.error("handle.message mistake", err)
		skynet.error("stack", debug.traceback())
		return err
	end
	local ok, ret = xpcall(function ()
		local conn = CONNECTION[fd]
		if not conn then
			local packet, err = decode_verify_login_pack(msg)
			if not packet then
				skynet.error("verify login decode failed", fd, err)
				websocket.close(fd)
				return
			end
			first_login(packet, fd)
		else
			skynet.send(conn.agent, "client", fd, msg, conn.userId)
		end
	end, error_handler)
	if not ok then
		skynet.error("handle.message ", fd, "mistake：", ret)
		websocket.close(fd)
	end
end

local function on_conn_lost(id)
	local conn = CONNECTION[id]
	CONNECTION[id] = nil
	fd_to_addr[id] = nil
	if conn then
		skynet.send(conn.agent, "lua", "disconnect", id, conn.userId)
	end
end

function handle.close(id, code, reason)
	on_conn_lost(id)
	print("gate ws close from: " .. tostring(id), code, reason)
end

function handle.error(id)
	on_conn_lost(id)
	print("gate ws error from: " .. tostring(id))
end

function CMD.init(list)
	agent_list = list
end

-- 连接整个生命周期都在这里阻塞，.gated 必须用 send
function CMD.accept(fd, addr)
	if is_closing then
		socket.close_fd(fd)
		return
	end
	fd_to_addr[fd] = addr
	-- websocket 帧头和负载分两次 write，不关 Nagle 每个回包都要等对端 40ms 延迟 ACK
	socketdriver.nodelay(fd)
	websocket.accept(fd, handle, PROTOCOL, addr)
end

-- agent 在 login 过程中就会推包，此时 CONNECTION 还没登记，不能按它过滤。
-- 连接已关时 websocket.write 会断言，这里丢掉这一包，避免打崩 gate_worker
function CMD.send_client_pack(fd, packet)
	if is_closing then
		return
	end
	pcall(websocket.write, fd, packet, "binary")
end

function CMD.kick(fd)
	websocket.close(fd)
end

-- 关服第一步：不再转发新消息，agent 那边才能安心下线存盘
function CMD.stop_forward()
	is_closing = true
end

-- 关服最后一步：agent 已经都下线了，清掉连接表再断开，不会再给 agent 发 disconnect
function CMD.shutdown()
	is_closing = true
	local fd_list = {}
	for fd in pairs(CONNECTION) do
		fd_list[#fd_list + 1] = fd
	end
	CONNECTION = {}
	for _, fd in ipairs(fd_list) do
		websocket.close(fd)
	end
	skynet.fork(skynet.exit)
end

skynet.start(function()
	dofile "../logic/service/gated/preload.lua"
	skynet.dispatch("lua", function (session, address, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("gate_worker unknown cmd", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
end)
