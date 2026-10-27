local skynet = require "skynet"
require "skynet.manager"

-- 只做战斗计算，不存数据。数量由配置 battle_cnt 决定，按目标 id 取模分配，同一目标永远进同一个服务
local idx = ...

local CMD = {}

function CMD.shutdown()
	skynet.fork(skynet.exit)
end

function CMD.hot_update(path_list)
	return hot_update(path_list)
end

function CMD.fight_batch(def_side, atk_list)
	return FIGHT_MGR.fight_batch(def_side, atk_list, math.random)
end

skynet.start(function()
	dofile "../logic/service/battle/preload.lua"
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("battle no callback", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
	skynet.register(".battle" .. idx)
	LOG._debug("boot battle success", idx)
end)
