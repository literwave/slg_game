local skynet = require "skynet"
require "skynet.manager"

local CMD = {}

function CMD.shutdown()
	skynet.fork(skynet.exit)
end

function CMD.hot_update(path_list)
	return hot_update(path_list)
end

function CMD.set_score(rank_type, user_id, score, name, head_icon)
	RANK_MGR.set_score(rank_type, user_id, score, name, head_icon)
end

function CMD.get_rank_list(rank_type, start, count, self_id)
	return RANK_MGR.get_rank_list(rank_type, start, count, self_id)
end

function CMD.get_rank(rank_type, user_id)
	return RANK_MGR.get_rank(rank_type, user_id)
end

skynet.start(function()
	LOG._debug("boot activity success")
	dofile "../logic/service/activity/preload.lua"
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("activity no callback", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
	skynet.register(".activity")
end)
