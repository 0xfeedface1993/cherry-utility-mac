#!/bin/zsh
# `cherry` 命令行与 `cherry mcp` 的模拟端到端检查。每个套件以模拟键盘在后台启动自己的 App 实例（不显示主窗口），
# 用包内的 cherry 经 /tmp 下的 socket 调用它；不碰真键盘、正式 App 的 socket，也不让 App 访问 ~/Downloads。
#
#   Scripts/verify-cli.sh [--run-dir <目录>] [--suites core,presets,concurrency,watch,lifecycle,scenarios,mcp,cross] [<CherryUtility.app>]
#
# 默认 App 为 ~/Library/Developer/Xcode/DerivedData/CherryUtility-automation 的 Debug 构建（先用 xcodebuild 构建）。
# 结果写入 <运行目录>/results.tsv（套件、ID、PASS/FAIL/KNOWN、耗时、说明），命令与输出写入 transcript.txt，
# MCP 收发写入 mcp.jsonl，watch 事件写入 watch-*.ndjson。默认运行目录为 build/cli-e2e/<时间>。
set -uo pipefail

repo="${0:A:h:h}"
source "$repo/Scripts/e2e-lib.sh"

run_dir="" suites="core,presets,concurrency,watch,lifecycle,scenarios,mcp,cross"
while (( $# )); do
  case "$1" in
    --run-dir) run_dir="$2"; shift 2 ;;
    --suites) suites="$2"; shift 2 ;;
    *) break ;;
  esac
done
app="${1:-$HOME/Library/Developer/Xcode/DerivedData/CherryUtility-automation/Build/Products/Debug/CherryUtility.app}"
[[ "$suites" == all ]] && suites="core,presets,concurrency,watch,lifecycle,scenarios,mcp,cross"
run_dir="${run_dir:-$repo/build/cli-e2e/$(date +%Y%m%d-%H%M%S)}"
e2e_init "$run_dir" "$app"
trap e2e_cleanup EXIT
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$E2E_APP/Contents/Info.plist")"
mcp() { # mcp <socket> <标签> <套件,套件…>
  local -a selected
  for name in ${(s:,:)3}; do selected+=(--suite "$name"); done
  python3 "$repo/Scripts/verify-mcp.py" --socket "$1" --transcript "$E2E_RUN/mcp.jsonl" --results "$E2E_RUN/results.tsv" \
    --expect-version "$version" --label "$2" "${selected[@]}" -- "$E2E_CLI" mcp
}
c() { cherry_safe "$SOCK" "$@"; }   # 当前套件的实例

print "App: $E2E_APP"
print "记录: $E2E_RUN"

# 看门狗能读到模拟实例的环境变量（否则它会误杀所有实例）。
watchdog_selftest() {
  local pid="${E2E_PIDS[$1]}"
  if ps -wwE -p "$pid" -o command= | grep -q "CHERRY_SIMULATION="; then
    record "看门狗自检" PASS 0 ""
  else
    record "看门狗自检" FAIL 0 "ps -E 读不到 CHERRY_SIMULATION，看门狗无法区分模拟实例"
    exit 1
  fi
}

