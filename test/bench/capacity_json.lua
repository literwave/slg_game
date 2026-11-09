-- Small output-only JSON encoder for test reports; no runtime dependency.
local M = {}
local function quoted(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        if char == '"' then return '\\"' end
        if char == '\\' then return '\\\\' end
        return string.format('\\u%04x', char:byte())
    end) .. '"'
end
function M.encode(value)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "non-finite JSON number")
        return tostring(value)
    end
    if kind == "string" then return quoted(value) end
    assert(kind == "table", "unsupported JSON value")
    local count, array = 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false end
    end
    local parts = {}
    if array and count > 0 and count == #value then
        for index = 1, count do parts[index] = M.encode(value[index]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for key, item in pairs(value) do parts[#parts + 1] = quoted(tostring(key)) .. ':' .. M.encode(item) end
    return '{' .. table.concat(parts, ',') .. '}'
end
return M
