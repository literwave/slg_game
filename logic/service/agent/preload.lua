local skynet = require "skynet"
local protobuf = require "protobuf"

local DOFILE_LIST = {
	"../logic/service/agent/global.lua",
}

local PROTO_FILE_LIST = {
	"../game_common/pb/common.pb",
	"../game_common/pb/login.pb",
	"../game_common/pb/heartbeat.pb",
	"../game_common/pb/hero.pb",
	"../game_common/pb/skill.pb",
	"../game_common/pb/reward.pb",
	"../game_common/pb/build.pb",
	"../game_common/pb/user.pb",
	"../game_common/pb/lottery.pb",
	"../game_common/pb/item.pb",
	"../game_common/pb/systemopen.pb",
	"../game_common/pb/world.pb",
	"../game_common/pb/city.pb",
	"../game_common/pb/task.pb",
	"../game_common/pb/activity.pb",
	"../game_common/pb/battle.pb",
	"../game_common/pb/report.pb",
	"../game_common/pb/rank.pb",
	"../game_common/pb/alliance.pb",
	"../game_common/pb/chat.pb",
	"../game_common/pb/mail.pb",
}

function __G__TRACKBACK__(msg)
	local bt_info = debug.traceback(tostring(msg), 2)
	print("server lua error", SERVICE_NAME)
	print(bt_info)
	if not LOG then
		return
	end
	LOG._error(bt_info)
	if MONITOR_MGR then
		pcall(MONITOR_MGR.on_error, msg, bt_info)
	end
end

local function system_start_up()
	MONGO_SLAVE.system_startup()
end

local function encode_pack(msg, id, name)
	local pack_data = string.pack(">I2", id) .. protobuf.encode(name, msg)
	pack_data = string.pack(">I2", #pack_data) .. pack_data
	return pack_data
end

local function init_dofile()
	for _, file_info in ipairs(DOFILE_LIST) do
		dofile(file_info)
	end
	for _, proto_file in ipairs(PROTO_FILE_LIST) do
		protobuf.register_file(proto_file)
	end
	-- 这里要优化一下前端发给后端的协议不需要加载进table
	local function create_send_message(id, pack_name)
		return function(fd, data)
			local gate_srv = USER_MGR.get_gate_srv_by_fd(fd)
			skynet.send(gate_srv, "lua", "send_client_pack", fd, encode_pack(data, id, pack_name))
		end
	end
	for pto_name, id in pairs(PTONAME_TO_ID) do
		for_caller[pto_name] = create_send_message(id, ID_TO_PACK_NAME[id])
	end
	math.randomseed(os.time())
	system_start_up()
end

init_dofile()