# ------------------------------------------------------------------------------------------------------------- core
suite_core() {
  E2E_SUITE=core
  launch_sim core pixiu75 || return
  watchdog_selftest core
  SOCK="$(sim_socket core)"
  local long_socket="/tmp/cherry-e2e-$(printf 'x%.0s' {1..110}).sock"

  check CL-01-拒绝非测试socket 70 "" "拒绝 socket" -- cherry_safe "$HOME/Library/Application Support/CherryUtility/control.sock" status

  check CL-02-status 0 "* 配置 2：波纹" "" -- c status
  check CL-02-status-json 0 '"status"' "" -- c status --json
  json_expect CL-02-status-json字段 'd["status"]["keyboard"]["id"]=="046A:01E2@03100000" and len(d["status"]["profiles"])==3 and d["status"]["battery"]=={"percent":95,"charging":True} and d["status"]["activeProfile"]==2'
  expect CL-02-成功时stderr为空 test -z "$LAST_ERR"
  check CL-02-keyboards-json 0 "" "" -- c keyboards --json
  json_expect CL-02-keyboards字段 'd["keyboards"][0]["id"]=="046A:01E2@03100000" and d["keyboards"][0]["configurable"] is True'
  check CL-02-battery-json 0 "" "" -- c battery --json
  json_expect CL-02-battery字段 'd["battery"]["percent"]==95 and "电量" in d["message"]'
  check CL-02-effects-json 0 "" "" -- c effects --json
  json_expect CL-02-effects字段 'len(d["effects"])==11 and {"name":"呼吸","englishName":"Breathing"} in d["effects"]'
  check CL-02-presets-json 0 "" "" -- c presets --json
  json_expect CL-02-presets为空 'd.get("presets", [])==[]'
  check CL-02-version-json 0 "" "" -- c version --json
  json_expect CL-02-version字段 "d['version']['protocolVersion']==1 and d['version']['app']=='$version'"
  check CL-02-profile-json 0 "" "" -- c profile 1 --json
  json_expect CL-02-profile字段 'd["profile"]["profile"]==1 and d["message"].startswith("已切换到配置 1")'
  check CL-02-set-json 0 "" "" -- c set --brightness 2 --json
  json_expect CL-02-set字段 'd["profile"]["brightness"]==2 and d["message"]=="已更新配置 1：亮度 中"'
  check CL-02-错误JSON 4 '"code" : "invalidArgument"' "" -- c profile 4 --json
  json_expect CL-02-错误JSON字段 'd["error"]["message"]=="MX PIXIU 75 只有 3 个配置档，没有配置 4"'
  check CL-02-App未运行JSON 3 '"appUnavailable"' "" -- cherry_safe "$E2E_SCRATCH/none.sock" status --json

  check CL-03-未知子命令 2 "" "Error" -- c fly
  check CL-03-缺少配置档 2 "" "Missing expected argument" -- c profile
  check CL-03-配置档非数字 2 "" "Error" -- c profile 二
  check CL-03-set一项都没有 2 "" "至少指定一项" -- c set
  check CL-03-亮度名称不对 2 "" "Error" -- c set --brightness 很亮
  check CL-03-亮度越界 2 "" "Error" -- c set --brightness 9
  check CL-03-配置档0 4 "" "没有配置 0" -- c profile 0
  check CL-03-配置档4 4 "" "没有配置 4" -- c profile 4
  check CL-03-型号没有的灯效 4 "" "没有「彩虹雨」灯效" -- c set --effect 彩虹雨
  check CL-03-休眠10 4 "" "休眠时间须为 0（不休眠）或 30–300 秒，收到 10" -- c set --sleep 10
  check CL-03-深度休眠10 4 "" "15–300 分钟" -- c set --deep-sleep 10
  check CL-03-速度6 4 "" "速度须为 1–5，收到 6" -- c set --speed 6
  check CL-03-颜色red 4 "" "#RRGGBB" -- c set --color red
  check CL-03-颜色带符号 4 "" "#RRGGBB" -- c set --color '#+FF720'
  check CL-03-键盘ID格式 4 "" "格式不对" -- c status -k PIXIU
  check CL-03-socket路径过长 1 "" "socket 路径过长" -- cherry_safe "$long_socket" status
  check CL-03-App未运行 3 "" "没有运行（socket：$E2E_SCRATCH/none.sock）" -- cherry_safe "$E2E_SCRATCH/none.sock" status
  check CL-03-帮助 0 "SUBCOMMANDS" "" -- c --help
  expect CL-03-帮助不显示socket test "${LAST_OUT//--socket/}" = "$LAST_OUT"
  check CL-03-help-set 0 "--brightness" "" -- c help set
  check CL-03-set--help 0 "--deep-sleep" "" -- c set --help
  check CL-03-mcp--help 0 "claude mcp add" "" -- c mcp --help
  check CL-03-版本 0 "控制协议 v1" "" -- c --version
  check CL-03-无子命令（记录） 0 "" "" -- c
  [[ $LAST_CODE == 0 ]] || record CL-03-无子命令-退出码 KNOWN 0 "无子命令时退出码 $LAST_CODE"

  check CL-04-profile=Int.min 4 "" "-9223372036854775808" -- c profile -- -9223372036854775808
  check CL-04-speed=Int.min 4 "" "-9223372036854775808" -- c set --speed=-9223372036854775808
  expect CL-04-App仍在运行 sim_alive core
  check CL-04-之后仍能响应 0 "CHERRY Utility" "" -- c version

  check CL-06-没见过的ID回退 0 "" "" -- c status -k 046A:01E2@03990000 --json
  json_expect CL-06-回退到唯一同型号 'd["status"]["keyboard"]["id"]=="046A:01E2@03100000"'
  check CL-06-其他型号ID 4 "" "未找到设备 046A:0079@03100000" -- c status -k 046A:0079@03100000
  check CL-06---socket优先于环境变量 0 "CHERRY Utility" "" -- env CHERRY_CONTROL_SOCKET="$E2E_SCRATCH/none.sock" "$E2E_CLI" version --socket "$SOCK"

  check CL-23-超长预设名 2 "" "过长" -- c preset apply "$(printf 'x%.0s' {1..70000})"
  check CL-23-超长灯效名 2 "" "过长" -- c set --effect "$(printf 'x%.0s' {1..100})"
  check CL-23-之后仍能响应 0 "* 配置 1" "" -- c status

  quit_sim core
}

