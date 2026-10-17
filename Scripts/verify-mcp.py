#!/usr/bin/env python3
"""`cherry mcp` 的 stdio 端到端检查：像 Claude Code 一样启动它，按行收发 JSON-RPC。

    Scripts/verify-mcp.py --socket /tmp/cherry-…/x.sock --suite <套件> [--suite …] --transcript <文件>
                          [--results <results.tsv>] [--expect-version <版本>] [--label <名称>] -- <cherry> mcp

套件：basic、full、errors、extremes、protocol、versions、unavailable、concurrency、garbage、eof、
scenario-dual、scenario-nbl、scenario-mx30s、scenario-empty、scenario-denied。
每个会话都检查：stdout 只有 JSON-RPC 行；正常套件 stderr 为空；关闭标准输入后 2 秒内以 0 退出。

只连 /tmp/cherry-* 下的 socket（模拟实例），不会以真机模式拉起 App。每项输出一行 PASS / FAIL，退出码为失败项数。
"""

import argparse
import json
import queue
import subprocess
import sys
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--suite", action="append", required=True)
parser.add_argument("--transcript", required=True)
parser.add_argument("--results")
parser.add_argument("--expect-version")
parser.add_argument("--label", default="mcp")
parser.add_argument("command", nargs=argparse.REMAINDER)
options = parser.parse_args()
command = options.command[1:] if options.command[:1] == ["--"] else options.command
if not command:
    parser.error("缺少要启动的命令")
if not (options.socket.startswith("/tmp/cherry-") or options.socket.startswith("/private/tmp/cherry-")):
    parser.error(f"只允许 /tmp/cherry-* 下的 socket：{options.socket}")
cli = command[0]

failures = 0
transcript = open(options.transcript, "a", encoding="utf-8")
results = open(options.results, "a", encoding="utf-8") if options.results else None
current_suite = ""


def report(check_id, ok, detail="", seconds=0.0):
    global failures
    status = "PASS" if ok else "FAIL"
    if not ok:
        failures += 1
    print(f"{status}  [{options.label}/{current_suite}] {check_id}" + (f"（{detail}）" if detail and not ok else ""))
    if results:
        results.write(f"{options.label}/{current_suite}\t{check_id}\t{status}\t{seconds:.2f}\t{'' if ok else detail}\n")
        results.flush()


