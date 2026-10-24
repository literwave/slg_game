local skynet = require "skynet"
local P = require "bench_proto"

-- 一个服务跑一批机器人，每个机器人一个协程一条连接
-- 每个请求发出后等对应的回包再发下一个，延迟就是这一来一回的时间

-- 只读查询，服务端都会回对应包
local QUERY_LIST = {
	{"c2s_req_system_open", "s2c_req_system_open"},
	{"c2s_user_base_info", "s2c_user_base_info"},
	{"c2s_req_user_res", "s2c_req_user_res"},
	{"c2s_req_troop", "s2c_req_troop"},
	{"c2s_req_all_hero_base_info", "s2c_req_all_hero_base_info"},
	{"c2s_req_march_list", "s2c_req_march_list"},
	{"c2s_req_task_list", "s2c_req_task_list", {taskType = 0}},
	{"c2s_req_activity_list", "s2c_req_activity_list"},
	{"c2s_req_mail_list", "s2c_req_mail_list", {mailKind = 1}},
	{"c2s_req_rank_list", "s2c_req_rank_list", {rankType = 1, start = 1, count = 20}},
	{"c2s_req_report_list", "s2c_req_report_list", {reportType = 0}},
	{"c2s_req_my_alliance", "s2c_req_my_alliance"},
	{"c2s_req_alliance_list", "s2c_req_alliance_list", {start = 1, count = 20}},
	{"c2s_req_chat_list", "s2c_req_chat_list", {channel = 1, targetId = 0}},
}
local HEART_BEAT = {"c2s_heart_beat", "s2c_heart_beat"}
local LOAD_OK = {"c2s_client_load_ok", "s2c_client_load_ok"}
local MONSTER_ID_BASE = 1000000000000000
local MONSTER_GROUPS = 15
-- 服务端 15 秒没心跳会踢人
local HEART_BEAT_INTERVAL = 500

local CMD = {}
local conf
local stat = {
	login = {},
	req = {},
	req_cnt = 0,
	login_fail = 0,
	req_fail = 0,
	timeout = 0,
	reject = {},
	errors = {},
}
local online = 0
local running = 0
local wait_co = nil
local pending = {}		-- [ws] = 发出时间 ms
local timed_out = {}

local function now_ms()
	return skynet.hpc() / 1e6
end

local function add_error(kind, err)
	stat[kind] = stat[kind] + 1
	local key = kind .. ": " .. string.sub(tostring(err), 1, 120)
	stat.errors[key] = (stat.errors[key] or 0) + 1
end

local function note_latency(name)
	local list = stat.req[name]
	if not list then
		list = {}
		stat.req[name] = list
	end
	return list
end

