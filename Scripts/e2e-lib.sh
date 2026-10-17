#!/bin/zsh
# 模拟端到端检查的公共函数（由 verify-cli.sh、verify-cross.sh 引入）。
#
# 安全规则：只用模拟键盘。真机可能正连在 USB 上，所以：
# - App 只以 CHERRY_SIMULATION=<场景> 启动，看门狗发现没有这个环境变量的 CherryUtility 进程就立即结束它并中止；
# - cherry / cherry mcp 只连 /tmp/cherry-* 下的 socket，不允许走默认 socket（那会以真机模式拉起已安装的 App）；
# - 默认 socket ~/Library/Application Support/CherryUtility/control.sock 一旦出现，也中止。
# App 的预设目录与 socket 都在 /tmp 下：App 访问 ~/Downloads（本仓库所在处）会弹 TCC 提示。

zmodload zsh/datetime   # EPOCHREALTIME：每项检查的耗时

E2E_DEFAULT_SOCKET="$HOME/Library/Application Support/CherryUtility/control.sock"
typeset -g E2E_RUN="" E2E_SCRATCH="" E2E_WATCHDOG="" E2E_FAILURES=0 E2E_SUITE="" E2E_APP="" E2E_CLI=""
typeset -gA E2E_PIDS

e2e_init() { # e2e_init <运行目录> <App>
  E2E_RUN="$1"
  E2E_APP="${2:A}"
  E2E_CLI="$E2E_APP/Contents/MacOS/cherry"
  [[ -x "$E2E_CLI" && -x "$E2E_APP/Contents/MacOS/CherryUtility" ]] || { print -u2 "missing app or cherry in $E2E_APP"; exit 66; }
  mkdir -p "$E2E_RUN"
  E2E_SCRATCH="$(mktemp -d /tmp/cherry-e2e.XXXXXX)"
  : >> "$E2E_RUN/results.tsv"
  e2e_preflight
  e2e_watchdog_start
}

e2e_preflight() {
  if pgrep -x CherryUtility >/dev/null; then
    print -u2 "已有 CherryUtility 进程在运行（$(pgrep -x CherryUtility | tr '\n' ' ')），请先退出它再跑模拟检查"
    exit 75
  fi
  if [[ -e "$E2E_DEFAULT_SOCKET" ]]; then
    print -u2 "默认 socket 存在：$E2E_DEFAULT_SOCKET（真机模式的 App 可能在运行）"
    exit 75
  fi
  [[ -z "${CHERRY_UITEST_HARDWARE:-}${TEST_RUNNER_CHERRY_UITEST_HARDWARE:-}" ]] || { print -u2 "不允许开启真机测试变量"; exit 75; }
}

# 进程正在退出（测试收尾时结束 App）时 `ps -E` 读不到它的环境（2026-10-17 的 UI 回归里因此误判过一次）。
# 读不到 CHERRY_SIMULATION= 时每 0.2 秒重读，最多 3 次；期间进程退出就不算；一直活着且没有这个变量才算非模拟实例。
e2e_is_simulated() {
  local pid="$1"
  for _ in 1 2 3; do
    kill -0 "$pid" 2>/dev/null || return 0
    [[ "$(ps -wwE -p "$pid" -o command= 2>/dev/null)" == *CHERRY_SIMULATION=* ]] && return 0
    sleep 0.2
  done
  ! kill -0 "$pid" 2>/dev/null
}

# 每秒检查：所有 CherryUtility 进程都必须带 CHERRY_SIMULATION=；默认 socket 不能出现。
e2e_watchdog_start() {
  local log="$E2E_RUN/watchdog.log" abort="$E2E_RUN/ABORT"
  (
    while true; do
      for pid in $(pgrep -x CherryUtility); do
        e2e_is_simulated "$pid" && continue
        kill -9 "$pid" 2>/dev/null
        print "$(date +%T) 非模拟模式的 CherryUtility（pid $pid），已结束" >> "$log"
        touch "$abort"
      done
      if [[ -e "$E2E_DEFAULT_SOCKET" ]]; then
        print "$(date +%T) 出现默认 socket" >> "$log"
        touch "$abort"
      fi
      sleep 1
    done
  ) &
  E2E_WATCHDOG=$!
}

