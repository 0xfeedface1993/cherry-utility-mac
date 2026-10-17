#!/bin/zsh
# 跨入口检查 XF-02 … XF-04：UI 测试操作菜单栏、主窗口和意图，本脚本在 shell 一侧运行 cherry、cherry mcp 和 watch。
# UI 测试经 TEST_RUNNER_CHERRY_E2E_SOCKET 拿到 socket 路径，以它启动模拟实例；runner 在沙盒里，双方只靠键盘状态握手。
#
#   Scripts/verify-cross.sh [--run-dir <目录>] [--only XF-02,XF-03,XF-04] [<CherryUtility.app>]
#
# 先 build-for-testing（DerivedData 在 ~/Library/Developer/Xcode/DerivedData/CherryUtility-automation）。
# 结果包先写在 DerivedData 下（测试产物不放 ~/Downloads，否则会弹「访问下载文件夹」的授权），结束后复制到运行目录。
set -uo pipefail

repo="${0:A:h:h}"
source "$repo/Scripts/e2e-lib.sh"

run_dir="" only="XF-02,XF-03,XF-04"
while (( $# )); do
  case "$1" in
    --run-dir) run_dir="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    *) break ;;
  esac
done
derived="$HOME/Library/Developer/Xcode/DerivedData/CherryUtility-automation"
app="${1:-$derived/Build/Products/Debug/CherryUtility.app}"
run_dir="${run_dir:-$repo/build/cross-e2e/$(date +%Y%m%d-%H%M%S)}"
e2e_init "$run_dir" "$app"
typeset -g UI_PID="" SOCK=""
results="$derived/e2e-results/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$results"
trap '[[ -n "$UI_PID" ]] && kill "$UI_PID" 2>/dev/null; e2e_cleanup' EXIT
E2E_SUITE=cross
print "App: $E2E_APP"
print "记录: $E2E_RUN"

# ui_test <ID> <-only-testing 目标>：后台运行一个 UI 用例，$UI_PID 是 xcodebuild。
ui_test() {
  rm -rf "$results/$1.xcresult"
  ( TEST_RUNNER_CHERRY_E2E_SOCKET="$SOCK" exec xcodebuild -project "$repo/CherryUtility.xcodeproj" -scheme CherryUtility \
      -destination 'platform=macOS,arch=arm64' -skipMacroValidation -derivedDataPath "$derived" test-without-building \
      -only-testing:"$2" -resultBundlePath "$results/$1.xcresult" > "$E2E_RUN/$1-xcodebuild.txt" 2>&1 ) &
  UI_PID=$!
}

# ui_finish <ID> <最长秒数>：等 xcodebuild 结束，复制结果包，记录用例结果（被跳过算失败：变量没有传到 runner）。
ui_finish() {
  local id="$1" limit="$2" waited=0 code=0 log="$E2E_RUN/$1-xcodebuild.txt"
  while kill -0 "$UI_PID" 2>/dev/null && (( waited < limit * 10 )); do sleep 0.1; waited=$((waited + 1)); done
  if kill -0 "$UI_PID" 2>/dev/null; then
    kill "$UI_PID"; wait "$UI_PID" 2>/dev/null; UI_PID=""
    record "$id-UI用例" FAIL 0 "xcodebuild $limit 秒内没有结束"
    return
  fi
  wait "$UI_PID"; code=$?; UI_PID=""
  cp -R "$results/$id.xcresult" "$E2E_RUN/" 2>/dev/null
  if grep -q " skipped" "$log"; then
    record "$id-UI用例" FAIL 0 "用例被跳过：CHERRY_E2E_SOCKET 没有传到 runner"
  elif [[ $code == 0 ]] && grep -q "TEST EXECUTE SUCCEEDED" "$log"; then
    record "$id-UI用例" PASS 0 ""
  else
    record "$id-UI用例" FAIL 0 "xcodebuild 退出码 $code：$(grep -E "error:|failed" "$log" | head -5 | tr '\n' ' ' | cut -c1-600)"
  fi
}

# 等 UI 测试启动的实例在 socket 上应答。
wait_for_app() {
  for _ in {1..$(( $1 * 10 ))}; do
    [[ -S "$SOCK" ]] && cherry_safe "$SOCK" version > /dev/null 2>&1 && return 0
    kill -0 "$UI_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

start_watch() { # start_watch <目录>：$WATCHER 是 watch 进程
  watch_bg "$SOCK" "$1/watch.ndjson" "$1/watch.err" --json
  for _ in {1..50}; do grep -q "开始监听" "$1/watch.err" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}

# finish_watch <ID> <watch pid> <最长秒数> <watch.ndjson>：App 退出后 watch 应以 3 结束，最后一行是单行的 appUnavailable 错误。
finish_watch() {
  local id="$1" watcher="$2" limit="$3" output="$4" waited=0 code=0
  while kill -0 "$watcher" 2>/dev/null && (( waited < limit * 10 )); do sleep 0.1; waited=$((waited + 1)); done
  if kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher"; wait "$watcher" 2>/dev/null
    record "$id" FAIL 0 "App 退出后 watch $limit 秒内没有结束"
    return
  fi
  wait "$watcher"; code=$?
  if [[ $code == 3 ]] && tail -1 "$output" | grep -q '^{"error":{"code":"appUnavailable"'; then
    record "$id" PASS 0 ""
  else
    record "$id" FAIL 0 "watch 退出码 $code（期望 3），最后一行：$(tail -1 "$output" | cut -c1-200)"
  fi
}

# 当前配置档的某一项：active_field <字段>（读 status --json）
active_field() {
  cherry_safe "$SOCK" status --json 2>/dev/null | python3 -I -c '
import json, sys
s = json.load(sys.stdin)["status"]
print({p["profile"]: p for p in s["profiles"]}[s["activeProfile"]][sys.argv[1]])' "$1" 2>/dev/null
}

# events_expect <ID> <watch.ndjson> <Python 表达式（e 为事件列表，active(x) 为事件 x 的当前档）>；每一行都必须是 JSON，
# 结束时的错误行不算事件。
events_expect() {
  if python3 -I -c '
import json, sys
e = [x for x in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if "error" not in x]
active = lambda x: {p["profile"]: p for p in x["profiles"]}[x["activeProfile"]]
profile = lambda x, n: {p["profile"]: p for p in x["profiles"]}[n]
sys.exit(0 if (eval(sys.argv[2])) else 1)' "$2" "$3" 2>/dev/null; then
    record "$1" PASS 0 ""
  else
    record "$1" FAIL 0 "watch 事件不满足 $3：$(wc -l < "$2" | tr -d ' ') 行，$(tr '\n' ' ' < "$2" | cut -c1-500)"
  fi
}

# mcp_call <工具> <参数 JSON>：经 cherry mcp 调一次工具，打印结果文本；工具报错时返回 1。
mcp_call() {
  python3 -I - "$E2E_CLI" "$SOCK" "$1" "$2" <<'PY'
import json, subprocess, sys
cli, socket, tool, arguments = sys.argv[1:5]
p = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env={"CHERRY_CONTROL_SOCKET": socket, "PATH": "/usr/bin:/bin"})
def send(i, method, params):
    p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode())
    p.stdin.flush()
    while True:
        r = json.loads(p.stdout.readline())
        if r.get("id") == i:
            return r
send(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "cross", "version": "1"}})
result = send(2, "tools/call", {"name": tool, "arguments": json.loads(arguments)})["result"]
print(result["content"][0]["text"])
p.stdin.close()
p.wait(timeout=10)
sys.exit(1 if result.get("isError") else 0)
PY
}

