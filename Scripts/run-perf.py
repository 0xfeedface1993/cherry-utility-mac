#!/usr/bin/env python3
"""CHERRY Utility 的 CPU / 内存基线：只用模拟键盘，按场景采集，结果写成 JSON。

  Scripts/run-perf.py --app <CherryUtility.app> --output <目录> [--scenarios a,b] [--trace]

场景：
  idle-background  以 --background 启动（没有主窗口，只有菜单栏图标），预热后静置采样
  idle-window      正常启动（主窗口停在概览），预热后静置采样
  automation       后台启动的 App + 一个经由 App 的 cherry mcp：交替 get_status / set_lighting；
                   再用 cherry 命令行经由 App 读状态
  cli-direct       App 不运行，cherry status 直连（每次一个新进程）
  mcp-idle         App 不运行，cherry mcp 直连后静置采样

每个场景一个新的数据目录（/tmp/cherry-perf-*）：App、cherry 与 cherry mcp 都带 CHERRY_SIMULATION 和这个数据目录，
不会碰真键盘或默认 socket。应在看门狗下运行（Scripts/run-perf.sh）。--trace 时在采样窗口内用 xctrace 附加
Time Profiler（automation 另录 Allocations），trace 与 leaks 结果一并保存。
"""
import argparse, json, os, pathlib, shutil, signal, statistics, subprocess, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCENARIO = "pixiu75"


