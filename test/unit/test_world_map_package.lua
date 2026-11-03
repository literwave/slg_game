local maps = require "world_map_package"
local revision = string.rep("a", 64)
local another = string.rep("b", 64)
local manifest = {mapRevision = revision, width = 1000, height = 1000}
local T = {}

function T.new_world_binds_once()
    local stored = maps.binding(manifest, nil, false, another)
    assert(stored.mapRevision == revision)
    assert(maps.binding(manifest, stored, true, another) == nil)
end

function T.bound_world_rejects_another_map()
    local ok = pcall(maps.binding, manifest, {mapRevision = another, width = 1000, height = 1000}, true, revision)
    assert(not ok)
end

function T.bound_world_rejects_dimension_change()
    assert(not pcall(maps.binding, manifest, {mapRevision = revision, width = 200, height = 200}, false, revision))
end

function T.legacy_world_only_adopts_original_map()
    assert(maps.binding(manifest, nil, true, revision).mapRevision == revision)
    assert(not pcall(maps.binding, manifest, nil, true, another))
end

local function quote(value)
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function fixture(callback)
    local directory = os.tmpname()
    os.remove(directory)
    assert(os.execute("mkdir -- " .. quote(directory)))
    local function write(name, text)
        local f = assert(io.open(directory .. "/" .. name, "wb"))
        f:write(text); f:close()
    end
    local sources = {
        ["mapRes_0.lua"] = "return {w=2,h=2,list={[0]={52,1}},emptyCells={}}",
        ["campaign-map.lua"] = "return {cities={},gates={}}",
        ["terrain.lua"] = "return {width=2,height=2,blockedCells={},reservedCityCells={}}",
    }
    local hashes = {}
    for name, source in pairs(sources) do
        write(name, source)
        local p = assert(io.popen("sha256sum -- " .. quote(directory .. "/" .. name)))
        hashes[name] = p:read("*l"):match("^([0-9a-f]+)")
        assert(p:close())
    end
    local rows = {}
    for name, hash in pairs(hashes) do
        rows[#rows + 1] = string.format("[%q]=%q", name, hash)
    end
    write("manifest.lua", string.format("return {schemaVersion=4,sourceMode='client-snapshot',clientCommit=%q,mapRevision=%q,width=2,height=2,files={%s}}", string.rep("c", 40), revision, table.concat(rows, ",")))
    local ok, err = pcall(callback, directory, write)
    for name in pairs(sources) do os.remove(directory .. "/" .. name) end
    os.remove(directory .. "/manifest.lua")
    os.remove(directory)
    assert(ok, err)
end

function T.load_verifies_hashes_and_zero_based_cells()
    fixture(function(directory)
        local m, resources = maps.load(directory, revision)
        assert(m.mapRevision == revision and resources.list[0][1] == 52)
    end)
end

function T.corrupt_file_cannot_load()
    fixture(function(directory, write)
        write("terrain.lua", "return {width=2,height=2}")
        local ok, err = pcall(maps.load, directory, revision)
        assert(not ok and err:match("checksum mismatch"))
    end)
end

function T.configured_version_cannot_drift()
    fixture(function(directory)
        local ok, err = pcall(maps.load, directory, another)
        assert(not ok and err:match("revision mismatch"))
    end)
end

function T.map_lua_cannot_access_os()
    fixture(function(directory, write)
        write("manifest.lua", "return os.getenv('HOME')")
        assert(not pcall(maps.load, directory, revision))
    end)
end

function T.old_seed_generated_package_is_rejected()
    fixture(function(directory, write)
        write("manifest.lua", "return {schemaVersion=3}")
        local ok, err = pcall(maps.load, directory, revision)
        assert(not ok and err:match("fixed client snapshot"))
    end)
end

return T
