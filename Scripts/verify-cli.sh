#!/bin/zsh
# `cherry` 命令行的端到端检查：以模拟模式在后台启动一个构建好的 App，再用包内的 cherry 读取、切换、设置和监听。
#
#   Scripts/verify-cli.sh [<CherryUtility.app>]
#
# 默认 App 为 ~/Library/Developer/Xcode/DerivedData/CherryUtility-automation 的 Debug 构建（先用 xcodebuild 构建）。
# App 运行在模拟键盘上（CHERRY_SIMULATION=pixiu75），socket 与预设目录在 /tmp 下的独立目录：
# 不碰正式 App 的 socket，也不让 App 访问 ~/Downloads（会弹 TCC 提示）。结束时只关闭本次启动的进程。
# 输出与 watch 事件记在 build/cli-e2e/<时间>/。
set -euo pipefail

repo="${0:A:h:h}"
app="${1:-$HOME/Library/Developer/Xcode/DerivedData/CherryUtility-automation/Build/Products/Debug/CherryUtility.app}"
app="${app:A}"
cli="$app/Contents/MacOS/cherry"
[[ -x "$cli" && -x "$app/Contents/MacOS/CherryUtility" ]] || { print -u2 "missing app or cherry in $app"; exit 66; }

run="$repo/build/cli-e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run"
scratch="$(mktemp -d /tmp/cherry-cli-e2e.XXXXXX)"
socket="$scratch/c.sock"
pid=""
watcher=""
failures=0

cleanup() {
  [[ -n "$watcher" ]] && kill "$watcher" 2>/dev/null || true
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT

check() { # check <名称> <期望退出码> <输出须包含的文本> -- <命令…>
  local name="$1" expected="$2" fragment="$3"
  shift 4
  local output code=0
  output="$("$@" 2>&1)" || code=$?
  print -r -- "$ $*"$'\n'"$output"$'\n'"(exit $code)"$'\n' >> "$run/transcript.txt"
  if [[ "$code" == "$expected" && "$output" == *"$fragment"* ]]; then
    print "PASS  $name"
  else
    print "FAIL  $name（退出码 $code，期望 $expected；输出：$output）"
    failures=$((failures + 1))
  fi
}

print "App: $app"
print "记录: $run"
open -n -g -j --env CHERRY_SIMULATION=pixiu75 --env CHERRY_CONTROL_SOCKET="$socket" \
  --env CHERRY_PRESET_DIR="$scratch/presets" "$app" --args --background
for _ in {1..150}; do
  [[ -S "$socket" ]] && break
  sleep 0.1
done
[[ -S "$socket" ]] || { print -u2 "App 15 秒内没有创建 socket"; exit 1; }
pid="$(pgrep -n -f "$app/Contents/MacOS/CherryUtility" || true)"
export CHERRY_CONTROL_SOCKET="$socket"

check "版本" 0 "CHERRY Utility" -- "$cli" version
check "键盘列表" 0 "046A:01E2@03100000" -- "$cli" keyboards
check "状态" 0 "* 配置 2：波纹" -- "$cli" status
check "电量" 0 "95%（充电中）" -- "$cli" battery

"$cli" watch --json > "$run/watch.ndjson" 2> "$run/watch.stderr" &
watcher=$!
for _ in {1..50}; do
  grep -q "开始监听" "$run/watch.stderr" 2>/dev/null && break
  sleep 0.1
done

check "切换配置档" 0 "已切换到配置 1（放射" -- "$cli" profile 1
check "设置灯效与亮度" 0 "已更新配置 1：灯效 呼吸，亮度 中" -- "$cli" set --effect 呼吸 --brightness 中
check "设置颜色" 0 "颜色 #00D70F" -- "$cli" set --profile 3 --color '#00D70F'
check "状态 JSON" 0 '"activeProfile" : 1' -- "$cli" status --json
check "用法错误" 2 "Error" -- "$cli" set --brightness 9
check "型号没有的灯效" 4 "没有「彩虹雨」灯效" -- "$cli" set --effect 彩虹雨
check "配置档越界" 4 "没有配置 4" -- "$cli" profile 4
check "预设不存在" 4 "没有名为「办公」的预设" -- "$cli" preset apply 办公
check "App 未运行" 3 "没有运行" -- env CHERRY_CONTROL_SOCKET="$scratch/none.sock" "$cli" status

sleep 0.5
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
watcher=""
events="$(grep -c '"activeProfile":1' "$run/watch.ndjson" || true)"
if (( events >= 3 )); then
  print "PASS  watch 收到 $events 个事件"
else
  print "FAIL  watch 只收到 $events 个 activeProfile=1 的事件（期望 ≥ 3）"
  failures=$((failures + 1))
fi

if (( failures )); then
  print -u2 "$failures 项失败，详见 $run/transcript.txt"
  exit 1
fi
print "全部通过"