-- allow_tell：业务拒绝走 s2c_tell_me，也算一次完整往返，不算失败
local function request(ws, action, allow_tell)
	local req, resp, msg, decode = action[1], action[2], action[3], action[4]
	local t = now_ms()
	pending[ws] = t
	P.send(ws, req, msg)
	local accept = {[resp] = true}
	local decode_set = {}
	if decode then
		decode_set[resp] = true
	end
	if allow_tell then
		accept.s2c_tell_me = true
		decode_set.s2c_tell_me = true
	end
	local got, body = P.recv_match(ws, accept, decode_set)
	pending[ws] = nil
	if timed_out[ws] then
		return nil, "timeout " .. req
	end
	if not got then
		return nil, req .. ": " .. tostring(body)
	end
	note_latency(req)[#note_latency(req) + 1] = now_ms() - t
	stat.req_cnt = stat.req_cnt + 1
	if got == "s2c_tell_me" then
		stat.reject[req] = (stat.reject[req] or 0) + 1
		return "reject", body and body.msg
	end
	return "ok", body
end

local function wait_gm_ok(ws, cmd)
	local t = now_ms()
	pending[ws] = t
	P.send(ws, "c2s_gm_command", {cmd = cmd or "super"})
	while true do
		local got, body = P.recv_match(ws, {s2c_tell_me = true}, {s2c_tell_me = true})
		if timed_out[ws] then
			return nil, "timeout c2s_gm_command"
		end
		if not got then
			return nil, "c2s_gm_command: " .. tostring(body)
		end
		local text = body and body.msg or ""
		if string.find(text, "指令使用成功", 1, true) then
			note_latency("c2s_gm_command")[#note_latency("c2s_gm_command") + 1] = now_ms() - t
			stat.req_cnt = stat.req_cnt + 1
			pending[ws] = nil
			return "ok"
		end
		if string.find(text, "指令使用失败", 1, true) then
			pending[ws] = nil
			stat.reject.c2s_gm_command = (stat.reject.c2s_gm_command or 0) + 1
			return nil, text
		end
	end
end

local function sleep_interval()
	local cs = conf.interval_ms / 10
	skynet.sleep(math.max(1, math.floor(cs * (0.8 + math.random() * 0.4))))
end

local function run_bot(idx)
	local t = now_ms()
	local conn_list = {}
	local ws, user_id = P.login(conf.login_addr, conf.server_id, conf.prefix .. idx, conf.timeout_ms / 10, function(c)
		conn_list[#conn_list + 1] = c
		pending[c] = now_ms()
	end)
	for _, c in ipairs(conn_list) do
		pending[c] = nil
		timed_out[c] = nil
	end
	if not ws then
		add_error("login_fail", user_id)
		return
	end
	stat.login[#stat.login + 1] = now_ms() - t
	online = online + 1
	local ok, err = request(ws, LOAD_OK)
	if ok then
		local kind, body = request(ws, {"c2s_user_base_info", "s2c_user_base_info", nil, true})
		if kind == "ok" and (not body.sex or body.sex == 0) then
			local name = string.format("b%d", idx)
			kind, err = request(ws, {"c2s_user_create", "s2c_user_create", {name = name, sex = 1}}, true)
			if kind == "reject" then
				kind, err = nil, "create: " .. tostring(err)
			end
		end
		ok = kind
	end
	if ok then
		ok, err = wait_gm_ok(ws)
	end
	local hero_type
	if ok then
		local kind, body = request(ws, {"c2s_req_all_hero_base_info", "s2c_req_all_hero_base_info", nil, true})
		local hero = kind == "ok" and body.heroInfoList and body.heroInfoList[1]
		hero_type = hero and hero.heroType
		if not hero_type then
			ok, err = nil, "no hero " .. tostring(kind)
		end
	end
	local city_x, city_y = 0, 0
	if ok then
		ok, err = request(ws, {"c2s_edit_troop", "s2c_edit_troop", {
			troopInfo = {
				troopIdx = 1,
				posMap = {{key = 1, value = {heroIdx = hero_type, soldier = {count = 100}}}},
			},
		}}, true)
		if ok == "reject" then
			ok, err = nil, "edit troop: " .. tostring(err)
		end
	end
	if ok then
		local kind, body = request(ws, {"c2s_user_base_info", "s2c_user_base_info", nil, true})
		if kind == "ok" and body.cityPos then
			city_x, city_y = body.cityPos.x or 0, body.cityPos.y or 0
		end
		ok = kind
		err = body
	end
		local last_heart_beat = skynet.now()
	local out = false
	local step = idx
	local monster = (idx - 1) % MONSTER_GROUPS + 1
	while ok and skynet.now() < conf.deadline do
		local kind, action_name
		if skynet.now() - last_heart_beat >= HEART_BEAT_INTERVAL then
			action_name = HEART_BEAT[1]
			kind, err = request(ws, HEART_BEAT)
			last_heart_beat = skynet.now()
		elseif step % 5 == 0 and not out then
			action_name = "c2s_march"
			kind, err = request(ws, {"c2s_march", "s2c_march", {
				troopIdx = 1,
				targetType = 2,
				targetId = MONSTER_ID_BASE + monster,
			}}, true)
			if kind == "ok" then
				out = true
			end
		elseif step % 5 == 0 and idx % 2 == 0 then
			action_name = "c2s_cancel_march"
			kind, err = request(ws, {"c2s_cancel_march", "s2c_cancel_march", {troopIdx = 1}}, true)
			if kind == "ok" then
				out = false
			end
		elseif step % 5 == 0 then
			-- 视野没有单独回包。先发视野，再用必回的行军列表把这一拍的耗时算进来
			action_name = "c2s_aoi_focus"
			local t0 = now_ms()
			pending[ws] = t0
			P.send(ws, "c2s_aoi_focus", {pos = {x = city_x + (step % 7), y = city_y}})
			P.send(ws, "c2s_req_march_list")
			local got
			got, err = P.recv_match(ws, {s2c_req_march_list = true, s2c_tell_me = true}, {s2c_tell_me = true})
			pending[ws] = nil
			if timed_out[ws] then
				kind, err = nil, "timeout c2s_aoi_focus"
			elseif not got then
				kind, err = nil, "c2s_aoi_focus: " .. tostring(err)
			else
				note_latency("c2s_aoi_focus")[#note_latency("c2s_aoi_focus") + 1] = now_ms() - t0
				stat.req_cnt = stat.req_cnt + 1
				if got == "s2c_tell_me" then
					stat.reject.c2s_aoi_focus = (stat.reject.c2s_aoi_focus or 0) + 1
				end
				kind = "ok"
			end
		elseif step % 13 == 0 then
			action_name = "c2s_chat"
			kind, err = request(ws, {"c2s_chat", "s2c_chat", {channel = 1, content = "bench", targetId = 0}}, true)
		else
			local action = QUERY_LIST[(step % #QUERY_LIST) + 1]
			action_name = action[1]
			if action_name == "c2s_user_base_info" then
				action = {"c2s_user_base_info", "s2c_user_base_info", nil, true}
			end
			kind, err = request(ws, action)
			if kind == "ok" and action_name == "c2s_user_base_info" and err and err.cityPos then
				city_x, city_y = err.cityPos.x or city_x, err.cityPos.y or city_y
			end
		end
		ok = kind
		if ok then
			step = step + 1
			sleep_interval()
		else
			err = action_name .. ": " .. tostring(err)
		end
	end
	if not ok then
		add_error("req_fail", err)
	end
	online = online - 1
	timed_out[ws] = nil
	P.close(ws)
end

local function watchdog()
	while true do
		skynet.sleep(50)
		local now = now_ms()
		for ws, t in pairs(pending) do
			if now - t > conf.timeout_ms then
				pending[ws] = nil
				timed_out[ws] = true
				stat.timeout = stat.timeout + 1
				P.close(ws)
			end
		end
	end
end

-- delay_list[i] 是 idx_list[i] 的启动延迟（厘秒），用来均匀爬坡
function CMD.start(c, idx_list, delay_list)
	conf = c
	math.randomseed(os.time() + skynet.self())
	for i, idx in ipairs(idx_list) do
		running = running + 1
		skynet.fork(function()
			skynet.sleep(delay_list[i])
			local ok, err = pcall(run_bot, idx)
			if not ok then
				add_error("req_fail", err)
			end
			running = running - 1
			if running == 0 and wait_co then
				skynet.wakeup(wait_co)
			end
		end)
	end
	skynet.fork(watchdog)
end

function CMD.progress()
	return online, stat.req_cnt
end

function CMD.wait()
	if running > 0 then
		wait_co = coroutine.running()
		skynet.wait(wait_co)
	end
	return stat
end

skynet.start(function()
	P.init()
	skynet.dispatch("lua", function(session, _, cmd, ...)
		local f = assert(CMD[cmd], cmd)
		if session ~= 0 then
			skynet.ret(skynet.pack(f(...)))
		else
			f(...)
		end
	end)
end)
