local skynet = require "skynet"

fd_to_user_id = {
	-- [fd] = user_id
}
user_id_to_fd = {
	-- [user_id] = fd
}
fd_to_gate_srv = {
	-- [fd] = gate_srv
}

function get_fd_by_user_id(user_id)
	return user_id_to_fd[user_id]
end

function get_user_id_by_fd(fd)
	return fd_to_user_id[fd]
end

function get_gate_srv_by_fd(fd)
	return fd_to_gate_srv[fd]
end

function ref_login(user_id, fd, gate_srv)
	user_id_to_fd[user_id] = fd
	fd_to_user_id[fd] = user_id
	fd_to_gate_srv[fd] = gate_srv
end

function disconnect(fd, user_id)
	fd_to_user_id[fd] = nil
	user_id_to_fd[user_id] = nil
	fd_to_gate_srv[fd] = nil
end

function on_user_login(user_id, fd, gate_srv, is_first_login)
	LOG._debug("activity login success", user_id, gate_srv, is_first_login)
	ref_login(user_id, fd, gate_srv)
end

function on_user_logout(user_id, fd)
	LOG._debug("activity logout success", user_id, fd)
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
