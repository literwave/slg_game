local T = {}
function T.agent_preload_registers_skill_messages_for_real_encoding()
    local protobuf = require "protobuf"
    local sent
    local env = setmetatable({for_caller = {}, dofile = function() end,
        math = setmetatable({randomseed = function() end}, {__index = math}),
        MONGO_SLAVE = {system_startup = function() end},
        USER_MGR = {get_gate_srv_by_fd = function() return 123 end},
        require = function(name)
            if name == "skynet" then return {send = function(_, _, _, _, data) sent = data end} end
            if name == "protobuf" then return setmetatable({register_file = function(path)
                protobuf.register_file((path:gsub("^%.%./", "")))
            end}, {__index = protobuf}) end
            return require(name)
        end}, {__index = _G})
    assert(loadfile("game_common/server/net_pb.lua", "t", env))()
    assert(loadfile("logic/service/agent/preload.lua", "t", env))()
    env.for_caller.s2c_sync_skill_data(7, {skillId = 2001, skillLv = 3})
    local value = protobuf.decode("Skill.s2c_sync_skill_data", sent:sub(5))
    assert(value.skillId == 2001 and value.skillLv == 3)
    env.for_caller.s2c_req_all_skill_data(7, {skillList = {{skillId = 2002, skillLv = 5}}})
    value = protobuf.decode("Skill.s2c_req_all_skill_data", sent:sub(5))
    assert(value.skillList[1].skillId == 2002 and value.skillList[1].skillLv == 5)
end
return T