class Session:
    """一个 `cherry mcp` 进程。读线程把 stdout 的每一行放进队列，stderr 单独收集，不会因缓冲阻塞。"""

    def __init__(self, socket=None, extra_args=()):
        environment = {"CHERRY_CONTROL_SOCKET": socket or options.socket, "PATH": "/usr/bin:/bin"}
        self.process = subprocess.Popen(
            command + list(extra_args), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment
        )
        self.lines = queue.Queue()
        self.stderr = []
        self.non_json = []
        self.next_id = 0
        self.responses = {}
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for raw in self.process.stdout:
            text = raw.decode(errors="replace").rstrip("\n")
            try:
                message = json.loads(text)
            except ValueError:
                self.non_json.append(text)
                transcript.write(f"<! {text}\n")
                continue
            if not (isinstance(message, (dict, list))):
                self.non_json.append(text)
            transcript.write(f"< {json.dumps(message, ensure_ascii=False)}\n")
            self.lines.put(message)
        self.lines.put(None)

    def _read_stderr(self):
        for raw in self.process.stderr:
            self.stderr.append(raw.decode(errors="replace"))

    def write_raw(self, data):
        transcript.write(f"> {data.decode(errors='replace')[:2000]}\n")
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def send(self, method, params=None, notification=False, request_id=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notification:
            if request_id is None:
                self.next_id += 1
                request_id = self.next_id
            message["id"] = request_id
        self.write_raw((json.dumps(message, ensure_ascii=False) + "\n").encode())
        return message.get("id")

    def wait(self, request_id, timeout=30):
        deadline = time.monotonic() + timeout
        while request_id not in self.responses:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{timeout} 秒内没有收到 id={request_id} 的响应")
            try:
                message = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if message is None:
                raise EOFError("cherry mcp 关闭了标准输出")
            for item in message if isinstance(message, list) else [message]:
                if isinstance(item, dict) and "id" in item and "method" not in item:
                    self.responses[item["id"]] = item
        return self.responses.pop(request_id)

    def any_message(self, timeout):
        try:
            return self.lines.get(timeout=timeout)
        except queue.Empty:
            return "timeout"

    def request(self, method, params=None, timeout=30):
        return self.wait(self.send(method, params), timeout)

    def initialize(self, version="2025-11-25"):
        response = self.request("initialize", {"protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "verify-mcp", "version": "2"}})
        self.send("notifications/initialized", notification=True)
        return response

    def call(self, name, arguments=None, timeout=30):
        response = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout)
        result = response.get("result") or {}
        texts = [item.get("text", "") for item in result.get("content", []) if item.get("type") == "text"]
        return result, (texts[0] if texts else ""), response

    def close(self, expect_clean_stderr=True):
        """关闭标准输入：2 秒内以 0 退出；stdout 只有 JSON-RPC；正常套件 stderr 为空。"""
        start = time.monotonic()
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            code = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            code = None
        elapsed = time.monotonic() - start
        time.sleep(0.05)
        report("MC-01 退出", code == 0 and elapsed < 2, f"退出码 {code}，用时 {elapsed:.2f}s", elapsed)
        report("MC-01 stdout 只有 JSON-RPC", not self.non_json, f"非 JSON 行：{self.non_json[:3]}")
        if expect_clean_stderr:
            report("MC-01 stderr 为空", not "".join(self.stderr).strip(), "".join(self.stderr)[:300])
        if self.stderr:
            transcript.write("stderr " + "".join(self.stderr) + "\n")


def structured(result, *keys):
    value = result.get("structuredContent") or {}
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def cli_status():
    output = subprocess.run([cli, "status", "--json"], capture_output=True, text=True,
                            env={"CHERRY_CONTROL_SOCKET": options.socket, "PATH": "/usr/bin:/bin"}, timeout=30)
    return json.loads(output.stdout)["status"]


def cli_profile(number):
    return next(profile for profile in cli_status()["profiles"] if profile["profile"] == number)


def expect_error(session, check_id, name, arguments, code, fragment=""):
    result, text, response = session.call(name, arguments)
    actual = structured(result, "error", "code")
    message = structured(result, "error", "message")
    ok = result.get("isError") is True and actual == code and fragment in text and text == message
    report(check_id, ok, f"{name} {json.dumps(arguments, ensure_ascii=False)[:80]} → {actual}：{text[:120]}")
    return text


# ---------------------------------------------------------------------------------------------------------------- suites

def suite_basic():
    session = Session()
    initialized = session.initialize()
    info = (initialized.get("result") or {}).get("serverInfo") or {}
    report("initialize", info.get("name") == "cherry-utility"
           and (options.expect_version is None or info.get("version") == options.expect_version)
           and "tools" in initialized["result"].get("capabilities", {}), str(initialized)[:300])
    tools = (session.request("tools/list").get("result") or {}).get("tools", [])
    names = [tool["name"] for tool in tools]
    destructive = {tool["name"] for tool in tools if tool.get("annotations", {}).get("destructiveHint")}
    read_only = {tool["name"] for tool in tools if tool.get("annotations", {}).get("readOnlyHint")}
    report("tools/list", len(names) == 9 and destructive == {"apply_preset"}
           and read_only == {"list_keyboards", "get_status", "get_battery", "list_lighting_effects", "list_presets"}
           and not any("firmware" in name for name in names), names)
    result, text, _ = session.call("get_status")
    report("get_status", not result.get("isError") and structured(result, "status", "keyboard", "id") and "配置" in text, text[:200])
    session.close()


def suite_full():
    """MC-02：9 个工具的正常路径，写入后与命令行读到的状态对照。"""
    session = Session()
    session.initialize()
    result, text, _ = session.call("list_keyboards")
    report("MC-02 list_keyboards", len(structured(result, "keyboards") or []) == 1 and "046A:01E2@03100000" in text, text)
    result, text, _ = session.call("get_status")
    cli_text = subprocess.run([cli, "status"], capture_output=True, text=True,
                              env={"CHERRY_CONTROL_SOCKET": options.socket, "PATH": "/usr/bin:/bin"}).stdout.strip()
    json_part = json.loads(result["content"][1]["text"]) if len(result.get("content", [])) > 1 else None
    report("MC-02 get_status 与命令行文本一致", text == cli_text, f"{text[:80]} ≠ {cli_text[:80]}")
    report("MC-02 get_status 第二段等于 structuredContent", json_part == result.get("structuredContent"))
    result, text, _ = session.call("get_battery")
    report("MC-02 get_battery", structured(result, "battery") == {"percent": 95, "charging": True}, text)
    result, text, _ = session.call("list_lighting_effects")
    report("MC-02 list_lighting_effects", len(structured(result, "effects") or []) == 11, text[:80])
    result, text, _ = session.call("list_presets")
    report("MC-02 list_presets", isinstance(structured(result, "presets"), list), text[:80])
    result, text, _ = session.call("switch_profile", {"profile": 1})
    report("MC-02 switch_profile", text.startswith("已切换到配置 1") and cli_status()["activeProfile"] == 1, text)
    result, text, _ = session.call("set_lighting", {"effect": "Breathing", "brightness": 2, "speed": 5, "color": "#00D70F", "profile": 3})
    p3 = cli_profile(3)
    report("MC-02 set_lighting", not result.get("isError") and p3["effect"] == "呼吸" and p3["brightness"] == 2 and p3["speed"] == 5
           and p3["color"] == "#00D70F" and p3["randomColor"] is False, f"{text}；{p3}")
    result, text, _ = session.call("set_sleep_timers", {"sleep_seconds": 0, "deep_sleep_minutes": 20, "profile": 3})
    p3 = cli_profile(3)
    report("MC-02 set_sleep_timers", p3["sleepSeconds"] == 0 and p3["deepSleepMinutes"] == 20, f"{text}；{p3}")
    result, text, _ = session.call("apply_preset", {"preset": "办公", "profile": 1})
    p1 = cli_profile(1)
    report("MC-02 apply_preset", text.startswith("已把预设「办公」载入配置 1") and p1["effect"] == "曲线" and p1["brightness"] == 3, f"{text}；{p1}")
    session.close()


def suite_errors():
    """MC-03 / MC-05：参数与协议错误。"""
    session = Session()
    session.initialize()
    expect_error(session, "MC-03 未知灯效", "set_lighting", {"effect": "Foo"}, "unknownEffect", "没有「Foo」灯效")
    expect_error(session, "MC-03 颜色格式", "set_lighting", {"color": "red"}, "invalidArgument", "#RRGGBB")
    expect_error(session, "MC-03 颜色带符号", "set_lighting", {"color": "#+FF720"}, "invalidArgument", "#RRGGBB")
    expect_error(session, "MC-03 亮度 5", "set_lighting", {"brightness": 5}, "invalidArgument", "亮度须为 0–4")
    expect_error(session, "MC-03 亮度 -1", "set_lighting", {"brightness": -1}, "invalidArgument", "亮度须为 0–4")
    expect_error(session, "MC-03 速度 0", "set_lighting", {"speed": 0}, "invalidArgument", "速度须为 1–5，收到 0")
    expect_error(session, "MC-03 速度 6", "set_lighting", {"speed": 6}, "invalidArgument", "速度须为 1–5，收到 6")
    expect_error(session, "MC-03 配置档 0", "switch_profile", {"profile": 0}, "invalidArgument", "没有配置 0")
    expect_error(session, "MC-03 配置档 4", "switch_profile", {"profile": 4}, "invalidArgument", "没有配置 4")
    expect_error(session, "MC-03 休眠 10", "set_sleep_timers", {"sleep_seconds": 10}, "invalidArgument", "收到 10")
    expect_error(session, "MC-03 休眠 301", "set_sleep_timers", {"sleep_seconds": 301}, "invalidArgument", "收到 301")
    expect_error(session, "MC-03 深度休眠 10", "set_sleep_timers", {"deep_sleep_minutes": 10}, "invalidArgument", "15–300")
    expect_error(session, "MC-03 键盘 ID", "get_status", {"keyboard": "PIXIU"}, "invalidArgument", "格式不对")
    expect_error(session, "MC-03 预设不存在", "apply_preset", {"preset": "不存在"}, "presetNotFound", "没有名为「不存在」的预设")
    expect_error(session, "MC-03 预设重名", "apply_preset", {"preset": "游戏"}, "ambiguousPreset", "请用 ID 指定")
    expect_error(session, "MC-03 其他型号的预设", "apply_preset", {"preset": "98 专用"}, "presetIncompatible", "来自其他型号")
    expect_error(session, "MC-03 亮度字符串", "set_lighting", {"brightness": "高"}, "invalidArgument", "应为整数")
    expect_error(session, "MC-03 亮度小数", "set_lighting", {"brightness": 2.5}, "invalidArgument", "应为整数")
    expect_error(session, "MC-03 亮度布尔", "set_lighting", {"brightness": True}, "invalidArgument", "应为整数")
    expect_error(session, "MC-03 未知参数", "set_lighting", {"Brightness": 1}, "invalidArgument", "未知参数 Brightness")
    expect_error(session, "MC-03 一项都不填", "set_lighting", {}, "invalidArgument", "至少指定一项")
    expect_error(session, "MC-03 缺少配置档", "switch_profile", {}, "invalidArgument", "缺少参数 profile")
    expect_error(session, "MC-03 null 视为未填", "switch_profile", {"profile": None}, "invalidArgument", "缺少参数 profile")
    for check_id, arguments in (("MC-03 宽松：中文灯效", {"effect": "呼吸"}), ("MC-03 宽松：无 # 的颜色", {"color": "FF7200"}),
                                ("MC-03 宽松：RANDOM", {"color": "RANDOM"}), ("MC-03 宽松：字符串数字", {"brightness": "2"}),
                                ("MC-03 宽松：整数值小数", {"brightness": 2.0})):
        result, text, _ = session.call("set_lighting", {**arguments, "profile": 2})
        report(check_id + "（记录：已接受）" if not result.get("isError") else check_id + "（记录：已拒绝）", True, text)
    # MC-05：协议层的错误。
    response = session.request("tools/call", {"name": "flash_firmware", "arguments": {}})
    report("MC-05 未知工具", (response.get("error") or {}).get("code") == -32602 and "未知工具 flash_firmware" in (response.get("error") or {}).get("message", ""), response)
    response = session.request("tools/call", {"arguments": {}})
    report("MC-05 缺少工具名", (response.get("error") or {}).get("code") in (-32602, -32600), response)
    response = session.request("resources/list")
    report("MC-05 resources/list", (response.get("error") or {}).get("code") == -32601, response)
    response = session.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "again", "version": "1"}})
    report("MC-05 第二次 initialize（记录行为）", True, str(response)[:200])
    response = session.request("ping")
    report("MC-05 之后仍能响应", response.get("result") == {}, response)
    session.close()