# ---------------------------------------------------------------------------------------------------------- presets
suite_presets() {
  E2E_SUITE=presets
  local office=11111111-1111-4111-8111-111111111111 game1=22222222-2222-4222-8222-222222222222 game2=33333333-3333-4333-8333-333333333333
  local only98=44444444-4444-4444-8444-444444444444 english=55555555-5555-4555-8555-555555555555 bad=66666666-6666-4666-8666-666666666666
  for name in presets nbl98 pix98; do
    seed_preset "$name" "$office.cherryprofile" "$(preset_json $office 办公 2026-01-01T00:00:00Z null 12 3 1 FF7200 false 60 30)"
    seed_preset "$name" "$game1.cherryprofile" "$(preset_json $game1 游戏 2026-01-02T00:00:00Z 482 0 4 4 FF0000 false 300 30)"
    seed_preset "$name" "$game2.cherryprofile" "$(preset_json $game2 游戏 2026-01-03T00:00:00Z 482 2 1 2 0099FF false 300 30)"
    seed_preset "$name" "$only98.cherryprofile" "$(preset_json $only98 '98 专用' 2026-01-04T00:00:00Z 486 5 4 3 FFFFFF true 300 30)"
    seed_preset "$name" "$english.cherryprofile" "$(preset_json $english Office 2026-01-05T00:00:00Z 482 18 2 3 3153FF false 120 60)"
    seed_preset "$name" "$bad.cherryprofile" "$(preset_json $bad 坏数据 2026-01-06T00:00:00Z 482 99 9 3 FFFFFF false 10 30)"
    seed_preset "$name" broken.cherryprofile '{"name": '
    seed_preset "$name" notes.txt "not a preset"
  done
  launch_sim presets pixiu75 || return
  SOCK="$(sim_socket presets)"

  check CL-15-列表 0 "" "" -- c presets --json
  json_expect CL-15-按时间倒序且跳过坏文件 '[p["name"] for p in d["presets"]]==["坏数据","Office","98 专用","游戏","游戏","办公"] and [p.get("model") for p in d["presets"]][-1] is None and d["presets"][2]["model"]=="MX PIXIU 98"'
  check CL-15-文本列表 0 "任何型号" "" -- c presets
  check CL-15-按名称载入 0 "已把预设「办公」载入配置 3（曲线 · 亮度 高）" "" -- c preset apply 办公 -p 3
  check CL-15-载入后状态 0 "" "" -- c status --json
  json_expect CL-15-配置3的值 '(lambda p: p["effect"]=="曲线" and p["brightness"]==3 and p["sleepSeconds"]==60 and p["deepSleepMinutes"]==30 and p["color"]=="#FF7200")([p for p in d["status"]["profiles"] if p["profile"]==3][0])'
  check CL-15-按UUID载入 0 "已把预设「游戏」载入配置 2" "" -- c preset apply $game1
  check CL-15-重名 4 "" "有 2 个名为「游戏」的预设" -- c preset apply 游戏
  expect CL-15-重名列出两个ID test "${LAST_ERR//$game1/}" != "$LAST_ERR" -a "${LAST_ERR//$game2/}" != "$LAST_ERR"
  check CL-15-大小写不敏感 0 "已把预设「Office」载入" "" -- c preset apply office
  check CL-15-全半角不敏感 0 "已把预设「Office」载入" "" -- c preset apply ＯＦＦＩＣＥ
  check CL-15-其他型号 4 "" "预设「98 专用」来自其他型号" -- c preset apply "98 专用"
  check CL-15-越界数值（记录） 0 "" "" -- c preset apply 坏数据 -p 1 --json
  record CL-15-越界数值被夹紧 KNOWN 0 "${LAST_OUT//$'\n'/ }"
  seed_preset presets 77777777-7777-4777-8777-777777777777.cherryprofile \
    "$(preset_json 77777777-7777-4777-8777-777777777777 运行中新增 2026-02-01T00:00:00Z 482 3 2 2 00D70F false 300 30)"
  check CL-15-运行中新增 0 "运行中新增" "" -- c presets
  quit_sim presets

  launch_sim nbl98 nbl || return
  check CL-15-nbl载入 4 "" "没有需要修改的设置" -- cherry_safe "$(sim_socket nbl98)" preset apply 办公
  quit_sim nbl98
  launch_sim pix98 pixiu98 || return
  check CL-15-pixiu98载入无产品ID预设 0 "" "" -- cherry_safe "$(sim_socket pix98)" preset apply 办公 -p 1 --json
  record CL-15-pixiu98按编号映射灯效 KNOWN 0 "B15：${LAST_OUT//$'\n'/ }"
  quit_sim pix98
}

# ------------------------------------------------------------------------------------------------------ concurrency
parallel_writes() { # parallel_writes <名字> <标签>：CL-16，9 个命令并行写不同字段
  local name="$1" tag="$2" socket dir="$E2E_SCRATCH/$1-par" i=0
  socket="$(sim_socket "$name")"
  mkdir -p "$dir"
  watch_bg "$socket" "$dir/watch.ndjson" "$dir/watch.stderr" --json
  local watcher=$WATCHER
  for _ in {1..30}; do grep -q "开始监听" "$dir/watch.stderr" 2>/dev/null && break; sleep 0.1; done
  local -a commands=(
    "set -p 3 --effect 呼吸" "set -p 3 --brightness 1" "set -p 3 --speed 5" "set -p 3 --color #00D70F" "set -p 3 --sleep 60"
    "set -p 3 --deep-sleep 20" "set -p 1 --effect 曲线" "set -p 2 --brightness 2" "profile 1"
  )
  local start=$EPOCHREALTIME
  local -a writers
  for command in "${commands[@]}"; do
    i=$((i + 1))
    ( cherry_safe "$socket" ${=command} > "$dir/$i.out" 2> "$dir/$i.err"; print $? > "$dir/$i.code" ) &
    writers+=($!)
  done
  wait "${writers[@]}" 2>/dev/null
  local elapsed=$(( EPOCHREALTIME - start )) bad=""
  for i in {1..9}; do [[ "$(<"$dir/$i.code")" == 0 && ! -s "$dir/$i.err" ]] || bad+=" $i:$(<"$dir/$i.code"):$(<"$dir/$i.err")"; done
  if [[ -z "$bad" ]]; then record "CL-16-$tag-全部成功" PASS "$elapsed" ""; else record "CL-16-$tag-全部成功" FAIL "$elapsed" "$bad"; fi
  check "CL-16-$tag-最终状态" 0 "" "" -- cherry_safe "$socket" status --json
  json_expect "CL-16-$tag-每一项都写入" 'd["status"]["activeProfile"]==1 and (lambda p: p[3]["effect"]=="呼吸" and p[3]["brightness"]==1 and p[3]["speed"]==5 and p[3]["color"]=="#00D70F" and p[3]["randomColor"] is False and p[3]["sleepSeconds"]==60 and p[3]["deepSleepMinutes"]==20 and p[1]["effect"]=="曲线" and p[2]["brightness"]==2)({x["profile"]: x for x in d["status"]["profiles"]})'
  local final="$LAST_OUT"
  sleep 0.5
  kill $watcher 2>/dev/null; wait $watcher 2>/dev/null
  if python3 -I -c '
import json,sys
final=json.loads(sys.argv[1])["status"]
events=[json.loads(l) for l in open(sys.argv[2]) if l.strip()]
last=events[-1]
same=last["activeProfile"]==final["activeProfile"] and all(
  {k:v for k,v in a.items()}=={k:v for k,v in b.items()} for a,b in zip(last["profiles"], final["profiles"]))
sys.exit(0 if same else 1)' "$final" "$dir/watch.ndjson" 2>/dev/null; then
    record "CL-16-$tag-watch最后一个事件等于最终状态" PASS 0 ""
  else
    record "CL-16-$tag-watch最后一个事件等于最终状态" FAIL 0 "$(tail -1 "$dir/watch.ndjson" | cut -c1-300)"
  fi
}

