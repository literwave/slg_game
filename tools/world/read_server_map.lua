-- 离线读取指定服务端地图，先校验文件哈希；不启动 Skynet，不访问存档。
local root, directory = assert(arg[1]), assert(arg[2])
package.path = root .. "/lualib/?.lua;" .. package.path
local package_reader = require "world_map_package"
local manifest, resources, terrain = package_reader.load(directory, nil, root .. "/game_common/server/res")
local world = assert(loadfile(directory .. "/campaign-map.lua", "t", {}))()

local function string_json(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        if char == '"' then return '\\"' end
        if char == '\\' then return '\\\\' end
        return string.format('\\u%04x', char:byte())
    end) .. '"'
end

local function encode(value)
    if type(value) == "string" then return string_json(value) end
    if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
    if value == nil then return "null" end
    assert(type(value) == "table", "unsupported map value")
    local length, count, is_array = #value, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then is_array = false end
    end
    is_array = is_array and count == length
    local result = {}
    if is_array then
        for i = 1, length do result[i] = encode(value[i]) end
        return "[" .. table.concat(result, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do result[#result + 1] = string_json(tostring(key)) .. ":" .. encode(value[key]) end
    return "{" .. table.concat(result, ",") .. "}"
end

-- 零起始资源键不能交给 #list；显式按尺寸读取，缺格直接失败。
local ordered = {}
for cell = 0, resources.w * resources.h - 1 do ordered[cell + 1] = assert(resources.list[cell], "missing resource cell") end
resources.list = ordered
io.write(encode({resources = resources, terrain = terrain, world = world, mapRevision = manifest.mapRevision}))
