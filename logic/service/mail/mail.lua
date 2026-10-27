local skynet = require "skynet"
require "skynet.manager"

-- 邮件。客户端协议由 agent 转过来，这里处理完直接回包；领奖由 agent 调 take_rewards

local CMD = {}

function CMD.shutdown()
	MONGO_SLAVE.flush_sync()
	skynet.fork(skynet.exit)
end

function CMD.hot_update(path_list)
	return hot_update(path_list)
end

function CMD.client(pto_name, user_id, packet)
	local handler = for_maker[pto_name]
	if not handler then
		skynet.error("mail no handler", pto_name)
		return
	end
	handler(user_id, packet)
end

function CMD.take_rewards(user_id, kind_uid_list)
	return MAIL_MGR.take_rewards(user_id, kind_uid_list)
end

function CMD.send_user_mail(user_id, mail_id, detail_list, reward_list)
	MAIL_MGR.send_user_mail(user_id, mail_id, detail_list, reward_list)
end

function CMD.send_group_mail(user_id_list, mail_id, detail_list, reward_list)
	MAIL_MGR.send_group_mail(user_id_list, mail_id, detail_list, reward_list)
end

function CMD.send_srv_mail(mail_id, detail_list, reward_list)
	MAIL_MGR.send_srv_mail(mail_id, detail_list, reward_list)
end

skynet.start(function()
	dofile "../logic/service/mail/preload.lua"
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = CMD[cmd]
		if not f then
			skynet.error("mail no callback", cmd)
			return
		end
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
	skynet.register(".mail")
	LOG._debug("boot mail success")
end)
