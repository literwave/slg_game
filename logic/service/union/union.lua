local skynet = require "skynet"
require "skynet.manager"

-- 联盟 + 聊天。客户端协议由 agent 带上玩家名片转过来，这里处理完直接回包

local CMD = {}

function CMD.shutdown()
	MONGO_SLAVE.flush_sync()
	skynet.fork(skynet.exit)
end

function CMD.hot_update(path_list)
	return hot_update(path_list)
end

-- brief = {uid, name, head_icon, level, power}；packet 是解码后的协议，默认值字段可能为 nil
function CMD.client(pto_name, brief, packet)
	USER_MGR.update_brief(brief)
	local handler = for_maker[pto_name]
	if not handler then
		skynet.error("union no handler", pto_name)
		return
	end
	handler(brief.uid, packet)
end

function CMD.update_brief(brief)
	USER_MGR.update_brief(brief)
	ALLIANCE_MGR.on_brief_change(brief)
end

skynet.start(function()
	dofile "../logic/service/union/preload.lua"
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("union no callback", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
	skynet.register(".union")
	LOG._debug("boot union success")
end)