# ------------------------------------------------------------------------------------------------------------ XF-02
# 菜单栏写入经 socket 可读；MCP 写入实时更新界面；watch 里只有自动化入口的写入；面板「退出」后 watch 以 3 结束、socket 删除。
xf02() {
  SOCK="$E2E_SCRATCH/x2.sock"
  local dir="$E2E_SCRATCH/x2"; mkdir -p "$dir"
  ui_test XF-02 CherryUtilityUITests/CrossEntryUITests/testMenuBarAndMCPShareTheQueueAndFeed
  wait_for_app 180 || { record XF-02-实例启动 FAIL 0 "UI 用例启动的实例没有在 socket 上应答"; ui_finish XF-02 120; return; }
  start_watch "$dir" || record XF-02-watch开始 FAIL 0 "$(<"$dir/watch.err")"
  local watcher=$WATCHER
  check XF-02-命令行写入（信号） 0 "" "" -- cherry_safe "$SOCK" set --brightness 2
  local seen="" effect
  for _ in {1..120}; do
    effect="$(active_field effect)"
    [[ "$effect" == 光谱 ]] && { seen=1; break; }
    sleep 0.5
  done
  if [[ -n "$seen" ]]; then record XF-02-菜单栏写入经socket可读 PASS 0 ""; else record XF-02-菜单栏写入经socket可读 FAIL 0 "60 秒内状态里没有出现光谱（最后：$effect）"; fi
  local text code=0
  text="$(mcp_call set_lighting '{"effect":"Breathing","brightness":1}')" || code=$?
  if [[ $code == 0 ]]; then record XF-02-MCP写入 PASS 0 "$text"; else record XF-02-MCP写入 FAIL 0 "$text"; fi
  finish_watch XF-02-面板退出后watch以3结束 "$watcher" 120 "$dir/watch.ndjson"
  expect XF-02-正常退出删除socket test ! -e "$SOCK"
  events_expect XF-02-watch只有命令行和MCP的写入 "$dir/watch.ndjson" \
    'len(e) == 2 and active(e[0])["effect"] == "波纹" and active(e[0])["brightness"] == 2 and active(e[1])["effect"] == "呼吸" and active(e[1])["brightness"] == 1 and all(active(x)["effect"] != "光谱" for x in e)'
  ui_finish XF-02 120
}