active_profile_race() { # CL-17：10 个不带 -p 的写入与一次切换并行
  local name="$1" tag="$2" socket dir="$E2E_SCRATCH/$1-race"
  socket="$(sim_socket "$name")"
  mkdir -p "$dir"
  local start=$EPOCHREALTIME
  local -a racers
  for i in {0..9}; do
    ( cherry_safe "$socket" set --brightness $((i % 5)) --json > "$dir/$i.out" 2> "$dir/$i.err"; print $? > "$dir/$i.code" ) &
    racers+=($!)
  done
  ( cherry_safe "$socket" profile 2 > "$dir/p.out" 2> "$dir/p.err"; print $? > "$dir/p.code" ) &
  racers+=($!)
  wait "${racers[@]}"
  local elapsed=$(( EPOCHREALTIME - start )) bad="" targets=""
  for i in {0..9}; do
    [[ "$(<"$dir/$i.code")" == 0 ]] || bad+=" $i:$(<"$dir/$i.code"):$(<"$dir/$i.err")"
    targets+="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["profile"]["profile"], end=" ")' "$dir/$i.out" 2>/dev/null)"
  done
  [[ "$(<"$dir/p.code")" == 0 ]] || bad+=" profile:$(<"$dir/p.code"):$(<"$dir/p.err")"
  if [[ -z "$bad" ]]; then record "CL-17-$tag-全部成功" PASS "$elapsed" "目标配置档：$targets"; else record "CL-17-$tag-全部成功" FAIL "$elapsed" "$bad"; fi
  print -r -- "$tag 目标配置档：$targets（${elapsed}s）" >> "$E2E_RUN/timings.tsv"
}

suite_concurrency() {
  E2E_SUITE=concurrency
  launch_sim conc pixiu75 || return
  parallel_writes conc pixiu75
  active_profile_race conc pixiu75
  # CL-19：64 个并发连接
  local dir="$E2E_SCRATCH/conc-64" socket
  socket="$(sim_socket conc)"
  mkdir -p "$dir"
  local -a callers
  for i in {1..64}; do ( cherry_safe "$socket" keyboards > /dev/null 2> "$dir/$i.err"; print $? > "$dir/$i.code" ) & callers+=($!); done
  wait "${callers[@]}"
  local refused=0
  for i in {1..64}; do [[ "$(<"$dir/$i.code")" == 0 ]] || refused=$((refused + 1)); done
  if (( refused == 0 )); then record CL-19-64个并发连接 PASS 0 ""; else record CL-19-64个并发连接 FAIL 0 "$refused 个失败（B10）：$(cat "$dir"/*.err | sort -u | head -3)"; fi
  quit_sim conc

  launch_sim slowc slow || return
  parallel_writes slowc slow
  active_profile_race slowc slow
  quit_sim slowc
}

# ------------------------------------------------------------------------------------------------------------ watch
suite_watch() {
  E2E_SUITE=watch
  launch_sim w pixiu75 || return
  SOCK="$(sim_socket w)"
  local dir="$E2E_SCRATCH/w"
  mkdir -p "$dir"
  watch_bg "$SOCK" "$dir/watch.ndjson" "$dir/watch.stderr" --json
  local watcher=$WATCHER acknowledged=0
  for _ in {1..30}; do grep -q "开始监听" "$dir/watch.stderr" 2>/dev/null && { acknowledged=1; break; }; sleep 0.1; done
  expect "CL-20-watch--json的确认写到stderr（B6）" test $acknowledged = 1
  local rss_before rss_after
  rss_before=$(ps -o rss= -p $watcher | tr -d ' ')
  local start=$EPOCHREALTIME
  for i in {1..200}; do c set -p 3 --brightness $((i % 5)) > /dev/null 2>> "$dir/set.err"; done
  local elapsed=$(( EPOCHREALTIME - start ))
  sleep 0.5
  rss_after=$(ps -o rss= -p $watcher | tr -d ' ')
  kill $watcher 2>/dev/null; wait $watcher 2>/dev/null
  local lines last
  lines=$(grep -c . "$dir/watch.ndjson")
  last=$(tail -1 "$dir/watch.ndjson" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print([p for p in d["profiles"] if p["profile"]==3][0]["brightness"])' 2>/dev/null)
  if [[ $lines == 200 && $last == 0 ]]; then record CL-20-200个事件一个不漏 PASS "$elapsed" ""; else record CL-20-200个事件一个不漏 FAIL "$elapsed" "收到 $lines 行，最后亮度 $last"; fi
  if (( rss_after < rss_before + 8192 )); then record CL-20-watch内存稳定 PASS 0 "${rss_before}→${rss_after} KB"; else record CL-20-watch内存稳定 FAIL 0 "${rss_before}→${rss_after} KB"; fi
  watch_bg "$SOCK" "$dir/human.out" /dev/null
  watcher=$WATCHER
  sleep 0.5
  c profile 2 > /dev/null
  sleep 0.5
  kill $watcher 2>/dev/null; wait $watcher 2>/dev/null
  expect CL-20-文本格式 grep -qE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] 046A:01E2@03100000 当前 配置 2：' "$dir/human.out"

  # CL-21：App 正常退出或被强杀时，watch 3 秒内以 3 结束
  for how in quit crash; do
    watch_bg "$SOCK" "$dir/$how.out" "$dir/$how.err" --json
    watcher=$WATCHER
    sleep 0.5
    if [[ $how == quit ]]; then quit_sim w; else crash_sim w; fi
    local code=0 waited=0
    for _ in {1..30}; do kill -0 $watcher 2>/dev/null || break; sleep 0.1; waited=$((waited + 1)); done
    wait $watcher; code=$?
    # --json 时错误以 JSON 写到 stdout（B9），与事件一样只占一行；stderr 只有开始监听的确认。
    if [[ $code == 3 ]] && (( $(wc -l < "$dir/$how.out") == 1 )) && grep -q '^{"error":{"code":"appUnavailable"' "$dir/$how.out" \
       && grep -q "关闭了连接" "$dir/$how.out" && (( waited < 30 )); then
      record "CL-21-App$how后watch退出" PASS "$((waited / 10.0))" ""
    else
      record "CL-21-App$how后watch退出" FAIL 0 "退出码 $code，stdout：$(<"$dir/$how.out")，stderr：$(<"$dir/$how.err")"
      kill $watcher 2>/dev/null
    fi
    [[ $how == quit ]] && { launch_sim w pixiu75 || return; }
  done
}

