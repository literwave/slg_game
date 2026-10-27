local skynet = require "skynet"

local function get_user_tbl(account)
	local raw = LREDIS.hgetall(account)
	local user_tbl = {}
	for user_id, flag in pairs(raw) do
		user_tbl[tonumber(user_id)] = flag
	end
	return user_tbl
end

function query_user_id(account, user_id)
	local user_tbl = get_user_tbl(account)
	return user_tbl[user_id]
end

function create_account(account, user_id)
	LREDIS.hset(account, user_id, 1)
end

local function fetch_user_id()
	return skynet.call(".game_sid", "lua", "fetch_user_id")
end

function sdk_login_ok(login_info)
	local account = login_info.account
	-- local userId = loginInfo.userId
	local user_tbl = get_user_tbl(account)
	local user_id = next(user_tbl)
	if not user_id then
		LOG._debug("user new create")
		user_id = fetch_user_id()
		login_info.userId = user_id
		create_account(account, user_id)
	else
		login_info.userId = user_id
	end
	-- 先不支持一个账号多个用户，先预留功能吧
	-- if userId == "" then
	-- 	skynet.error("user create")
	-- 	userId = fetchUserId()
	-- 	loginInfo.userId = userId
	-- 	createAccount(account, userId)
	-- else
	-- 	skynet.error("user load")
	-- 	local ret = queryUserId(account, userId)
	-- 	skynet.error("ret: ", ret)
	-- 	assert(ret, "user load error")
	-- end
end