# ------------------------------------------------------------------------------------------------------------ XF-03
# 命令行写入实时更新主窗口；意图写入与命令行写入出现在同一个 watch 里。
xf03() {
  SOCK="$E2E_SCRATCH/x3.sock"
  local dir="$E2E_SCRATCH/x3"; mkdir -p "$dir"
  ui_test XF-03 CherryUtilityIntentsUITests/IntentFeedUITests/testIntentWritesReachTheCommandLineFeed
  wait_for_app 180 || { record XF-03-实例启动 FAIL 0 "UI 用例启动的实例没有在 socket 上应答"; ui_finish XF-03 120; return; }
  start_watch "$dir" || record XF-03-watch开始 FAIL 0 "$(<"$dir/watch.err")"
  local watcher=$WATCHER
  check XF-03-命令行切换配置档（信号） 0 "" "" -- cherry_safe "$SOCK" profile 1
  finish_watch XF-03-用例结束后watch以3结束 "$watcher" 180 "$dir/watch.ndjson"
  events_expect XF-03-命令行与意图的写入在同一个watch里 "$dir/watch.ndjson" \
    'len(e) == 3 and e[0]["activeProfile"] == 1 and profile(e[1], 3)["effect"] == "曲线" and e[2]["activeProfile"] == 1 and profile(e[2], 1)["brightness"] == 1'
  ui_finish XF-03 120
}

