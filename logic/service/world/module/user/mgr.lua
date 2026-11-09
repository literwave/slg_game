local skynet = require "skynet"

fd_to_user_id = {
	-- [vfd] = userId
}
user_id_to_fd = {
	-- [userId] = fd
}
fd_to_gate_srv = {
	-- [fd] = gateSrv
}

function get_user_id_by_vfd(fd)
	return fd_to_user_id[fd]
end

function del_user_id_by_vfd(fd)
	fd_to_user_id[fd] = nil
end

function get_fd_by_user_id(user_id)
	return user_id_to_fd[user_id]
end

function get_user_id_by_fd(fd)
	return fd_to_user_id[fd]
end

function get_gate_srv_by_fd(fd)
	return fd_to_gate_srv[fd]
end

local function module_on_user_logout(user_id)
	AOI_MGR.clear_focus(user_id)
end

function disconnect(fd, user_id)
	if fd_to_user_id[fd] == user_id then
		del_user_id_by_vfd(fd)
		fd_to_gate_srv[fd] = nil
	end
	-- A delayed logout from the replaced connection must not clear the new view.
	if user_id_to_fd[user_id] ~= fd then return end
	user_id_to_fd[user_id] = nil
	module_on_user_logout(user_id)
end

function ref_login(user_id, fd, gate_srv)
	user_id_to_fd[user_id] = fd
	fd_to_user_id[fd] = user_id
	fd_to_gate_srv[fd] = gate_srv
end

function module_on_user_login(user, is_first_login)
end

function on_user_login(user_id, fd, gate_srv, is_first_login)
	LOG._debug("world login success", user_id, gate_srv, is_first_login)
	local old_fd = user_id_to_fd[user_id]
	if old_fd and old_fd ~= fd then
		if fd_to_user_id[old_fd] == user_id then
			del_user_id_by_vfd(old_fd)
			fd_to_gate_srv[old_fd] = nil
		end
		-- Seen entities belong to a client connection, not the persistent user.
		AOI_MGR.clear_focus(user_id)
	end
	ref_login(user_id, fd, gate_srv)
end

function on_user_logout(user_id, fd)
	LOG._debug("world logout success", user_id, fd)
	disconnect(fd, user_id)
end

function kick_user(fd, user_id)
	disconnect(fd, user_id)
end

function __init__()
	EVENT.register(CONST.EVENT.ON_USER_LOGIN)
	EVENT.register(CONST.EVENT.ON_USER_LOGOUT)
	EVENT.register(CONST.EVENT.KICK_USER)
end