-- 支持连续行数组和按 Id 导出的稀疏表；不能用 ipairs 截断编号空档之后的配置。
local M = {}
function M.index_by_id(data)
    local first = next(data) and select(2, next(data))
    if type(first) ~= "table" or first.Id == nil then return data end
    local indexed = {}
    for _, row in pairs(data) do
        assert(type(row) == "table" and row.Id ~= nil, "mixed config row shape")
        assert(indexed[row.Id] == nil, "duplicate config Id " .. tostring(row.Id))
        indexed[row.Id] = row
    end
    return indexed
end
function M.validate_city_guards(tables)
    for kind, levels in pairs(tables.City or {}) do
        for level, city in pairs(levels) do
            for _, slot in ipairs(city.Team or {}) do
                assert(tables.Monster and tables.Monster[slot.mid],
                    string.format("City[%s][%s] missing guard %s", kind, level, tostring(slot.mid)))
            end
        end
    end
end
return M