# ------------------------------------------------------------------------------------------------------------ XF-04
# 慢设备上命令行写入进行中拔出键盘：命令以 4 结束、不挂起；watch 不断开，插回后收到新事件。
xf04() {
  SOCK="$E2E_SCRATCH/x4.sock"
  local dir="$E2E_SCRATCH/x4"; mkdir -p "$dir"
  ui_test XF-04 CherryUtilityUITests/CrossEntryUITests/testUnplugDuringACommandLineWrite
  wait_for_app 180 || { record XF-04-实例启动 FAIL 0 "UI 用例启动的实例没有在 socket 上应答"; ui_finish XF-04 120; return; }
  start_watch "$dir" || record XF-04-watch开始 FAIL 0 "$(<"$dir/watch.err")"
  local watcher=$WATCHER
  check XF-04-命令行写入（信号） 0 "" "" -- cherry_safe "$SOCK" set --brightness 2
  # UI 用例看到信号后约 1–3 秒拔出键盘。脚本在后台连续写配置 3（慢设备上每次约 3 秒，配置 3 不是当前档，面板不变），
  # 拔出时总有一次正在进行；第一次失败后停下。
  ( for i in {1..8}; do
      local began=$EPOCHREALTIME code=0
      cherry_safe "$SOCK" set -p 3 --brightness $(( i % 5 )) --json > "$dir/w$i.out" 2> "$dir/w$i.err" || code=$?
      print -r -- "$i $code $(( EPOCHREALTIME - began ))" >> "$dir/writes.txt"
      (( code == 0 )) || break
    done ) &
  local writer=$! waited=0
  while kill -0 "$writer" 2>/dev/null && (( waited < 600 )); do sleep 0.1; waited=$((waited + 1)); done
  if kill -0 "$writer" 2>/dev/null; then
    kill "$writer"; record XF-04-进行中的写入不挂起 FAIL 0 "60 秒内没有结束：$(tr '\n' ';' < "$dir/writes.txt")"
  else
    local last=(${(z)"$(tail -1 "$dir/writes.txt")"}) failure
    failure="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"]["code"])' "$dir/w${last[1]}.out" 2>/dev/null)"
    # 拔出前开始的写入报 disconnected（或设备错误）；noKeyboard 说明它在拔出之后才开始，没测到进行中的情形。
    if [[ ${last[2]} == 4 && -n "$failure" && "$failure" != noKeyboard ]] && (( ${last[3]} < 25 )); then
      record XF-04-拔出时进行中的写入以4结束 PASS "${last[3]}" "第 ${last[1]} 次写入：$failure"
    else
      record XF-04-拔出时进行中的写入以4结束 FAIL "${last[3]:-0}" "$(tr '\n' ';' < "$dir/writes.txt") 错误码 $failure：$(<"$dir/w${last[1]}.out")"
    fi
  fi
  expect XF-04-拔出后watch仍在运行 kill -0 "$watcher"
  local back=""
  for _ in {1..120}; do
    cherry_safe "$SOCK" status > /dev/null 2>&1 && { back=1; break; }
    sleep 0.5
  done
  if [[ -n "$back" ]]; then record XF-04-插回后可用 PASS 0 ""; else record XF-04-插回后可用 FAIL 0 "60 秒内键盘没有回来"; fi
  check XF-04-插回后写入 0 "" "" -- cherry_safe "$SOCK" set --brightness 3
  finish_watch XF-04-用例结束后watch以3结束 "$watcher" 120 "$dir/watch.ndjson"
  events_expect XF-04-插回后watch收到事件 "$dir/watch.ndjson" \
    'len(e) >= 2 and active(e[0])["brightness"] == 2 and active(e[-1])["brightness"] == 3'
  ui_finish XF-04 120
}

for id in ${(s:,:)only}; do
  e2e_aborted && { print -u2 "看门狗中止了运行（见 $E2E_RUN/watchdog.log）"; exit 99; }
  print "== $id"
  "xf${id#XF-}"
done
e2e_aborted && { print -u2 "看门狗中止了运行（见 $E2E_RUN/watchdog.log）"; exit 99; }

total=$(grep -c . "$E2E_RUN/results.tsv")
failed=$(awk -F'\t' '$3=="FAIL"' "$E2E_RUN/results.tsv" | wc -l | tr -d ' ')
print "合计 $total 项：失败 $failed。详见 $E2E_RUN/results.tsv"
(( failed == 0 ))
