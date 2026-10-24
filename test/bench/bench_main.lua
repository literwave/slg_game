local skynet = require "skynet"
require "skynet.manager"
local P = require "bench_proto"

-- 参数见 shell/bench.sh。结果写到 BENCH_RESULT，第一行 PASS / FAIL，脚本据此给退出码

local function env(name, default)
	local v = os.getenv(name)
	if v == nil or v == "" then
		return default
	end
	return tonumber(v) or v
end

local conf = {
	mode = env("BENCH_MODE", "load"),
	users = env("BENCH_USERS", 100),
	duration = env("BENCH_DURATION", 30),
	ramp = env("BENCH_RAMP", 10),
	interval_ms = env("BENCH_INTERVAL_MS", 1000),
	timeout_ms = env("BENCH_TIMEOUT_MS", 5000),
	login_addr = env("BENCH_LOGIN_ADDR", "127.0.0.1:33021"),
	server_id = env("BENCH_SERVER_ID", 120),
	prefix = env("BENCH_PREFIX", "bench_"),
	workers = env("BENCH_WORKERS", 4),
	max_error_rate = env("BENCH_MAX_ERROR_RATE", 0.01),
	max_p99_ms = env("BENCH_MAX_P99_MS", 0),
	result = env("BENCH_RESULT", "../log/bench_result.txt"),
}

