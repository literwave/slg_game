-- 静态地图包校验与存档版本绑定。此模块不连接数据库，便于离线测试。
local M = {}
local names = {"mapRes_0.lua", "campaign-map.lua", "terrain.lua"}

local function is_revision(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function quote(value)
    assert(not value:find("\0", 1, true), "map path contains NUL")
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function read_table(path)
    -- 地图模块只能返回数据，不能调用 os/io/require 修改运行环境。
    local value = assert(loadfile(path, "t", {}))()
    assert(type(value) == "table", "map file must return a table: " .. path)
    return value
end

function M.verify_resource_config(requirements, directory)
    if not requirements then
        return -- 兼容现有 schemaVersion=2 快照
    end
    local types = read_table(directory .. "/ResLandType.lua")
    local lands = read_table(directory .. "/ResLand.lua")
    local enums, levels = {}, {}
    for _, row in pairs(types) do
        enums[row.Enum] = row.Id
    end
    for _, row in pairs(lands) do
        levels[row.Type .. ":" .. row.Level] = true
    end
    for _, requirement in ipairs(requirements) do
        assert(enums[requirement.enum] == requirement.type, "map resource enum mismatch: " .. requirement.enum)
        for _, level in ipairs(requirement.levels) do
            assert(levels[requirement.type .. ":" .. level], "map resource level missing: " .. requirement.enum .. ":" .. level)
        end
    end
end

function M.load(directory, expected_revision, config_directory)
    local manifest = read_table(directory .. "/manifest.lua")
    assert(manifest.schemaVersion == 2 or manifest.schemaVersion == 4, "map must be a fixed client snapshot; rebuild with make map")
    if manifest.schemaVersion == 4 then
        assert(manifest.sourceMode == "client-snapshot", "map source is not a fixed client snapshot")
        assert(type(manifest.clientCommit) == "string" and (#manifest.clientCommit == 40 or #manifest.clientCommit == 64)
            and manifest.clientCommit:match("^[0-9a-f]+$"), "map lacks client Git commit")
    end
    assert(is_revision(manifest.mapRevision), "invalid map revision")
    assert(type(manifest.width) == "number" and type(manifest.height) == "number", "missing map size")
    if expected_revision then
        assert(is_revision(expected_revision) and expected_revision == manifest.mapRevision, "configured map revision mismatch")
    end
    local args = {}
    for _, name in ipairs(names) do
        assert(is_revision(manifest.files[name]), "missing map file checksum: " .. name)
        args[#args + 1] = quote(directory .. "/" .. name)
    end
    -- Linux/WSL 的 coreutils，在加载百万格 Lua 前一次性验证三个文件。
    local pipe = assert(io.popen("sha256sum -- " .. table.concat(args, " "), "r"))
    local output = pipe:read("*a")
    local ok = pipe:close()
    assert(ok, "sha256sum failed while validating map package")
    local i = 0
    for line in output:gmatch("[^\n]+") do
        i = i + 1
        local hash = line:match("^([0-9a-f]+)%s")
        assert(names[i] and hash == manifest.files[names[i]], "map checksum mismatch: " .. tostring(names[i]))
    end
    assert(i == #names, "incomplete map checksum result")
    if config_directory then
        M.verify_resource_config(manifest.resourceRequirements, config_directory)
    end
    local resources = read_table(directory .. "/mapRes_0.lua")
    local terrain = read_table(directory .. "/terrain.lua")
    assert(resources.w == manifest.width and resources.h == manifest.height, "map size mismatch")
    assert(terrain.width == manifest.width and terrain.height == manifest.height, "terrain size mismatch")
    return manifest, resources, terrain
end

function M.binding(manifest, stored, has_players, legacy_revision)
    if stored then
        assert(stored.mapRevision == manifest.mapRevision, "world save is bound to another map revision; map replacement requires an explicit migration")
        assert(stored.width == manifest.width and stored.height == manifest.height, "world map dimensions changed")
        return nil
    end
    -- 升级前的世界没有版本记录，只允许认领升级时冻结的原地图。
    if has_players then
        assert(legacy_revision == manifest.mapRevision, "existing world must first bind its original map; refusing to adopt a new layout")
    end
    return {schemaVersion = 1, mapRevision = manifest.mapRevision, width = manifest.width, height = manifest.height}
end

return M