def suite_extremes():
    """MC-04：极端整数不能让 App 崩溃（B1）。"""
    session = Session()
    session.initialize()
    minimum = -9223372036854775808
    expect_error(session, "MC-04 profile=Int.min", "switch_profile", {"profile": minimum}, "invalidArgument", str(minimum))
    expect_error(session, "MC-04 speed=Int.min", "set_lighting", {"speed": minimum}, "invalidArgument", str(minimum))
    result, text, _ = session.call("get_status")
    report("MC-04 App 仍然存活", not result.get("isError"), text[:120])
    session.close()


def suite_protocol():
    """MC-07：initialize 之前的消息、ping、未知通知。"""
    session = Session()
    session.send("notifications/initialized", notification=True)
    session.send("notifications/whatever", notification=True)
    response = session.request("ping")
    report("MC-07 initialize 前 ping", response.get("result") == {}, response)
    response = session.request("tools/list")
    report("MC-07 initialize 前 tools/list（记录行为）", True, str(response)[:120])
    session.initialize()
    report("MC-07 initialize 后 ping", session.request("ping").get("result") == {})
    session.close()


def suite_versions():
    """MC-06：协议版本协商，每个版本一个新进程。"""
    for version in ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2099-01-01", None):
        session = Session()
        params = {"capabilities": {}, "clientInfo": {"name": "v", "version": "1"}}
        if version:
            params["protocolVersion"] = version
        response = session.request("initialize", params)
        negotiated = (response.get("result") or {}).get("protocolVersion")
        if version in ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"):
            report(f"MC-06 {version}", negotiated == version, response)
        elif version:
            report(f"MC-06 未知版本 {version} → {negotiated}", negotiated == "2025-11-25", response)
        else:
            report(f"MC-06 缺少版本（记录：{'错误' if 'error' in response else negotiated}）", True, str(response)[:200])
        session.send("notifications/initialized", notification=True)
        tools = (session.request("tools/list").get("result") or {}).get("tools", [])
        report(f"MC-06 {version} 之后 tools/list", len(tools) == 9, len(tools))
        session.close()


