local skynet = require "skynet"

-- 用法：LOG._info("user %s login", user_id)；参数是表会展开
-- 只有一个参数或格式化失败时按空格拼接，不会因为日志本身报错
-- 配置 log_level = "info" 可关掉 debug

local LEVEL_TBL = {
	debug = 1,
	info = 2,
	warn = 3,
	error = 4,
}

local min_level = LEVEL_TBL[skynet.getenv("log_level") or "debug"] or LEVEL_TBL.debug
local SERVICE_INFO = SERVICE_NAME

local function to_str(v)
	if type(v) == "table" then
		return table2str(v)
	end
	return tostring(v)
end

local function format_msg(fmt, ...)
	local n = select("#", ...)
	if n == 0 then
		return to_str(fmt)
	end
	local args = table.pack(...)
	for i = 1, n do
		if type(args[i]) == "table" then
			args[i] = table2str(args[i])
		end
	end
	-- 没有 % 时按 skynet.error 那样空格拼接。string.format 会丢掉用不上的参数，不能拿成功与否判断
	if type(fmt) == "string" and fmt:find("%", 1, true) then
		local ok, msg = pcall(string.format, fmt, table.unpack(args, 1, n))
		if ok then
			return msg
		end
	end
	local str_list = {to_str(fmt)}
	for i = 1, n do
		str_list[#str_list + 1] = tostring(args[i])
	end
	return table.concat(str_list, " ")
end

local SRC_PREFIX = "../logic/service/"

local function src_of(info)
	local src = info and info.short_src or "?"
	if src:sub(1, #SRC_PREFIX) == SRC_PREFIX then
		return src:sub(#SRC_PREFIX + 1)
	end
	return src
end

-- 栈：调用方 -> _xxx -> write
local function write(level, fmt, ...)
	if LEVEL_TBL[level] < min_level then
		return
	end
	local info = debug.getinfo(3, "Sl")
	local line = string.format("[%s] [%s] %s %s:%s %s",
		os.date("%Y-%m-%d %H:%M:%S"), string.upper(level), SERVICE_INFO,
		src_of(info), info and info.currentline or "?",
		format_msg(fmt, ...))
	skynet.send(".gamelog", "lua", "log", level, line)
end

function _debug(...)
	write("debug", ...)
end

function _info(...)
	write("info", ...)
end

function _warn(...)
	write("warn", ...)
end

function _error(...)
	write("error", ...)
end

function debug_print(...)
	write("debug", ...)
end

-- 热更时 common_class 逐个打印保留下来的模块变量
function update_file(...)
	write("debug", ...)
end

-- 资源流水，一行一条，tab 分隔：
-- 时间  user_id  id  变化量  变化后数量  reason_list(逗号分隔)
-- kind: diamond / res / item / hero，分别写 flow_<kind>_<日期>.log
function _flow(kind, user_id, id, change, after, reason_list)
	local reason_str = "-"
	if reason_list and reason_list[1] then
		local str_list = {}
		for i, v in ipairs(reason_list) do
			str_list[i] = tostring(v)
		end
		reason_str = table.concat(str_list, ",")
	end
	local line = table.concat({
		os.date("%Y-%m-%d %H:%M:%S"),
		tostring(user_id),
		tostring(id),
		tostring(change),
		tostring(after),
		reason_str,
	}, "\t")
	skynet.send(".gamelog", "lua", "flow", kind, line)
end
