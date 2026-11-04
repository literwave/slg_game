local skynet = require "skynet"
local queue = require "skynet.queue"
require "skynet.manager"

local MONGODB = nil
local CMD = {}
-- 读写按到达顺序串行：同一文档的旧整包不会盖掉新整包，重新登录也读不到没写完的旧数据
local cs = queue()

function CMD.shutdown()
	MONGODB:disconnect()
	skynet.fork(skynet.exit)
end

function CMD.start()
	MONGODB = MONGO_OBJ.cls_mongo_db:New()
end

function CMD.insert(args)
	return MONGODB:insert(args)
end

function CMD.insert_batch(args)
	return MONGODB:insert_batch(args)
end

function CMD.delete(args)
	return MONGODB:delete(args)
end

function CMD.find_one(args)
	return MONGODB:find_one(args)
end

function CMD.find_all(args)
	return MONGODB:find_all(args)
end

function CMD.update(args)
	return MONGODB:update(args)
end

function CMD.save_data(all_cmd_tbl)
	return MONGODB:save_data(GAME.get_data_base(), all_cmd_tbl)
end

function CMD.chat_append(args)
	return MONGODB:chat_append(args)
end

skynet.start(function()
	dofile "../logic/service/main_mongodb/preload.lua"
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = CMD[cmd]
		if not f then
			error(string.format("Unknown command %s", tostring(cmd)))
		end
		local ret = cs(f, ...)
		if session ~= 0 then
			skynet.ret(skynet.pack(ret))
		end
	end)
	skynet.register ".mongodb"
end)