def suite_unavailable():
    """MC-08：App 不可用时每个工具都返回 appUnavailable 错误，不崩溃。"""
    missing = "/tmp/cherry-e2e-none.sock"
    session = Session(socket=missing)
    session.initialize()
    for name, arguments in (("list_keyboards", {}), ("get_status", {}), ("get_battery", {}), ("list_lighting_effects", {}),
                            ("list_presets", {}), ("switch_profile", {"profile": 1}), ("set_lighting", {"brightness": 1}),
                            ("set_sleep_timers", {"sleep_seconds": 0}), ("apply_preset", {"preset": "x"})):
        result, text, _ = session.call(name, arguments)
        report(f"MC-08 {name}", result.get("isError") is True and structured(result, "error", "code") == "appUnavailable"
               and f"没有运行（socket：{missing}）" in text, text)
    report("MC-08 ping", session.request("ping").get("result") == {})
    session.close()


def suite_concurrency():
    """MC-10：8 个请求不等响应连续发出，id 一一对应，各字段都写入。"""
    session = Session()
    session.initialize()
    calls = [("set_lighting", {"effect": "Curve", "profile": 3}), ("set_lighting", {"brightness": 1, "profile": 3}),
             ("set_lighting", {"speed": 4, "profile": 3}), ("set_lighting", {"color": "#3153FF", "profile": 3}),
             ("set_sleep_timers", {"sleep_seconds": 120, "profile": 3}), ("set_sleep_timers", {"deep_sleep_minutes": 45, "profile": 3}),
             ("get_status", {}), ("list_presets", {})]
    start = time.monotonic()
    ids = [session.send("tools/call", {"name": name, "arguments": arguments}) for name, arguments in calls]
    ping = session.send("ping")
    responses = {request_id: session.wait(request_id, 60) for request_id in ids + [ping]}
    elapsed = time.monotonic() - start
    errors = [rid for rid in ids if (responses[rid].get("result") or {}).get("isError")]
    report("MC-10 8 个并发调用都成功", not errors, f"失败 {errors}", elapsed)
    p3 = cli_profile(3)
    report("MC-10 最终状态含每一项", p3["effect"] == "曲线" and p3["brightness"] == 1 and p3["speed"] == 4 and p3["color"] == "#3153FF"
           and p3["sleepSeconds"] == 120 and p3["deepSleepMinutes"] == 45, p3)
    session.close()


