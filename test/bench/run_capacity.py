#!/usr/bin/env python3
"""Create private MongoDB/Redis/game processes and measure the real WebSocket workload.
Uses loopback-only reserved ports, a new database directory and a unique output folder.
Never connects to the development game's database or management endpoint.
"""
import argparse, json, os, re, socket, subprocess, time, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

def wait_http(port, process, seconds=90):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if process.poll() is not None: raise RuntimeError(f"private server exited: {process.returncode}")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/?method_tag=3", timeout=1) as r:
                if r.read().decode().strip() == "ready": return
        except (OSError, TimeoutError): pass
        time.sleep(.2)
    raise RuntimeError("private server ready timeout")

def process_sample(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().split()
        rss = re.search(r"VmRSS:\s+(\d+)", Path(f"/proc/{pid}/status").read_text())
        return {"pid":pid,"cpu_seconds":(int(fields[13])+int(fields[14])) / os.sysconf("SC_CLK_TCK"),
                "rss_kb":int(rss.group(1)) if rss else 0}
    except (OSError, ValueError): return {"pid":pid}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--users",default="20,100,300,600,1000")
    ap.add_argument("--duration",type=int,default=60)
    ap.add_argument("--ramp",type=int,default=30)
    ap.add_argument("--interval-ms",type=int,default=500)
    ap.add_argument("--agents",type=int,default=4)
    ap.add_argument("--account-model",choices=("super","fresh"),default="super")
    ap.add_argument("--p99-ms",type=int,default=100)
    ap.add_argument("--keep-going",action="store_true")
    ap.add_argument("--verify-relogin",action="store_true")
    args=ap.parse_args(); levels=[int(x) for x in args.users.split(",")]
    assert all(0<x<=10000 for x in levels) and args.duration>0 and args.ramp>=0 and args.interval_ms>=100
    ports={"console":39000,"center_console":39001,"login":39021,"gate":39022,"http":39023,
           "center_http":39024,"mongo":39027,"redis":39079,"cluster_center":39127,"cluster_game":39128}
    for name,port in ports.items():
        with socket.socket() as listener:
            # Match server bind semantics: TIME_WAIT is reusable; a live listener still fails.
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try: listener.bind(("127.0.0.1",port))
            except OSError as error: raise RuntimeError(f"private {name} port {port} unavailable") from error
    run=ROOT/"build/capacity"/(time.strftime("%Y%m%d-%H%M%S")+f"-{os.getpid()}")
    run.mkdir(parents=True)
    for name in ("mongo","redis","game_logs","center_logs"): (run/name).mkdir()
    (run/"settings.json").write_text(json.dumps({**vars(args),"ports":ports,"cpu_count":os.cpu_count(),
        "meminfo":Path("/proc/meminfo").read_text(),"cpuinfo":Path("/proc/cpuinfo").read_text().split("\n\n")[0]},indent=2))
    (run/"cluster.lua").write_text('__nowaiting = true\ncenter899 = "127.0.0.1:39127"\ngame901 = "127.0.0.1:39128"\n')
    def configuration(source,extra):
        return f'include {json.dumps(str(ROOT/"config"/source))}\n'+'\n'.join(
            f'{key} = {json.dumps(value) if isinstance(value,str) else str(value)}' for key,value in extra.items())+'\n'
    shared={"mongodb_host":"127.0.0.1","mongodb_port":"39027","redis_host":"127.0.0.1","redis_port":39079,
        "cluster":str(run/"cluster.lua"),"game":"capacity_","address":"127.0.0.1","log_level":"warn","maxonline":20000}
    (run/"center_node").write_text(configuration("center_node",{**shared,"host_id":"899","console_port":39001,
        "http_port":39024,"logpath":str(run/"center_logs")}))
    (run/"game_node").write_text(configuration("main_node",{**shared,"host_id":"901","start":"capacity_server",
        "console_port":39000,"login_port":39021,"gate_port":39022,"http_port":39023,"https_port":39023,
        "logpath":str(run/"game_logs"),"agent_init_cnt":args.agents,"performance_metrics":"1",
        "capacity_metrics_file":str(run/"metrics.jsonl")})+'luaservice = luaservice .. ";../test/bench/?.lua"\nlua_path = lua_path .. ";../test/bench/?.lua"\n')
    (run/"bot_node").write_text(configuration("bench_node",{"start":"capacity_main"}))
    processes,handles={},[]
    def launch(name,command,env=None):
        handle=(run/(name+".log")).open("w"); handles.append(handle)
        process=subprocess.Popen(command,cwd=ROOT/"skynet",env=env,stdout=handle,stderr=subprocess.STDOUT,start_new_session=True)
        processes[name]=process
        (run/"pids.json").write_text(json.dumps({k:v.pid for k,v in processes.items()}))
        return process
    print("CAPACITY_RUN "+str(run),flush=True)
    results=[]
    try:
        launch("mongo",["mongod","--bind_ip","127.0.0.1","--port","39027","--dbpath",str(run/"mongo"),"--wiredTigerCacheSizeGB","0.25","--quiet"])
        launch("redis",["redis-server","--bind","127.0.0.1","--port","39079","--dir",str(run/"redis"),"--save","","--appendonly","no"])
        time.sleep(2)
        launch("center",[str(ROOT/"skynet/skynet"),str(run/"center_node")]); wait_http(39024,processes["center"])
        launch("game",[str(ROOT/"skynet/skynet"),str(run/"game_node")]); wait_http(39023,processes["game"])
        time.sleep(2)
        for users in levels:
            result_path=run/f"result-{users}.json"; env=os.environ.copy()
            env.update({"BENCH_USERS":str(users),"BENCH_DURATION":str(args.duration),"BENCH_RAMP":str(args.ramp),
                "BENCH_INTERVAL_MS":str(args.interval_ms),"BENCH_LOGIN_ADDR":"127.0.0.1:39021","BENCH_SERVER_ID":"901",
                "BENCH_PREFIX":f"capacity_fresh_{users}_" if args.account_model=="fresh" else "capacity_",
                "BENCH_ACCOUNT_MODEL":args.account_model,"BENCH_RESULT":str(result_path),"BENCH_TIMEOUT_MS":"15000",
                "BENCH_MAX_P99_MS":str(args.p99_ms),"BENCH_WORKERS":"8"})
            print(f"CAPACITY_STAGE users={users}",flush=True); begin=time.time()
            bot=launch(f"bots-{users}",[str(ROOT/"skynet/skynet"),str(run/"bot_node")],env)
            with (run/f"process-{users}.jsonl").open("w") as monitor:
                while bot.poll() is None:
                    sample={"time":time.time(),**{k:process_sample(v.pid) for k,v in processes.items() if v.poll() is None}}
                    monitor.write(json.dumps(sample)+"\n"); monitor.flush()
                    available=int(re.search(r"MemAvailable:\s+(\d+)",Path("/proc/meminfo").read_text()).group(1))
                    if available<500000 or time.time()-begin>args.ramp+args.duration+240:
                        raise RuntimeError("capacity resource/time guard reached")
                    if processes["game"].poll() is not None: raise RuntimeError("private game exited")
                    time.sleep(1)
            if not result_path.exists():
                print((run/f"bots-{users}.log").read_text()[-6000:],flush=True)
                raise RuntimeError("capacity client did not produce a result")
            result=json.loads(result_path.read_text()); result["stage_start"]=begin; result["stage_end"]=time.time()
            result["world"] = world_summary(run, result)
            result["request_pass"] = result["pass"]
            result["slow_protocols"] = {name:latency["p99"] for name,latency in result["latency"].items()
                                        if name!="all" and latency["count"]>0 and latency["p99"]>args.p99_ms}
            result["protocol_pass"] = not result["slow_protocols"]
            result["pass"] = result["pass"] and result["world"].get("pass", False) and result["protocol_pass"]
            results.append(result); (run/"results.json").write_text(json.dumps(results,indent=2))
            print(json.dumps({"users":users,"pass":result["pass"],"finished":result["finished"],"rps":result["rps"],
                "p99_ms":result["latency"]["all"]["p99"],"scheduled_p99_ms":result["scheduled_latency"]["p99"],
                "errors":result["errors"],"rejects":result["rejects"],"reject_reasons":result.get("reject_reasons", {}),
                "slow_protocols":result["slow_protocols"],"missed":result["missed"],"world":result["world"]}),flush=True)
            time.sleep(10)
            result["persistence"] = verify_draws(run, result)
            result["cache_drain"] = verify_cache_drain(run, args.agents)
            result["pass"] = result["pass"] and result["persistence"]["pass"] and result["cache_drain"]["pass"]
            (run/"results.json").write_text(json.dumps(results,indent=2))
            persistence_summary=dict(result["persistence"])
            persistence_summary["mismatch_count"]=len(persistence_summary.get("mismatches", []))
            persistence_summary["mismatches"]=persistence_summary.get("mismatches", [])[:5]
            persistence_summary["hero_mismatch_count"]=len(persistence_summary.get("hero_mismatches", []))
            persistence_summary["hero_mismatches"]=persistence_summary.get("hero_mismatches", [])[:5]
            print("CAPACITY_PERSISTENCE " + json.dumps(persistence_summary),flush=True)
            print("CAPACITY_CACHE_DRAIN " + json.dumps(result["cache_drain"]),flush=True)
            if not result["pass"] and not args.keep_going: break
        if args.verify_relogin:
            # A separate account verifies session replacement after the measured workload.
            (run/"relogin_node").write_text(configuration("bench_node",{"start":"bench_main"}))
            env=os.environ.copy(); relogin_result=run/"relogin-result.txt"
            env.update({"BENCH_MODE":"relogin","BENCH_LOGIN_ADDR":"127.0.0.1:39021","BENCH_SERVER_ID":"901",
                "BENCH_PREFIX":"capacity_relogin_","BENCH_TIMEOUT_MS":"15000","BENCH_RESULT":str(relogin_result)})
            bot=launch("bots-relogin",[str(ROOT/"skynet/skynet"),str(run/"relogin_node")],env)
            bot.wait(timeout=45)
            passed=relogin_result.exists() and relogin_result.read_text().splitlines()[0]=="PASS"
            print("CAPACITY_RELOGIN "+str(passed),flush=True)
            if not passed: raise RuntimeError("private relogin verification failed")
    finally:
        stop_private_processes(processes,ports,run)
        for handle in handles: handle.close()
        (run/"exit-status.json").write_text(json.dumps({k:{"pid":v.pid,"exit":v.poll()} for k,v in processes.items()},indent=2))
    print("CAPACITY_COMPLETE "+str(run),flush=True)

def verify_cache_drain(run, agent_count):
    # Observe the real services only; never clear caches to make the benchmark pass.
    deadline=time.monotonic()+30
    fields=("users", "hero_users", "item_users", "item_uid_users", "item_kind_users",
            "player_queues", "player_queue_calls", "offline_cache_retries", "pending_continuations")
    report={"pass":False,"reason":"agent samples unavailable"}
    while True:
        lines=(run/"metrics.jsonl").read_text().splitlines()
        if lines:
            try:
                sample=json.loads(lines[-1]); agents=sample.get("agents", [])
                valid=len(agents)==agent_count and all(a.get("enabled") and all(k in a for k in fields) for a in agents)
                counts={key:sum(a.get(key,0) for a in agents) for key in fields}
                report={"pass":valid and time.time()-sample["time"]<5 and all(v==0 for v in counts.values()),
                        "agents":len(agents),"time":sample["time"],"counts":counts}
            except (ValueError, KeyError): pass  # Reader may see the writer's incomplete last line.
        if report["pass"] or time.monotonic()>=deadline: return report
        time.sleep(1)

def verify_draws(run, result):
    expected = result.get("draw_final", {})
    if not expected: return {"pass":False,"reason":"no acknowledged draw sequence to verify"}
    query = run / ("verify-draws-"+str(result["config"]["users"])+".js")
    query.write_text("const expected="+json.dumps(expected)+";\nconst expectedHeroes="+json.dumps(result.get("hero_ids", {}))+";\n" + r"""
const ids=Object.keys(expected).map(Number);
const rows=db.getSiblingDB('capacity_901').getCollection('user_info_col').find(
    {_id:{$in:ids}}, {'dat._lottery_times':1}).toArray();
let mismatches=[];
for (const row of rows) {
  const key=String(row._id);
  const valid=row.dat && typeof row.dat === "object";
  const actual=valid && row.dat._lottery_times === undefined ? 0 : row.dat && row.dat._lottery_times;
  if (!valid || actual === null || Number(actual)!==Number(expected[key])) mismatches.push({uid:key,expected:expected[key],actual});
}
const heroUsers=Object.keys(expectedHeroes).map(Number);
const heroes=db.getSiblingDB('capacity_901').getCollection('user_hero_col').find(
    {_id:{$in:heroUsers}}, {'dat._heroes':1}).toArray();
let heroMismatches=[];
for (const row of heroes) {
  const key=String(row._id), data=row.dat && row.dat._heroes;
  const actual=data && typeof data==='object' ? Object.keys(data).map(Number).sort((a,b)=>a-b) : null;
  const wanted=expectedHeroes[key].slice().sort((a,b)=>a-b);
  if (JSON.stringify(actual)!==JSON.stringify(wanted)) heroMismatches.push({uid:key,expected:wanted,actual});
}
print(JSON.stringify({checked:rows.length,expected:ids.length,missing:ids.length-rows.length,mismatches,
    hero_checked:heroes.length,hero_expected:heroUsers.length,hero_missing:heroUsers.length-heroes.length,
    hero_mismatches:heroMismatches}));
""")
    started=time.monotonic()
    while True:
        proc=subprocess.run(["mongosh","--quiet","--host","127.0.0.1","--port","39027","--file",str(query)],
                            text=True,capture_output=True,timeout=20)
        if proc.returncode: return {"pass":False,"reason":proc.stderr[-500:]}
        report=json.loads(proc.stdout.strip().splitlines()[-1])
        report["pass"]=report["missing"]==0 and not report["mismatches"] and report["hero_missing"]==0 and not report["hero_mismatches"]
        report["check_ms"]=round((time.monotonic()-started)*1000,1)
        if report["pass"] or time.monotonic()-started>30: return report
        time.sleep(2)

def world_summary(run, result):
    start = result.get("measure_started_at")
    if start is None: return {"pass":False,"reason":"measurement did not start"}
    samples = [json.loads(line) for line in (run/"metrics.jsonl").read_text().splitlines()]
    before = [row for row in samples if row["time"] <= start and row.get("world")]
    during = [row for row in samples if start < row["time"] <= start+result["config"]["duration"] and row.get("world")]
    if not before or not during: return {"pass":False,"reason":"world samples missing"}
    first,last=before[-1]["world"],during[-1]["world"]
    def histogram(name):
        previous,current=first[name],last[name]
        count=current["count"]-previous["count"]
        cumulative,p99=0,None
        for old,new in zip(previous["buckets"],current["buckets"]):
            cumulative+=new["count"]-old["count"]
            if p99 is None and cumulative>=count*.99: p99=new["upper_ms"]
        return {"count":count,"avg_ms":(current["sum"]-previous["sum"])/max(1,count),
                "p99_upper_ms":p99,"run_max_ms":current["max"]}
    step=histogram("step_ms"); late=histogram("late_ms")
    errors=last["errors"]-first["errors"]
    return {"step":step,"late":late,"errors":errors,
            "pass":errors==0 and step["count"]>0 and step["p99_upper_ms"] is not None
                and step["p99_upper_ms"]<=50 and late["p99_upper_ms"] is not None and late["p99_upper_ms"]<=50}

def stop_private_processes(processes, ports, run):
    """Only manage handles created in this invocation, checked against its unique folder."""
    def owned(role, process):
        if process.poll() is not None: return False
        command = Path(f"/proc/{process.pid}/cmdline").read_bytes().replace(b"\0", b" ").decode()
        private_redis = role == "redis" and Path(f"/proc/{process.pid}/cwd").resolve() == (run / "redis").resolve()
        if str(run) not in command and not private_redis:
            raise RuntimeError(f"refusing to manage process outside this run: {role}")
        return True
    # End test clients before the game performs its acknowledged persistence shutdown.
    for role, process in processes.items():
        if role.startswith("bots-") and owned(role, process):
            process.terminate(); process.wait(timeout=15)
    for role, port in [("game", ports["http"]), ("center", ports["center_http"])]:
        process = processes.get(role)
        if process and owned(role, process):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/?method_tag=1", timeout=60) as response:
                    print(role + " shutdown: " + response.read().decode(), flush=True)
                process.wait(timeout=10)
            except Exception as error:
                print(role + " graceful shutdown incomplete: " + str(error), flush=True)
    # If private bootstrap failed, SIGTERM is allowed only after the same identity check.
    # Test databases remain on disk; no directories or stored documents are deleted.
    for role, process in reversed(list(processes.items())):
        if owned(role, process):
            process.terminate()
            try: process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                print("private process remains: " + role + " pid=" + str(process.pid), flush=True)

if __name__ == "__main__": main()
