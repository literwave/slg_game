-- ORM 写盘只使用幂等的 set/unset/delete；重试不会重复扣费或发奖。
local M = {}

function M.compact(commands)
	local result, full = {}, {}
	for _, cmd in ipairs(commands) do
		assert(cmd.key ~= nil, "missing document key")
		assert(cmd.op_type == "$set" or cmd.op_type == "$unset" or cmd.op_type == "del_doc",
			"unsupported persistence operation")
		if cmd.op_type == "$set" and cmd.field_str == "dat" then
			-- 同一文档没有穿插局部更新/删除时，前一份整包已被后一份完整覆盖。
			if full[cmd.key] then result[full[cmd.key]] = false end
			full[cmd.key] = #result + 1
		else
			full[cmd.key] = nil
		end
		result[#result + 1] = cmd
	end
	local out = {}
	for _, cmd in ipairs(result) do
		if cmd then out[#out + 1] = cmd end
	end
	return out
end

function M.operation(cmd)
	if cmd.op_type == "del_doc" then
		return "delete", {q = {_id = cmd.key}, limit = 1}
	end
	assert(type(cmd.field_str) == "string" and cmd.field_str ~= "", "missing update field")
	local value = cmd.value
	if cmd.op_type == "$unset" then value = "" end
	return "update", {
		q = {_id = cmd.key},
		u = {[cmd.op_type] = {[cmd.field_str] = value}},
		upsert = cmd.op_type == "$set",
		multi = false,
	}
end

return M
