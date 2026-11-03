-- 离线工具只读取资源配置，不启动 Skynet，不访问数据库。
local types = assert(loadfile(arg[1], "t", {}))()
local lands = assert(loadfile(arg[2], "t", {}))()
for _, row in pairs(types) do
    print(string.format("enum %s %d", row.Enum, row.Id))
end
for _, row in pairs(lands) do
    print(string.format("land %d %d", row.Type, row.Level))
end
