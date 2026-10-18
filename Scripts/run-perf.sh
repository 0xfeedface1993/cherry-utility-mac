#!/bin/zsh
# 在看门狗下运行 Scripts/run-perf.py（只用模拟键盘）：先编译 perf-rusage，再按场景采集。
#
#   Scripts/run-perf.sh <CherryUtility.app> <输出目录> [run-perf.py 的其他参数…]
#
# 看门狗（e2e-lib.sh）发现非模拟模式的 CherryUtility、可能直连真键盘的 cherry 或默认 socket 时立即结束并中止。
set -u
repo="${0:A:h:h}"
cd "$repo"
(( $# >= 2 )) || { sed -n '2,6p' "$0"; exit 64; }
app="${1:A}"; output="${2:A}"; shift 2
source Scripts/e2e-lib.sh
e2e_init "$output.watchdog" "$app"
trap e2e_cleanup EXIT
rusage="$E2E_SCRATCH/perf-rusage"
swiftc -O Scripts/perf-rusage.swift -o "$rusage" || exit 1
python3 Scripts/run-perf.py --app "$app" --output "$output" --rusage "$rusage" "$@"
code=$?
if e2e_aborted; then
  print -u2 "看门狗中止了运行：$(cat "$output.watchdog/watchdog.log")"
  exit 99
fi
exit $code