class Run:
    def __init__(self, app, output, rusage, trace):
        self.app, self.output, self.rusage, self.trace = app, output, rusage, trace
        self.cherry = app / "Contents/MacOS/cherry"

    # ---------------------------------------------------------------- 进程与采样
    def environment(self, data):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CHERRY_")}
        env.update({"CHERRY_SIMULATION": SCENARIO, "CHERRY_DATA_DIR": str(data)})
        return env

    def sample(self, *pids):
        out = subprocess.run([str(self.rusage), *map(str, pids)], capture_output=True, text=True, check=True).stdout
        return {line["pid"]: line for line in map(json.loads, out.splitlines())}

    def app_pids(self):
        out = subprocess.run(["pgrep", "-x", "CherryUtility"], capture_output=True, text=True).stdout
        return {int(p) for p in out.split()}

    def is_simulated(self, pid, data):
        line = subprocess.run(["ps", "-wwE", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
        return f"CHERRY_SIMULATION={SCENARIO}" in line and f"CHERRY_DATA_DIR={data}" in line

    def launch_app(self, data, background):
        before = self.app_pids()
        args = ["open", "-n", "-g", "-j", "--env", f"CHERRY_SIMULATION={SCENARIO}", "--env", f"CHERRY_DATA_DIR={data}", str(self.app)]
        if background:
            args += ["--args", "--background"]
        subprocess.run(args, check=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            new = self.app_pids() - before
            if len(new) == 1:
                pid = new.pop()
                if not self.is_simulated(pid, data):
                    os.kill(pid, signal.SIGKILL)
                    raise RuntimeError(f"实例 {pid} 不是本场景的模拟实例，已结束")
                if self.cli(data, ["version"], check=False).returncode == 0:
                    return pid
            time.sleep(0.1)
        raise TimeoutError("模拟实例 20 秒内没有应答")

    def quit_app(self, pid):
        os.kill(pid, signal.SIGTERM)
        for _ in range(100):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        os.kill(pid, signal.SIGKILL)

    def cli(self, data, args, check=True):
        return subprocess.run([str(self.cherry), *args], env=self.environment(data), capture_output=True, text=True, check=check)

    def xctrace(self, template, pid, seconds, name):
        if not self.trace:
            return None
        path = self.output / f"{name}.trace"
        log = (self.output / f"{name}.xctrace.txt").open("w")
        recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", template, "--attach", str(pid),
                                     "--time-limit", f"{seconds}s", "--output", str(path)], stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while "Ctrl-C" not in (self.output / f"{name}.xctrace.txt").read_text():
            if recorder.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"xctrace {template} 没有开始，见 {name}.xctrace.txt")
            time.sleep(0.2)
        return recorder

    @staticmethod
    def finish(recorder):
        if recorder is None:
            return
        try:
            recorder.wait(timeout=600)
        except subprocess.TimeoutExpired:
            recorder.send_signal(signal.SIGINT)
            recorder.wait(timeout=120)

    def window(self, pids, seconds, every=1.0):
        """静置采样：返回开始、结束和逐秒的 footprint 序列。"""
        start = self.sample(*pids)
        series = []
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            time.sleep(every)
            series.append(self.sample(*pids))
        end = self.sample(*pids)
        return start, end, series

    @staticmethod
    def delta(start, end, series, pid):
        s, e = start[pid], end[pid]
        wall = e["epoch"] - s["epoch"]
        footprints = [x[pid]["footprint"] for x in series if pid in x] or [e["footprint"]]
        return {
            "wall_s": round(wall, 3),
            "cpu_s": round((e["cpu_ns"] - s["cpu_ns"]) / 1e9, 4),
            "cpu_percent": round((e["cpu_ns"] - s["cpu_ns"]) / 1e9 / wall * 100, 4),
            "idle_wakeups_per_s": round((e["idle_wakeups"] - s["idle_wakeups"]) / wall, 2),
            "interrupt_wakeups_per_s": round((e["interrupt_wakeups"] - s["interrupt_wakeups"]) / wall, 2),
            "footprint_start_mib": round(s["footprint"] / 2**20, 2),
            "footprint_end_mib": round(e["footprint"] / 2**20, 2),
            "footprint_max_mib": round(max(footprints) / 2**20, 2),
            "lifetime_peak_mib": round(e["peak_footprint"] / 2**20, 2),
        }

    def leaks(self, pid, name):
        result = subprocess.run(["leaks", "--noContent", str(pid)], capture_output=True, text=True)
        (self.output / f"{name}.leaks.txt").write_text(result.stdout + result.stderr)
        summary = next((l.strip() for l in result.stdout.splitlines() if " leaks for " in l), "")
        return {"exit": result.returncode, "summary": summary}

    def data_dir(self):
        return pathlib.Path(tempfile.mkdtemp(prefix="cherry-perf-", dir="/tmp"))

    # ---------------------------------------------------------------- 场景
    def idle(self, background, warmup, seconds):
        name = "idle-background" if background else "idle-window"
        data = self.data_dir()
        pid = self.launch_app(data, background)
        try:
            time.sleep(warmup)
            recorder = self.xctrace("Time Profiler", pid, int(seconds), name)
            start, end, series = self.window([pid], seconds)
            self.finish(recorder)
            result = {"app": self.delta(start, end, series, pid), "leaks": self.leaks(pid, name)}
        finally:
            self.quit_app(pid)
            shutil.rmtree(data, ignore_errors=True)
        return result

    def automation(self, calls, cli_calls):
        data = self.data_dir()
        pid = self.launch_app(data, background=True)
        mcp = None
        try:
            time.sleep(10)
            mcp = MCPClient(self.cherry, self.environment(data))
            mcp.call("get_status", {})
            # 预热：前 20 次不计入，避免把首次连接、首次读取算进稳态。
            for i in range(20):
                mcp.call("get_status" if i % 2 else "set_lighting", {} if i % 2 else {"profile": 3, "speed": i % 5 + 1})
            baseline = self.sample(pid, mcp.pid)
            recorder = self.xctrace("Time Profiler", pid, 60, "automation-time")
            latencies = []
            started = self.sample(pid, mcp.pid)
            series = []
            for i in range(calls):
                tool, args = ("get_status", {}) if i % 2 else ("set_lighting", {"profile": 3, "speed": i % 5 + 1})
                began = time.perf_counter()
                mcp.call(tool, args)
                latencies.append((tool, time.perf_counter() - began))
                if i % 25 == 0:
                    series.append(self.sample(pid, mcp.pid))
            ended = self.sample(pid, mcp.pid)
            self.finish(recorder)
            cli_latency = []
            cli_start = self.sample(pid)
            for _ in range(cli_calls):
                began = time.perf_counter()
                self.cli(data, ["status"])
                cli_latency.append(time.perf_counter() - began)
            cli_end = self.sample(pid)
            alloc = self.xctrace("Allocations", pid, 45, "automation-allocations")
            if alloc:
                for i in range(100):
                    mcp.call("get_status" if i % 2 else "set_lighting", {} if i % 2 else {"profile": 3, "speed": i % 5 + 1})
                self.finish(alloc)
            settled = self.sample(pid, mcp.pid)
            reads = [t for n, t in latencies if n == "get_status"]
            writes = [t for n, t in latencies if n == "set_lighting"]
            result = {
                "calls": calls,
                "app": self.delta(started, ended, series, pid),
                "mcp": self.delta(started, ended, series, mcp.pid),
                "app_cpu_ms_per_call": round((ended[pid]["cpu_ns"] - started[pid]["cpu_ns"]) / 1e6 / calls, 3),
                "mcp_cpu_ms_per_call": round((ended[mcp.pid]["cpu_ns"] - started[mcp.pid]["cpu_ns"]) / 1e6 / calls, 3),
                "read_ms": percentiles(reads), "write_ms": percentiles(writes),
                "app_footprint_growth_mib": round((settled[pid]["footprint"] - baseline[pid]["footprint"]) / 2**20, 2),
                "mcp_footprint_growth_mib": round((settled[mcp.pid]["footprint"] - baseline[mcp.pid]["footprint"]) / 2**20, 2),
                "cli": {"calls": cli_calls, "wall_ms": percentiles(cli_latency),
                        "app_cpu_ms_per_call": round((cli_end[pid]["cpu_ns"] - cli_start[pid]["cpu_ns"]) / 1e6 / cli_calls, 3)},
                "leaks": self.leaks(pid, "automation-app"),
                "mcp_leaks": self.leaks(mcp.pid, "automation-mcp"),
            }
        finally:
            if mcp:
                mcp.close()
            self.quit_app(pid)
            shutil.rmtree(data, ignore_errors=True)
        return result

    def cli_direct(self, runs):
        data = self.data_dir()
        env = self.environment(data)
        samples = []
        try:
            subprocess.run([str(self.cherry), "status"], env=env, capture_output=True, check=True)  # 首次：建共享状态文件
            for _ in range(runs):
                began = time.perf_counter()
                process = subprocess.Popen([str(self.cherry), "status"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                _, status, usage = os.wait4(process.pid, 0)
                wall = time.perf_counter() - began
                if os.waitstatus_to_exitcode(status) != 0:
                    raise RuntimeError("cherry status 直连失败：" + process.stderr.read().decode())
                samples.append({"wall": wall, "cpu": usage.ru_utime + usage.ru_stime, "maxrss": usage.ru_maxrss})
            if self.trace:
                trace = self.output / "cli-direct.trace"
                args = ["xcrun", "xctrace", "record", "--template", "Time Profiler", "--output", str(trace)]
                for key in ("CHERRY_SIMULATION", "CHERRY_DATA_DIR"):
                    args += ["--env", f"{key}={env[key]}"]
                args += ["--launch", "--", str(self.cherry), "status"]
                with (self.output / "cli-direct.xctrace.txt").open("w") as log:
                    subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        finally:
            shutil.rmtree(data, ignore_errors=True)
        return {"runs": runs, "wall_ms": percentiles([s["wall"] for s in samples]),
                "cpu_ms": percentiles([s["cpu"] for s in samples]),
                "maxrss_mib": round(statistics.median(s["maxrss"] for s in samples) / 2**20, 2)}

    def mcp_idle(self, seconds):
        data = self.data_dir()
        mcp = MCPClient(self.cherry, self.environment(data))
        try:
            mcp.call("get_status", {})
            time.sleep(5)
            recorder = self.xctrace("Time Profiler", mcp.pid, int(seconds), "mcp-idle")
            start, end, series = self.window([mcp.pid], seconds)
            self.finish(recorder)
            result = {"mcp": self.delta(start, end, series, mcp.pid), "leaks": self.leaks(mcp.pid, "mcp-idle")}
        finally:
            mcp.close()
            shutil.rmtree(data, ignore_errors=True)
        return result


class MCPClient:
    """经 stdio 与 cherry mcp 交互，一次一个请求。"""
    def __init__(self, cherry, env):
        self.process = subprocess.Popen([str(cherry), "mcp"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.pid, self.next = self.process.pid, 1
        self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "perf", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        ident, self.next = self.next, self.next + 1
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("cherry mcp 意外退出")
            message = json.loads(line)
            if message.get("id") == ident:
                return message

    def call(self, tool, arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})["result"]
        if result.get("isError"):
            raise RuntimeError(f"{tool} 失败：{result['content'][0]['text']}")
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()


def percentiles(values):
    values = sorted(v * 1000 for v in values)
    if not values:
        return {}
    pick = lambda q: values[min(len(values) - 1, int(round(q * (len(values) - 1))))]
    return {"n": len(values), "p50": round(pick(0.5), 2), "p90": round(pick(0.9), 2), "max": round(values[-1], 2)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--rusage", type=pathlib.Path, required=True, help="编译好的 Scripts/perf-rusage.swift")
    parser.add_argument("--scenarios", default="idle-background,idle-window,automation,cli-direct,mcp-idle")
    parser.add_argument("--idle-seconds", type=float, default=180)
    parser.add_argument("--warmup", type=float, default=30)
    parser.add_argument("--calls", type=int, default=400)
    parser.add_argument("--trace", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    run = Run(args.app.resolve(), args.output.resolve(), args.rusage.resolve(), args.trace)
    if run.app_pids():
        sys.exit("已有 CherryUtility 在运行，先退出它")
    binary = run.app / "Contents/MacOS/CherryUtility"
    results = {"app": str(run.app), "uuid": subprocess.check_output(["dwarfdump", "--uuid", str(binary)], text=True).strip(),
               "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "scenarios": {}}
    for scenario in args.scenarios.split(","):
        print(f"== {scenario}", flush=True)
        if scenario == "idle-background":
            value = run.idle(True, args.warmup, args.idle_seconds)
        elif scenario == "idle-window":
            value = run.idle(False, args.warmup, args.idle_seconds)
        elif scenario == "automation":
            value = run.automation(args.calls, 30)
        elif scenario == "cli-direct":
            value = run.cli_direct(15)
        elif scenario == "mcp-idle":
            value = run.mcp_idle(min(args.idle_seconds, 120))
        else:
            sys.exit(f"未知场景 {scenario}")
        results["scenarios"][scenario] = value
        print(json.dumps(value, ensure_ascii=False), flush=True)
        (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    results["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    (args.output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