# -------------------------------------------------------------------------------------------------------- lifecycle
suite_lifecycle() {
  E2E_SUITE=lifecycle
  launch_sim nested/deeper/s pixiu75 || return
  local socket="$E2E_SCRATCH/nested/deeper/s.sock"
  expect CL-22a-socket权限600 test "$(stat -f %Lp "$socket")" = 600
  expect CL-22a-新建目录700 test "$(stat -f %Lp "$E2E_SCRATCH/nested/deeper")" = 700
  quit_sim nested/deeper/s
  sleep 0.3
  expect CL-22b-正常退出删除socket test ! -e "$socket"
  check CL-22b-之后报未运行 3 "" "没有运行（socket：$socket）" -- cherry_safe "$socket" status

  launch_sim life pixiu75 || return
  socket="$(sim_socket life)"
  local inode_before inode_after
  inode_before=$(stat -f %i "$socket")
  crash_sim life
  expect CL-22c-强杀后socket残留 test -S "$socket"
  check CL-22c-残留socket报未运行 3 "" "没有运行" -- cherry_safe "$socket" status
  launch_sim life pixiu75 || return
  inode_after=$(stat -f %i "$socket")
  expect CL-22c-重启替换残留socket test "$inode_before" != "$inode_after"
  check CL-22c-重启后可用 0 "CHERRY Utility" "" -- cherry_safe "$socket" version

  local since="$(date '+%Y-%m-%d %H:%M:%S')"
  local first="${E2E_PIDS[life]}"
  E2E_PIDS[life]=""
  launch_sim life pixiu75 || true   # 同一 socket 的第二个实例
  local second="${E2E_PIDS[life]}"
  E2E_PIDS[life-a]="$first"
  E2E_PIDS[life-b]="$second"
  unset "E2E_PIDS[life]"
  sleep 1
  check CL-22d-第一个实例继续服务 0 "CHERRY Utility" "" -- cherry_safe "$socket" version
  if /usr/bin/log show --style compact --info --start "$since" --predicate 'subsystem == "online.odeployer.CherryUtility" AND category == "control"' 2>/dev/null | grep -q "already served by another instance"; then
    record CL-22d-第二个实例记录alreadyRunning PASS 0 ""
  else
    record CL-22d-第二个实例记录alreadyRunning FAIL 0 "日志里没有 already served"
  fi
  quit_sim life-b
  expect CL-22d-第二个实例退出后socket还在 test -S "$socket"
  check CL-22d-仍由第一个实例服务 0 "CHERRY Utility" "" -- cherry_safe "$socket" version
  quit_sim life-a
  sleep 0.3
  expect CL-22d-第一个实例退出后socket删除 test ! -e "$socket"

  local occupied="$E2E_SCRATCH/occupied.sock"
  print -r -- "keep" > "$occupied"
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  open -n -g -j --env CHERRY_SIMULATION=pixiu75 --env CHERRY_CONTROL_SOCKET="$occupied" \
    --env CHERRY_PRESET_DIR="$E2E_SCRATCH/occupied-presets" "$E2E_APP" --args --background
  sleep 3
  for pid in $(pgrep -x CherryUtility); do
    ps -wwE -p "$pid" -o command= | grep -q "CHERRY_CONTROL_SOCKET=$occupied" && E2E_PIDS[occupied]=$pid
  done
  expect CL-22e-实例照常运行 sim_alive occupied
  expect CL-22e-普通文件不被删除 test "$(<"$occupied")" = keep
  if /usr/bin/log show --style compact --info --start "$since" --predicate 'subsystem == "online.odeployer.CherryUtility" AND category == "control"' 2>/dev/null | grep -q "pathOccupied"; then
    record CL-22e-日志记录pathOccupied PASS 0 ""
  else
    record CL-22e-日志记录pathOccupied FAIL 0 "日志里没有 pathOccupied"
  fi
  local code=0 err
  err="$(cherry_safe "$occupied" status 2>&1 >/dev/null)" || code=$?
  if [[ $code == 1 && "$err" == *"不是 socket"* ]]; then record CL-22e-占用时命令行说明原因 PASS 0 "$err"; else record CL-22e-占用时命令行说明原因 FAIL 0 "退出码 $code：$err"; fi
  quit_sim occupied
}