def suite_garbage():
    """MC-12：乱码、空对象、1 MiB 单行、超长预设名，进程都不退出。"""
    session = Session()
    session.initialize()
    for check_id, data in (("MC-12 乱码", b"garbage\n"), ("MC-12 {}", b"{}\n"), ("MC-12 1 MiB 单行", b"x" * (1 << 20) + b"\n")):
        start = time.monotonic()
        session.write_raw(data)
        message = session.any_message(3)
        alive = session.request("ping", timeout=5).get("result") == {}
        report(check_id, alive, f"进程不可用；回应：{str(message)[:120]}", time.monotonic() - start)
        report(f"{check_id}（记录：{'有回应' if message != 'timeout' else '无回应'}）", True)
    result, text, _ = session.call("apply_preset", {"preset": "x" * 70000})
    report("MC-12 70 KiB 预设名", result.get("isError") is True and structured(result, "error", "code") == "invalidArgument" and "过长" in text, text[:120])
    result, text, _ = session.call("get_status")
    report("MC-12 之后仍可用", not result.get("isError"), text[:80])
    session.close(expect_clean_stderr=False)


def suite_eof():
    """MC-13：请求进行中关闭标准输入，响应仍送达后再退出（B2）。"""
    session = Session()
    session.initialize()
    request_id = session.send("tools/call", {"name": "get_status", "arguments": {}})
    session.process.stdin.close()
    try:
        response = session.wait(request_id, 30)
        ok = not (response.get("result") or {}).get("isError")
    except (TimeoutError, EOFError) as error:
        ok, response = False, repr(error)
    report("MC-13 EOF 前的请求仍得到响应", ok, str(response)[:200])
    code = session.process.wait(timeout=30)
    report("MC-13 随后以 0 退出", code == 0, code)
    idle = Session()
    idle.initialize()
    idle.close()