e2e_aborted() { [[ -e "$E2E_RUN/ABORT" ]]; }

e2e_cleanup() {
  local pid
  for pid in ${(v)E2E_PIDS}; do kill -TERM "$pid" 2>/dev/null; done
  sleep 1
  for pid in ${(v)E2E_PIDS}; do kill -9 "$pid" 2>/dev/null; done
  [[ -n "$E2E_WATCHDOG" ]] && kill "$E2E_WATCHDOG" 2>/dev/null
  [[ -n "$E2E_SCRATCH" ]] && rm -rf "$E2E_SCRATCH"
}

# launch_sim <名字> <场景> [附加 --env 变量…]：后台启动一个模拟实例；socket 为 $E2E_SCRATCH/<名字>.sock。
# 预设目录 $E2E_SCRATCH/<名字>-presets 可事先由 seed_preset 写入。pid 由启动前后的进程差集确定。
launch_sim() {
  local name="$1" scenario="$2"
  shift 2
  local socket="$E2E_SCRATCH/$name.sock" before after pid
  local -a extra
  for variable in "$@"; do extra+=(--env "$variable"); done
  before=" $(pgrep -x CherryUtility | tr '\n' ' ') "
  open -n -g -j --env CHERRY_SIMULATION="$scenario" --env CHERRY_CONTROL_SOCKET="$socket" \
    --env CHERRY_PRESET_DIR="$E2E_SCRATCH/$name-presets" "${extra[@]}" "$E2E_APP" --args --background
  # 等新进程出现且 socket 有实例应答：崩溃留下的旧 socket 一开始就存在，只看文件会在新实例接管前返回。
  local answered=""
  for _ in {1..150}; do
    for pid in $(pgrep -x CherryUtility); do
      [[ "$before" == *" $pid "* ]] || after="$pid"
    done
    if [[ -n "$after" && -S "$socket" ]] && CHERRY_CONTROL_SOCKET="$socket" "$E2E_CLI" version > /dev/null 2>&1; then
      answered=1
      break
    fi
    sleep 0.1
  done
  [[ -n "$answered" ]] || { print -u2 "模拟实例 $name（$scenario）15 秒内没有在 socket 上应答"; return 1; }
  E2E_PIDS[$name]="$after"
}

sim_socket() { print -r -- "$E2E_SCRATCH/$1.sock"; }

# 正常退出（SIGTERM 走与 ⌘Q 相同的流程），最多等 5 秒。
quit_sim() {
  local pid="${E2E_PIDS[$1]}"
  [[ -n "$pid" ]] || return 0
  kill -TERM "$pid" 2>/dev/null
  for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && { print -u2 "实例 $1 5 秒内没有退出"; kill -9 "$pid"; }
  unset "E2E_PIDS[$1]"
}

crash_sim() {
  local pid="${E2E_PIDS[$1]}"
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
  for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  unset "E2E_PIDS[$1]"
}

sim_alive() { [[ -n "${E2E_PIDS[$1]}" ]] && kill -0 "${E2E_PIDS[$1]}" 2>/dev/null; }

# cherry_safe <socket> <参数…>：只允许 /tmp/cherry-* 下的 socket。
cherry_safe() {
  local socket="$1"
  shift
  case "$socket" in
    /tmp/cherry-*|/private/tmp/cherry-*) ;;
    *) print -u2 "cherry_safe：拒绝 socket $socket"; return 70 ;;
  esac
  CHERRY_CONTROL_SOCKET="$socket" "$E2E_CLI" "$@"
}

# watch_bg <socket> <stdout 文件> <stderr 文件> [--json]：后台运行 cherry watch，$WATCHER 是 cherry 进程本身
# （用 exec 替换子 shell），kill / wait 直接作用于它，退出码也是它的。
typeset -g WATCHER=""
watch_bg() {
  local socket="$1" out="$2" err="$3"
  shift 3
  ( cherry_safe_check "$socket" || exit 70; CHERRY_CONTROL_SOCKET="$socket" exec "$E2E_CLI" watch "$@" > "$out" 2> "$err" ) &
  WATCHER=$!
}