# -------------------------------------------------------------------------------------------------------- scenarios
suite_scenarios() {
  E2E_SUITE=scenarios
  launch_sim dual dual || return; SOCK="$(sim_socket dual)"
  check CL-05-dual歧义 4 "" "046A:01E2@03100000  CHERRY MX PIXIU 75" -- c status
  expect CL-05-dual列出第二把 test "${LAST_ERR//046A:01E2@03200000/}" != "$LAST_ERR"
  check CL-05-dual歧义JSON 4 '"candidates"' "" -- c status --json
  json_expect CL-05-dual候选 '[k["id"] for k in d["error"]["candidates"]]==["046A:01E2@03100000","046A:01E2@03200000"]'
  check CL-05-dual列表 0 "046A:01E2@03200000" "" -- c keyboards
  check CL-05-dual指定B写入 0 "已更新配置 3：亮度 低" "" -- c set -k 046A:01E2@03200000 -p 3 --brightness 1
  check CL-05-dualA不变 0 "  配置 3：常亮 · 亮度 4/4" "" -- c status -k 046A:01E2@03100000
  check CL-05-dual没见过的ID在两把同型号时 4 "" "未找到设备" -- c status -k 046A:01E2@03990000
  check CL-05-dual-effects（记录） 4 "" "连接了多把键盘" -- c effects
  mcp "$SOCK" scenarios scenario-dual
  quit_sim dual

  launch_sim nbl nbl || return; SOCK="$(sim_socket nbl)"
  check CL-07-nbl灯效 0 "没有背光灯效" "" -- c effects
  check CL-07-nbl灯效JSON 0 "" "" -- c effects --json
  json_expect CL-07-nbl灯效为空 'd["effects"]==[]'
  check CL-07-nbl设灯效 4 "" "没有背光，不能设置灯效" -- c set --effect 波纹
  check CL-07-nbl设颜色 4 "" "不支持设置颜色" -- c set --color '#FF0000'
  check CL-07-nbl设休眠 4 "" "不支持休眠设置" -- c set --sleep 60
  check CL-07-nbl切换 0 "已切换到配置 3（无背光）" "" -- c profile 3
  check CL-07-nbl状态 0 "* 配置 3：无背光" "" -- c status
  check CL-07-nbl状态JSON 0 "" "" -- c status --json
  json_expect CL-07-nbl只有profile字段 'all(set(p)=={"profile"} for p in d["status"]["profiles"])'
  check CL-07-nbl电量 4 "" "是有线键盘，没有电量" -- c battery
  mcp "$SOCK" scenarios scenario-nbl
  quit_sim nbl

  launch_sim mx mx30s || return; SOCK="$(sim_socket mx)"
  check CL-08-mx30s电量 4 "" "MX BOARD 3.0S FL RGB 是有线键盘，没有电量" -- c battery
  check CL-08-mx30s休眠 4 "" "不支持休眠设置" -- c set --sleep 0
  check CL-08-mx30s颜色 0 "颜色 #3153FF" "" -- c set --color '#3153FF'
  check CL-08-mx30s状态JSON 0 "" "" -- c status --json
  json_expect CL-08-mx30s字段 '"battery" not in d["status"] and all("sleepSeconds" not in p and "color" in p for p in d["status"]["profiles"]) and d["status"]["connection"]=="USB"'
  mcp "$SOCK" scenarios scenario-mx30s
  quit_sim mx

  launch_sim rcv receiver || return; SOCK="$(sim_socket rcv)"
  check CL-09-receiver状态 0 "64%（未充电）" "" -- c status
  expect CL-09-receiver名称与无线 test "${LAST_OUT//Receiver/}" != "$LAST_OUT" -a "${LAST_OUT//无线/}" != "$LAST_OUT"
  check CL-09-receiver休眠 0 "休眠 60 秒" "" -- c set --sleep 60
  check CL-09-receiver灯效 0 "" "" -- c effects --json
  json_expect CL-09-receiver11种灯效 'len(d["effects"])==11'
  quit_sim rcv

  launch_sim p98 pixiu98 || return; SOCK="$(sim_socket p98)"
  check CL-10-pixiu98灯效 0 "彩虹雨（Rainbow Rain）" "" -- c effects
  check CL-10-pixiu98灯效JSON 0 "" "" -- c effects --json
  json_expect CL-10-pixiu98有12种 'len(d["effects"])==12'
  check CL-10-pixiu98呼吸 0 "" "" -- c set --effect Breathing --json
  json_expect CL-10-pixiu98呼吸英文名 'd["profile"]["effectEnglishName"]=="Breathing" and d["profile"]["effect"]=="呼吸"'
  check CL-10-pixiu98彩虹雨 0 "灯效 彩虹雨" "" -- c set --effect 彩虹雨
  check CL-10-pixiu98对战 4 "" "没有「battle」灯效" -- c set --effect battle
  quit_sim p98

  for scenario in empty unsupported; do
    launch_sim $scenario $scenario || return; SOCK="$(sim_socket $scenario)"
    check "CL-11-$scenario-列表" 0 "没有连接受支持的 CHERRY 键盘" "" -- c keyboards
    check "CL-11-$scenario-列表JSON" 0 "" "" -- c keyboards --json
    json_expect "CL-11-$scenario-列表为空" 'd.get("keyboards", [])==[]'
    check "CL-11-$scenario-状态" 4 "" "没有连接受支持的 CHERRY 键盘" -- c status
    expect "CL-11-$scenario-第二次不再冷启动等待" test "${LAST_SECONDS%.*}" -lt 2
    [[ $scenario == empty ]] && mcp "$SOCK" scenarios scenario-empty
    quit_sim $scenario
  done

  launch_sim denied denied || return; SOCK="$(sim_socket denied)"
  check CL-12-denied列表 0 "046A:01E2@03100000" "" -- c keyboards
  check CL-12-denied状态 4 "" "输入监控" -- c status
  check CL-12-denied电量 4 "" "输入监控" -- c battery
  check CL-12-denied切换 4 "" "输入监控" -- c profile 1
  check CL-12-denied灯效（记录） 0 "" "" -- c effects
  mcp "$SOCK" scenarios scenario-denied
  quit_sim denied

  launch_sim wl wireless || return; SOCK="$(sim_socket wl)"
  check CL-13-wireless电量 0 "15%（未充电）" "" -- c battery
  check CL-13-wireless列表 0 "" "" -- c keyboards
  record CL-13-wireless连接方式（记录） KNOWN 0 "$LAST_OUT"
  check CL-13-wireless写入 0 "亮度 中" "" -- c set -p 1 --brightness 2
  quit_sim wl

  launch_sim slow slow || return; SOCK="$(sim_socket slow)"
  # 上限与意图用例（UI-138）一致：读取 < 5 秒、写入 < 10 秒。
  check CL-14-slow状态 0 "" "" -- c status
  print -r -- "slow status ${LAST_SECONDS}s" >> "$E2E_RUN/timings.tsv"
  expect CL-14-slow状态小于5秒 test "${LAST_SECONDS%.*}" -lt 5
  check CL-14-slow指定配置档写入 0 "" "" -- c set -p 3 --brightness 1
  local explicit="$LAST_SECONDS"
  print -r -- "slow set -p 3 ${LAST_SECONDS}s" >> "$E2E_RUN/timings.tsv"
  expect CL-14-slow指定写入小于10秒 test "${LAST_SECONDS%.*}" -lt 10
  check CL-14-slow当前配置档写入 0 "" "" -- c set --brightness 2
  print -r -- "slow set ${LAST_SECONDS}s" >> "$E2E_RUN/timings.tsv"
  expect CL-14-slow当前写入小于10秒 test "${LAST_SECONDS%.*}" -lt 10
  # B4：当前档在写入事务内解析，不再先单独读一次，耗时与指定配置档相当。
  expect CL-14-slow当前写入不另读一次 zsh -c "(( $LAST_SECONDS < $explicit + 1.5 ))"
  quit_sim slow
}

