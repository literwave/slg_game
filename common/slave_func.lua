local skynet = require "skynet"
local protobuf = require "protobuf"
local websocket = require "http.websocket"
local socketdriver = require "skynet.socketdriver"
local crypt = require "client.crypt"
local PROTOCOL = skynet.getenv("protocol")

local TOKEN_EXPIRED_TIME = 300
CMD = {}

SERVER_TBL = {
	-- [serverId] =
	-- 	{gateInfo, gateInfo}
}

local function try_get_gate_info(server_id)
	local gate_list = SERVER_TBL[server_id]
	if not gate_list then
		return nil
	end
	return gate_list[math.random(1, #gate_list)]
end

local acc_type2_module = {
	[1] = Import("../logic/service/logind/module/login/pc.lua"),
	-- [2] = Import("../logic/module/login/wechat.lua")
}

function CMD.shutdown()
	skynet.exit()
end

local function decode_login_pack(msg)
	if #msg < 4 then
		return nil, "short pack"
	end
	local ok, _, pos = pcall(string.unpack, ">I4", msg)
	if not ok then
		return nil, _
	end
	local decoded, err
	ok, decoded, err = pcall(protobuf.decode, "Login.c2s_user_login", msg:sub(pos))
	if not ok or not decoded then
		return nil, ok and err or decoded
	end
	return decoded
end

local function encode_login_pack(msg)
	local pack_name = "Login.s2c_user_login"
	local pack_data = string.pack(">I2", PACK_NAME_TO_ID[pack_name]) .. protobuf.encode(pack_name, msg)
	pack_data = string.pack(">I2", #pack_data) .. pack_data
	return pack_data
end

local handle = {}

function handle.connect(id)
	LOG._debug("logind ws connect from: %s", tostring(id))
end

function handle.handshake(id, header, url)
	local addr = websocket.addrinfo(id)
	LOG._debug("logind ws handshake from: %s url %s addr: %s", tostring(id), url, addr)
end

function handle.message(id, msg)
	local login_info, err = decode_login_pack(msg)
	if not login_info then
		skynet.error("login decode failed", id, err)
		websocket.close(id)
		return
	end
	local login_module = acc_type2_module[login_info.accountType]
	if login_module then
		login_module.on_user_login(login_info)
	end
	login_info.serverId = tonumber(login_info.serverId)
	local gate_info = try_get_gate_info(login_info.serverId)
	if not gate_info then
		skynet.error("auth error: ", login_info.serverId, login_info.userId)
		websocket.close(id)
		return
	end
	local token = string.format("%s@%s:%s", crypt.base64encode(tostring(login_info.userId)),
		crypt.base64encode(tostring(login_info.serverId)),
		crypt.base64encode(login_info.passwd)
	)
	LOG._debug("loginInfo:", login_info.userId)
	local token_tbl = {
		userId = login_info.userId,
		passwd = login_info.passwd,
		serverId = login_info.serverId,
		account = login_info.account,
	}
	LREDIS.hmset(token, token_tbl, TOKEN_EXPIRED_TIME)
	local pack = {
		accountType = login_info.accountType,
		appId =  login_info.appId,
		cchid = login_info.cchid,
		account = login_info.account,
		passwd = login_info.passwd,
		gateAddr = gate_info.addr,
		token = token,
		userId = login_info.userId,
	}
	websocket.write(id, encode_login_pack(pack), "binary")
	LOG._debug("login succ", login_info.userId, token)
	websocket.close(id)
end

function handle.close(id, code, reason)
	LOG._debug("logind ws close from:", id, code, reason)
end

function handle.error(id)
	skynet.error("logind ws error from:", id,
		"handshake failed; connect with ws://host:33021 not raw TCP/HTTP")
end

function CMD.auth(fd, addr)
	LOG._debug("login step 1-auth", fd, addr)
	skynet.fork(function()
		socketdriver.nodelay(fd)
		local ok, err = websocket.accept(fd, handle, PROTOCOL, addr)
		if not ok then
			skynet.error("login error", fd, addr, err)
		end
	end)
end

function CMD.create_user_ok(account, user_id)
	ACCOUNT.create_account(account, user_id)
end

function CMD.register_gate(server_id, gate_info)
	if not SERVER_TBL[server_id] then
		SERVER_TBL[server_id] = {}
	end
	table.insert(SERVER_TBL[server_id], gate_info)
end