cherry_safe_check() {
  case "$1" in
    /tmp/cherry-*|/private/tmp/cherry-*) return 0 ;;
    *) print -u2 "cherry_safe：拒绝 socket $1"; return 70 ;;
  esac
}

# record <ID> <PASS|FAIL|KNOWN|SKIP> <秒> <说明>
record() {
  print -r -- "$E2E_SUITE	$1	$2	$3	$4" >> "$E2E_RUN/results.tsv"
  print -r -- "$2  [$E2E_SUITE] $1 $4"
  [[ "$2" == FAIL ]] && E2E_FAILURES=$((E2E_FAILURES + 1))
  return 0
}

# check <ID> <期望退出码> <stdout 须含> <stderr 须含> -- <命令…>；空字符串表示不检查。
# 每次的命令、stdout、stderr、退出码、耗时都记入 transcript。
typeset -g LAST_OUT="" LAST_ERR="" LAST_CODE=0 LAST_SECONDS=0
check() {
  local id="$1" expected="$2" out_fragment="$3" err_fragment="$4"
  shift 5
  local start=$EPOCHREALTIME out err code=0
  local out_file="$E2E_SCRATCH/out.$$" err_file="$E2E_SCRATCH/err.$$"
  "$@" > "$out_file" 2> "$err_file" || code=$?
  LAST_OUT="$(<"$out_file")" LAST_ERR="$(<"$err_file")" LAST_CODE=$code
  LAST_SECONDS=$(( EPOCHREALTIME - start ))
  print -r -- "## $id  $*"$'\n'"--- stdout"$'\n'"$LAST_OUT"$'\n'"--- stderr"$'\n'"$LAST_ERR"$'\n'"(exit $code, ${LAST_SECONDS}s)"$'\n' >> "$E2E_RUN/transcript.txt"
  if [[ "$code" == "$expected" && "$LAST_OUT" == *"$out_fragment"* && "$LAST_ERR" == *"$err_fragment"* ]]; then
    record "$id" PASS "$LAST_SECONDS" ""
  else
    record "$id" FAIL "$LAST_SECONDS" "退出码 $code（期望 $expected）；stdout：${LAST_OUT:0:300}；stderr：${LAST_ERR:0:300}"
  fi
}

# json_expect <ID> <Python 表达式（变量 d 为 stdout 解析后的 JSON）>：检查最近一次 check 的 stdout。
json_expect() {
  local id="$1" expression="$2"
  if print -r -- "$LAST_OUT" | python3 -I -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($expression) else 1)" 2>/dev/null; then
    record "$id" PASS 0 ""
  else
    record "$id" FAIL 0 "JSON 不满足 $expression：${LAST_OUT:0:400}"
  fi
}

# expect <ID> <shell 条件…>
expect() {
  local id="$1"
  shift
  if "$@"; then record "$id" PASS 0 ""; else record "$id" FAIL 0 "条件不成立：$*"; fi
}

# seed_preset <名字（实例）> <文件名> <JSON>：按 ProfilePreset 的格式写入实例的预设目录（App 启动前或运行中都可以）。
seed_preset() {
  local directory="$E2E_SCRATCH/$1-presets"
  mkdir -p "$directory"
  print -r -- "$3" > "$directory/$2"
}

# preset_json <UUID> <名称> <ISO 时间> <productID 或 null> <effect> <brightness> <speed> <RRGGBB> <random true/false> <sleep> <deep>
preset_json() {
  local r=$((16#${8[1,2]})) g=$((16#${8[3,4]})) b=$((16#${8[5,6]}))
  local product="$4"
  [[ "$product" == null ]] || product="$product"
  print -r -- "{\"createdAt\":\"$3\",\"id\":\"$1\",\"name\":\"$2\",\"productID\":$product,\"settings\":{\"brightness\":$6,\"color\":{\"b\":$b,\"g\":$g,\"r\":$r},\"deepSleepMinutes\":${11},\"effect\":$5,\"randomColor\":$9,\"sleepSeconds\":${10},\"speed\":$7}}"
}