# -------------------------------------------------------------------------------------------------------------- mcp
suite_mcp() {
  E2E_SUITE=mcp
  local office=11111111-1111-4111-8111-111111111111
  seed_preset mcp "$office.cherryprofile" "$(preset_json $office 办公 2026-01-01T00:00:00Z null 12 3 1 FF7200 false 60 30)"
  seed_preset mcp g1.cherryprofile "$(preset_json 22222222-2222-4222-8222-222222222222 游戏 2026-01-02T00:00:00Z 482 0 4 4 FF0000 false 300 30)"
  seed_preset mcp g2.cherryprofile "$(preset_json 33333333-3333-4333-8333-333333333333 游戏 2026-01-03T00:00:00Z 482 2 1 2 0099FF false 300 30)"
  seed_preset mcp p98.cherryprofile "$(preset_json 44444444-4444-4444-8444-444444444444 '98 专用' 2026-01-04T00:00:00Z 486 5 4 3 FFFFFF true 300 30)"
  launch_sim mcp pixiu75 || return
  mcp "$(sim_socket mcp)" mcp basic,full,errors,extremes,protocol,versions,concurrency,garbage,eof
  mcp "/tmp/cherry-e2e-none.sock" mcp unavailable
  expect MC-04-App仍在运行 sim_alive mcp
  quit_sim mcp
  launch_sim mcpslow slow || return
  mcp "$(sim_socket mcpslow)" mcp-slow concurrency,eof,cancel
  quit_sim mcpslow
  mcp_restart
}

