local skynet = require "skynet"
local netpack = require "skynet.netpack"
local socket = require "skynet.socket"
CMD = {}
SOCKET = {}
local SLAVE_ADDRESS = {}

local login_port = skynet.getenv("login_port")
local slave_cnt = tonumber(skynet.getenv("slave_cnt"))
local listen_backlog = math.floor(tonumber(skynet.getenv("listen_backlog")) or 32)
if listen_backlog < 1 then
	listen_backlog = 32
end

local address = skynet.getenv("address")

function CMD.shutdown()
	skynet.fork(skynet.exit)
end

function start_login()
	for _ = 1, slave_cnt do
	    table.insert(SLAVE_ADDRESS, skynet.newservice(SERVICE_NAME))
	end
	LOG._debug("login listen on %s:%d backlog=%d", address, login_port, listen_backlog)
	local fd = socket.listen(address or "0.0.0.0", login_port, listen_backlog)
	local balance = 1
	socket.start(fd, function (fd, addr)
		local slave_service = SLAVE_ADDRESS[balance]
		balance = balance + 1
		if balance > slave_cnt then
			balance = 1
		end
		pcall(MASTER_FUNC.accept, slave_service, fd, addr)
	end)
	skynet.dispatch("lua", function (session, address, cmd, ...)
		local f = CMD[cmd] or MASTER_FUNC.CMD[cmd]
		if f then
			local ret = f(...)
			if session ~= 0 then
				skynet.ret(skynet.pack(ret))
			end
		end
	end)
end

function CMD.register_gate(gate, server_id, addr)
	local gate_info = {
		addr = addr,
		srv = gate,
	}
	for _, slave_service in pairs(SLAVE_ADDRESS) do
		skynet.send(slave_service, "lua", "register_gate", server_id, gate_info)
	end
end