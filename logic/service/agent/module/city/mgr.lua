local function query(fd, cmd, id)
    local uid = USER_MGR.get_user_id_by_fd(fd)
    if not uid then return end
    local result, err = MARCH_MGR.world_call(cmd, id)
    if USER_MGR.get_fd_by_user_id(uid) ~= fd then return end
    if not result then
        USER_MGR.tell_me(uid, err or "城池数据暂不可用")
        result = cmd == "req_city_list" and {cityList = {}} or {rankList = {}}
    end
    for_caller["s2c_" .. cmd](fd, result)
end

function __init__()
    for_maker.c2s_req_city_list = function(fd) query(fd, "req_city_list") end
    for_maker.c2s_req_city_info = function(fd, packet) query(fd, "req_city_info", packet.entityId or 0) end
end