# MC-09：同一个 cherry mcp 进程里，App 退出时工具报 appUnavailable，App 重新启动后无需重启 MCP 就恢复。
# 经 FIFO 喂标准输入，这样能在会话中途用 quit_sim / launch_sim 重启 App。
mcp_restart() {
  launch_sim mcpr pixiu75 || return
  local socket dir="$E2E_SCRATCH/mcpr" feed server
  socket="$(sim_socket mcpr)"
  mkdir -p "$dir" && mkfifo "$dir/in"
  ( CHERRY_CONTROL_SOCKET="$socket" exec "$E2E_CLI" mcp < "$dir/in" > "$dir/out" 2> "$dir/err" ) &
  server=$!
  exec {feed}> "$dir/in"
  mcpr_call() { # mcpr_call <id> <工具>：发一个 tools/call，等它的响应（最多 30 秒），打印 isError 与错误码
    print -u $feed -r -- '{"jsonrpc":"2.0","id":'$1',"method":"tools/call","params":{"name":"'$2'","arguments":{}}}'
    for _ in {1..300}; do
      grep -q "\"id\":$1[,}]" "$dir/out" && break
      sleep 0.1
    done
    python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    m = json.loads(line)
    if m.get("id") == int(sys.argv[2]):
        r = m.get("result") or {}
        print(r.get("isError", False), (r.get("structuredContent") or {}).get("error", {}).get("code", ""))
        break
else:
    print("missing")' "$dir/out" "$1"
  }
  print -u $feed -r -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"restart","version":"1"}}}'
  print -u $feed -r -- '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  local reply
  reply="$(mcpr_call 2 get_status)"
  if [[ "$reply" == "False "* ]]; then record MC-09-重启前可用 PASS 0 ""; else record MC-09-重启前可用 FAIL 0 "$reply"; fi
  quit_sim mcpr
  reply="$(mcpr_call 3 get_status)"
  if [[ "$reply" == "True appUnavailable" ]]; then record MC-09-App退出后报appUnavailable PASS 0 ""; else record MC-09-App退出后报appUnavailable FAIL 0 "$reply"; fi
  launch_sim mcpr pixiu75 || { exec {feed}>&-; return; }
  reply="$(mcpr_call 4 get_status)"
  if [[ "$reply" == "False "* ]] && kill -0 $server 2>/dev/null; then
    record MC-09-App重启后同一MCP进程恢复 PASS 0 ""
  else
    record MC-09-App重启后同一MCP进程恢复 FAIL 0 "$reply"
  fi
  exec {feed}>&-
  local code=0 waited=0
  while kill -0 $server 2>/dev/null && (( waited < 50 )); do sleep 0.1; waited=$((waited + 1)); done
  kill -0 $server 2>/dev/null && { kill $server; record MC-09-关闭输入后退出 FAIL 0 "5 秒内没有退出"; } || {
    wait $server; code=$?
    if [[ $code == 0 && ! -s "$dir/err" ]]; then record MC-09-关闭输入后退出 PASS 0 ""; else record MC-09-关闭输入后退出 FAIL 0 "退出码 $code：$(<"$dir/err")"; fi
  }
  quit_sim mcpr
}

# ------------------------------------------------------------------------------------------------------------ cross
suite_cross() {
  E2E_SUITE=cross
  launch_sim x pixiu75 || return
  SOCK="$(sim_socket x)"
  local dir="$E2E_SCRATCH/x"
  mkdir -p "$dir"
  watch_bg "$SOCK" "$dir/watch.ndjson" "$dir/watch.stderr" --json
  local watcher=$WATCHER
  for _ in {1..30}; do grep -q "开始监听" "$dir/watch.stderr" 2>/dev/null && break; sleep 0.1; done
  python3 -I - "$E2E_CLI" "$SOCK" > "$dir/mcp.out" 2>&1 <<'PY'
import json, subprocess, sys
cli, socket = sys.argv[1], sys.argv[2]
p = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env={"CHERRY_CONTROL_SOCKET": socket, "PATH": "/usr/bin:/bin"})
def send(i, method, params=None):
    m = {"jsonrpc": "2.0", "id": i, "method": method}
    if params is not None: m["params"] = params
    p.stdin.write((json.dumps(m) + "\n").encode()); p.stdin.flush()
    while True:
        r = json.loads(p.stdout.readline())
        if r.get("id") == i: return r
send(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
print(send(2, "tools/call", {"name": "set_lighting", "arguments": {"effect": "Curve", "brightness": 1, "profile": 3}})["result"]["content"][0]["text"])
print(send(3, "tools/call", {"name": "switch_profile", "arguments": {"profile": 1}})["result"]["content"][0]["text"])
p.stdin.close(); p.wait(timeout=10)
PY
  sleep 0.5
  kill $watcher 2>/dev/null; wait $watcher 2>/dev/null
  check XF-01-命令行读到的状态 0 "" "" -- c status --json
  local final="$LAST_OUT"
  if python3 -I -c '
import json,sys
events=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
final=json.loads(sys.argv[2])["status"]
p3=[p for p in events[0]["profiles"] if p["profile"]==3][0] if events else {}
ok=len(events)==2 and p3.get("effect")=="曲线" and p3.get("brightness")==1 and events[1]["activeProfile"]==1 \
   and events[1]["profiles"]==final["profiles"] and final["activeProfile"]==1
sys.exit(0 if ok else 1)' "$dir/watch.ndjson" "$final" 2>/dev/null; then
    record XF-01-MCP写入恰好两个watch事件 PASS 0 "$(tr '\n' ' ' < "$dir/mcp.out")"
  else
    record XF-01-MCP写入恰好两个watch事件 FAIL 0 "$(wc -l < "$dir/watch.ndjson") 行；$(tr '\n' ' ' < "$dir/mcp.out")"
  fi
  quit_sim x
}

for suite in ${(s:,:)suites}; do
  e2e_aborted && { print -u2 "看门狗中止了运行（见 $E2E_RUN/watchdog.log）"; exit 99; }
  print "== $suite"
  "suite_$suite"
done
e2e_aborted && { print -u2 "看门狗中止了运行（见 $E2E_RUN/watchdog.log）"; exit 99; }

total=$(grep -c . "$E2E_RUN/results.tsv")
failed=$(awk -F'\t' '$3=="FAIL"' "$E2E_RUN/results.tsv" | wc -l | tr -d ' ')
known=$(awk -F'\t' '$3=="KNOWN"' "$E2E_RUN/results.tsv" | wc -l | tr -d ' ')
print "合计 $total 项：失败 $failed，已知/记录 $known。详见 $E2E_RUN/results.tsv"
(( failed == 0 ))
