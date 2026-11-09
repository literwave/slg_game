-- lua-orm：按 schema 校验赋值，改动时把所在文档标脏，dump 出可直接写 mongo 的纯 table
-- 对象本体是空表，字段存在 nodes[obj].vals 里，这样每次赋值都会进 __newindex

local M = {}

local ATOMS = {
	number = {name = "number", atom = true, default = 0, conv = tonumber},
	string = {name = "string", atom = true, default = "", conv = tostring},
	boolean = {name = "boolean", atom = true, default = false, conv = function(v) return v == true end},
}

local classes = {}
local nodes = setmetatable({}, {__mode = "k"})	-- obj -> {cls, vals, parent, col, key, dirty}
local docs = {}		-- col -> key -> root
local dirty_list = {}
local dirty_head, dirty_tail = 1, 0

local function resolve(def, name)
	local t = def.type
	if ATOMS[t] then
		return ATOMS[t]
	end
	if t == "struct" then
		local cls = {name = name, kind = "struct", attrs = {}}
		for k, attr in pairs(def.attrs) do
			cls.attrs[k] = resolve(attr, name .. "." .. k)
		end
		return cls
	end
	if t == "map" or t == "list" then
		local key = t == "list" and ATOMS.number or resolve(def.key, name .. ".key")
		if not key.atom then
			error(string.format("cls<%s> map key must be atom", name))
		end
		return {name = name, kind = t, key = key, value = resolve(def.value or def.item, name .. ".value")}
	end
	local ref = classes[t]
	if not ref then
		error(string.format("cls<%s> ref unknown type<%s>, define it first", name, t))
	end
	return ref
end

function M.init(type_list)
	classes = {}
	for _, def in ipairs(type_list) do
		if classes[def.name] or ATOMS[def.name] then
			error(string.format("cls<%s> redefined", def.name))
		end
		classes[def.name] = resolve(def, def.name)
	end
	M.inited = true
end

local function mark_dirty(obj)
	local n = nodes[obj]
	while n.parent do
		obj = n.parent
		n = nodes[obj]
	end
	if n.col == nil or n.dirty then
		return
	end
	n.dirty = true
	dirty_tail = dirty_tail + 1
	dirty_list[dirty_tail] = obj
	if M.on_dirty then
		M.on_dirty()
	end
end

local new_obj

local function conform(cls, v, where)
	if cls.atom then
		local ret = cls.conv(v)
		if ret == nil then
			error(string.format("%s need<%s>, give<%s>", where, cls.name, tostring(v)))
		end
		return ret
	end
	local n = nodes[v]
	if n then
		if n.cls ~= cls then
			error(string.format("%s need<%s>, give<%s>", where, cls.name, n.cls.name))
		end
		return v
	end
	return new_obj(cls, v)
end

local function setfield(obj, k, v)
	local n = nodes[obj]
	local cls = n.cls
	local v_cls
	if cls.kind == "struct" then
		v_cls = cls.attrs[k]
		if not v_cls then
			error(string.format("cls<%s> has no attr<%s>", cls.name, tostring(k)))
		end
		if v == nil and not v_cls.atom then
			v = {}
		end
	else
		k = conform(cls.key, k, cls.name .. ".key")
		v_cls = cls.value
	end
	if v ~= nil then
		v = conform(v_cls, v, cls.name .. "." .. tostring(k))
	end
	local old = n.vals[k]
	if old == v then
		return
	end
	if nodes[old] then
		nodes[old].parent = nil
	end
	if nodes[v] then
		nodes[v].parent = obj
	end
	n.vals[k] = v
	mark_dirty(obj)
end

local function getfield(obj, k)
	local n = nodes[obj]
	local v = n.vals[k]
	if v == nil and n.cls.kind == "struct" then
		local attr = n.cls.attrs[k]
		return attr and attr.default
	end
	return v
end

local MT = {
	__index = getfield,
	__newindex = setfield,
	__pairs = function(obj)
		return next, nodes[obj].vals, nil
	end,
	__len = function(obj)
		return #nodes[obj].vals
	end,
}

new_obj = function(cls, data)
	if data ~= nil and type(data) ~= "table" then
		error(string.format("cls<%s> data<%s> is not table", cls.name, tostring(data)))
	end
	local obj = setmetatable({}, MT)
	nodes[obj] = {cls = cls, vals = {}}
	if cls.kind == "struct" then
		for k, attr in pairs(cls.attrs) do
			local v = data and data[k]
			if v ~= nil or not attr.atom then
				obj[k] = v
			end
		end
	elseif data then
		for k, v in pairs(data) do
			obj[k] = v
		end
	end
	return obj
end

-- data 已经是该类型的 orm 对象时原样返回
function M.new(cls_name, data)
	local cls = classes[cls_name]
	if not cls then
		error(string.format("orm.new: unknown cls<%s>", tostring(cls_name)))
	end
	local n = nodes[data]
	if n and n.cls == cls then
		return data
	end
	return new_obj(cls, data)
end

-- 把根对象登记为 col/key 文档，之后改动会进脏列表
function M.bind(obj, col, key)
	local n = nodes[obj]
	assert(n and not n.parent, "orm.bind: need a root orm object")
	assert(col and key ~= nil, "orm.bind: col and key required")
	n.col, n.key = col, key
	docs[col] = docs[col] or {}
	docs[col][key] = obj
end

function M.get(col, key)
	return docs[col] and docs[col][key]
end

-- 只是不再登记，已经标脏的改动仍会刷出去
function M.unbind(col, key)
	if docs[col] then
		docs[col][key] = nil
	end
end

function M.touch(obj)
	mark_dirty(obj)
end

-- 纯 table；number key 的 map 转成字符串 key，list 按数组输出
function M.dump(obj)
	local n = nodes[obj]
	if not n then
		return obj
	end
	local ret = {}
	if n.cls.kind == "list" then
		for i, v in ipairs(n.vals) do
			ret[i] = M.dump(v)
		end
		return ret
	end
	local str_key = n.cls.kind == "map" and n.cls.key == ATOMS.number
	for k, v in pairs(n.vals) do
		ret[str_key and tostring(k) or k] = M.dump(v)
	end
	return ret
end

-- 取走所有脏文档：{ {col, key, dat}, ... }
function M.has_dirty()
	return dirty_head <= dirty_tail
end

function M.drain(limit)
	assert(limit == nil or type(limit) == "number" and limit >= 0 and limit % 1 == 0,
		"orm.drain limit must be a non-negative integer")
	local ret = {}
	local last = limit and math.min(dirty_tail, dirty_head + limit - 1) or dirty_tail
	-- Snapshot the whole selected batch before removing any root. A serialization
	-- error must leave earlier roots dirty too, since no batch reached the caller.
	for index = dirty_head, last do
		local root = dirty_list[index]
		local n = nodes[root]
		ret[#ret + 1] = {col = n.col, key = n.key, dat = M.dump(root)}
	end
	for index = dirty_head, last do
		nodes[dirty_list[index]].dirty = nil
		dirty_list[index] = nil
	end
	dirty_head = last + 1
	if dirty_head > dirty_tail then
		dirty_list = {}
		dirty_head, dirty_tail = 1, 0
	end
	return ret
end

return M