def suite_cancel():
    """MC-11：客户端取消进行中的调用（notifications/cancelled）：不再回应这个 id，会话照常；已发出的写入是否生效以 App 为准（记录）。"""
    session = Session()
    session.initialize()
    before = cli_profile(3)["brightness"]
    target = 1 if before != 1 else 2
    request_id = session.send("tools/call", {"name": "set_lighting", "arguments": {"brightness": target, "profile": 3}})
    session.send("notifications/cancelled", {"requestId": request_id, "reason": "verify-mcp"}, notification=True)
    try:
        response = session.wait(request_id, 8)
        report("MC-11 取消后不再回应", False, str(response)[:200])
    except TimeoutError:
        report("MC-11 取消后不再回应", True)
    report("MC-11 之后仍能响应", session.request("ping").get("result") == {})
    after = cli_profile(3)["brightness"]   # 排在已发出的写入之后读取
    report(f"MC-11 已取消的写入（记录：{'已生效' if after == target else '未生效'}）", True, f"配置 3 亮度 {before} → {after}")
    session.close()


def scenario(name):
    def run():
        session = Session()
        session.initialize()
        if name == "dual":
            result, text, _ = session.call("get_status")
            candidates = [item["id"] for item in structured(result, "error", "candidates") or []]
            report("MC-14 dual 歧义", structured(result, "error", "code") == "ambiguousKeyboard"
                   and candidates == ["046A:01E2@03100000", "046A:01E2@03200000"] and "03200000" in text, text)
            result, text, _ = session.call("set_lighting", {"brightness": 1, "keyboard": "046A:01E2@03200000"})
            report("MC-14 dual 指定键盘 B", not result.get("isError"), text)
        elif name == "nbl":
            result, text, _ = session.call("list_lighting_effects")
            report("MC-14 nbl 灯效", structured(result, "effects") == [] and "没有背光灯效" in text, text)
            expect_error(session, "MC-14 nbl 设灯光", "set_lighting", {"brightness": 1}, "unsupportedSetting", "没有背光")
            expect_error(session, "MC-14 nbl 休眠", "set_sleep_timers", {"sleep_seconds": 60}, "unsupportedSetting", "不支持休眠设置")
        elif name == "mx30s":
            expect_error(session, "MC-14 mx30s 电量", "get_battery", {}, "noBattery", "是有线键盘，没有电量")
            expect_error(session, "MC-14 mx30s 休眠", "set_sleep_timers", {"sleep_seconds": 0}, "unsupportedSetting", "不支持休眠设置")
        elif name == "empty":
            start = time.monotonic()
            expect_error(session, "MC-14 empty", "get_status", {}, "noKeyboard", "没有连接受支持的 CHERRY 键盘")
            report("MC-14 empty 第一次 ≤ 4 秒", time.monotonic() - start <= 4, time.monotonic() - start)
        elif name == "denied":
            expect_error(session, "MC-14 denied", "get_status", {}, "accessDenied", "输入监控")
        session.close()
    return run


suites = {
    "basic": suite_basic, "full": suite_full, "errors": suite_errors, "extremes": suite_extremes, "protocol": suite_protocol,
    "versions": suite_versions, "unavailable": suite_unavailable, "concurrency": suite_concurrency, "garbage": suite_garbage,
    "eof": suite_eof, "cancel": suite_cancel,
    **{f"scenario-{name}": scenario(name) for name in ("dual", "nbl", "mx30s", "empty", "denied")},
}

for current_suite in options.suite:
    transcript.write(f"### suite {current_suite}\n")
    try:
        suites[current_suite]()
    except Exception as error:  # 超时、EOF、JSON 错误：整个套件记为失败，继续下一个
        report("会话中断", False, repr(error))
    transcript.flush()

transcript.close()
sys.exit(min(failures, 125))
