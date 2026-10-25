local function on_req_user_res(fd)
	local user = USER_MGR.get_user_by_fd(fd)
	local res_list = {}
	for _, res_type in ipairs(CONST.RES_BAR_LIST) do
		table.insert(res_list, make_common_pto_tbl(res_type, user:get_res_num(res_type)))
	end
	for_caller.s2c_req_user_res(fd, {resList = res_list})
end

function __init__()
	for_maker.c2s_req_user_res = on_req_user_res
end