local out = {}
local function say(fmt, ...)
	local line = string.format(fmt, ...)
	print(line)
	out[#out + 1] = line
end

local function finish(is_pass)
	local f = io.open(conf.result, "w")
	if f then
		f:write(is_pass and "PASS\n" or "FAIL\n", table.concat(out, "\n"), "\n")
		f:close()
	else
		print("write result failed: " .. conf.result)
	end
	skynet.abort()
end

local function percentile(sorted, q)
	if #sorted == 0 then
		return 0
	end
	return sorted[math.max(1, math.ceil(#sorted * q))]
end

local function summary_line(name, list)
	table.sort(list)
	local sum = 0
	for _, v in ipairs(list) do
		sum = sum + v
	end
	local avg = #list > 0 and sum / #list or 0
	say("  %-28s %8d %8.1f %8.1f %8.1f %8.1f %8.1f", name, #list, avg,
		percentile(list, 0.5), percentile(list, 0.95), percentile(list, 0.99), list[#list] or 0)
	return percentile(list, 0.99)
end

local function run_load()
	local worker_cnt = math.max(1, math.min(conf.workers, conf.users))
	local worker_list = {}
	for i = 1, worker_cnt do
		worker_list[i] = skynet.newservice("bench_bot")
	end
	local start_cs = skynet.now()
	conf.deadline = start_cs + (conf.ramp + conf.duration) * 100
	local idx_tbl, delay_tbl = {}, {}
	for i = 1, worker_cnt do
		idx_tbl[i], delay_tbl[i] = {}, {}
	end
	for idx = 1, conf.users do
		local w = (idx - 1) % worker_cnt + 1
		table.insert(idx_tbl[w], idx)
		table.insert(delay_tbl[w], math.floor((idx - 1) / conf.users * conf.ramp * 100))
	end
	say("bench: users=%d duration=%ds ramp=%ds interval=%dms login=%s workers=%d",
		conf.users, conf.duration, conf.ramp, conf.interval_ms, conf.login_addr, worker_cnt)
	for i, w in ipairs(worker_list) do
		skynet.call(w, "lua", "start", conf, idx_tbl[i], delay_tbl[i])
	end

	local is_done = false
	skynet.fork(function()
		local last_cnt, last_cs = 0, skynet.now()
		while not is_done do
			skynet.sleep(500)
			if is_done then
				break
			end
			local online, cnt = 0, 0
			for _, w in ipairs(worker_list) do
				local o, c = skynet.call(w, "lua", "progress")
				online, cnt = online + o, cnt + c
			end
			local now = skynet.now()
			print(string.format("[%3ds] online=%d req=%d rps=%.1f", (now - start_cs) // 100, online, cnt,
				(cnt - last_cnt) * 100 / math.max(1, now - last_cs)))
			last_cnt, last_cs = cnt, now
		end
	end)

	local total = {login = {}, req = {}, req_cnt = 0, login_fail = 0, req_fail = 0, timeout = 0, reject = {}, errors = {}}
	for _, w in ipairs(worker_list) do
		local s = skynet.call(w, "lua", "wait")
		for _, v in ipairs(s.login) do
			total.login[#total.login + 1] = v
		end
		for name, list in pairs(s.req) do
			total.req[name] = total.req[name] or {}
			for _, v in ipairs(list) do
				table.insert(total.req[name], v)
			end
		end
		for _, k in ipairs({"req_cnt", "login_fail", "req_fail", "timeout"}) do
			total[k] = total[k] + s[k]
		end
		for name, n in pairs(s.reject or {}) do
			total.reject[name] = (total.reject[name] or 0) + n
		end
		for k, v in pairs(s.errors) do
			total.errors[k] = (total.errors[k] or 0) + v
		end
	end
	is_done = true
	local elapsed = (skynet.now() - start_cs) / 100

	say("")
	say("login ok %d / %d, login fail %d, request fail %d, timeout %d", #total.login, conf.users,
		total.login_fail, total.req_fail, total.timeout)
	say("requests %d in %.1fs, %.1f req/s", total.req_cnt, elapsed, total.req_cnt / math.max(1, elapsed))
	say("")
	say("  %-28s %8s %8s %8s %8s %8s %8s", "latency (ms)", "count", "avg", "p50", "p95", "p99", "max")
	summary_line("login", total.login)
	local all = {}
	local name_list = {}
	for name in pairs(total.req) do
		name_list[#name_list + 1] = name
	end
	table.sort(name_list)
	for _, name in ipairs(name_list) do
		for _, v in ipairs(total.req[name]) do
			all[#all + 1] = v
		end
		summary_line(name, total.req[name])
	end
	local p99 = summary_line("all requests", all)
	if next(total.reject) then
		say("")
		say("business reject (round trip ok, game refused):")
		local names = {}
		for name in pairs(total.reject) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			say("  %5d  %s", total.reject[name], name)
		end
	end
	if next(total.errors) then
		say("")
		say("errors:")
		for k, v in pairs(total.errors) do
			say("  %5d  %s", v, k)
		end
	end

	local fail_cnt = total.login_fail + total.req_fail
	local error_rate = fail_cnt / math.max(1, conf.users + total.req_cnt)
	local reason_list = {}
	if error_rate > conf.max_error_rate then
		table.insert(reason_list, string.format("error rate %.4f > %.4f", error_rate, conf.max_error_rate))
	end
	if conf.max_p99_ms > 0 and p99 > conf.max_p99_ms then
		table.insert(reason_list, string.format("p99 %.1fms > %dms", p99, conf.max_p99_ms))
	end
	if #total.login == 0 then
		table.insert(reason_list, "no user logged in")
	end
	say("")
	if reason_list[1] then
		say("FAIL: %s", table.concat(reason_list, "; "))
	else
		say("PASS")
	end
	finish(reason_list[1] == nil)
end

-- 同一账号登两次：第一条连接要被服务端踢掉，第二条要一直可用（旧连接迟到的断线不能把它登出）
local function run_relogin()
	local account = conf.prefix .. "relogin"
	local timeout_cs = conf.timeout_ms // 10
	local function check(ok, fmt, ...)
		say("%s %s", ok and "ok  " or "FAIL", string.format(fmt, ...))
		if not ok then
			finish(false)
			skynet.wait()
		end
	end
	local function request(ws, req, resp)
		local done = false
		skynet.timeout(timeout_cs, function()
			if not done then
				P.close(ws)
			end
		end)
		P.send(ws, req)
		local ok, err = P.recv_until(ws, resp)
		done = true
		return ok, err
	end

	local ws1, uid1 = P.login(conf.login_addr, conf.server_id, account, timeout_cs)
	check(ws1, "first login: %s", tostring(uid1))
	check(request(ws1, "c2s_heart_beat", "s2c_heart_beat"), "first connection responds")

	local ws2, uid2 = P.login(conf.login_addr, conf.server_id, account, timeout_cs)
	check(ws2, "second login: %s", tostring(uid2))
	check(uid1 == uid2, "same user id (%s, %s)", tostring(uid1), tostring(uid2))

	local kicked_by_server = nil
	skynet.timeout(timeout_cs, function()
		if kicked_by_server == nil then
			kicked_by_server = false
			P.close(ws1)
		end
	end)
	while true do
		local id = P.recv(ws1)
		if not id then
			break
		end
	end
	if kicked_by_server == nil then
		kicked_by_server = true
	end
	check(kicked_by_server, "first connection closed by server")

	check(request(ws2, "c2s_req_system_open", "s2c_req_system_open"), "second connection responds")
	-- 留时间让旧连接的断线通知走完 worker -> agent
	skynet.sleep(200)
	check(request(ws2, "c2s_user_base_info", "s2c_user_base_info"), "second connection still logged in after old disconnect")
	P.close(ws2)
	say("PASS")
	finish(true)
end

skynet.start(function()
	P.init()
	skynet.fork(function()
		local ok, err = xpcall(conf.mode == "relogin" and run_relogin or run_load, debug.traceback)
		if not ok then
			say("FAIL: %s", tostring(err))
			finish(false)
		end
	end)
end)
