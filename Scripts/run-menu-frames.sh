#!/bin/zsh
# 交替运行各产品 3 次（run-menu-profile.py --recording commits|frames），每次运行后立即分析，最后汇总。
# 用法：Scripts/run-menu-frames.sh <xctestrun> <输出根目录> <commits|frames> before=<App> after=<App> [current=<App>]
# 已有 summary-frames.json 的运行会跳过，可续跑。xctrace 在停止 / 处理 ktrace 时偶发崩溃（Instruments 27.0：SIGTRAP 于
# ktrace_set_ktrace_file、SIGSEGV 于 kpdecode_cursor_next_record），runner 失败时把运行目录改名为 failed-<名>-<序号> 保留并重试，
# 同一次最多 3 次；分析失败或空间不足即停。
set -euo pipefail
REPO=${0:A:h:h}
XCTESTRUN=$1 ROOT=$2 RECORDING=$3; shift 3
typeset -A apps; typeset -a order
for arg in "$@"; do apps[${arg%%=*}]=${arg#*=}; order+=(${arg%%=*}); done
mkdir -p $ROOT
free_mib() { df -k /System/Volumes/Data | awk 'NR==2{print int($4/1024)}' }
# 录完的 ktrace 临时文件已删除，但 Xcode 的 DTServiceHub 仍打开着它们，空间要等它关闭才回收（每次 frames 约 10 GB）。
held_ktrace_mib() { lsof -nP +L1 2>/dev/null | awk '$1 ~ /^DTService/ && $NF ~ /\.ktrace$/ && !seen[$NF]++ {s+=$7} END{print int(s/1048576)}' }
for n in 1 2 3; do
  for g in $order; do
    out=$ROOT/$g-$n
    [[ -f $out/summary-frames.json ]] && { echo "skip $g-$n"; continue; }
    # 单次运行的临时占用：虚拟显示器上约 2 GB，接 144 Hz 物理显示器录 Hitches 时最多约 10 GB，之后才逐渐回收。
    # 磁盘写满时 xctrace 会保存失败，系统还会清除 Xcode DerivedData。
    for attempt in 1 2 3; do
      (( $(free_mib) > 16384 )) || { echo "STOP 可用空间不足 16 GiB（$(free_mib) MiB，其中 DTServiceHub 占着已删除的 ktrace $(held_ktrace_mib) MiB），未运行 $g-$n"; exit 2; }
      echo "run $g-$n $(date +%T) free=$(free_mib)MiB"
      python3 $REPO/Scripts/run-menu-profile.py --recording $RECORDING --app ${apps[$g]} --xctestrun $XCTESTRUN --output $out > $ROOT/$g-$n.runner.txt 2>&1 && break
      echo "FAILED runner $g-$n（第 $attempt 次）"; tail -3 $ROOT/$g-$n.runner.txt
      failed=$ROOT/failed-$g-$n-$(date +%H%M%S); rm -rf $out/Product; mv $out $failed; mv $ROOT/$g-$n.runner.txt $failed.runner.txt
      (( attempt < 3 )) || { echo "STOP $g-$n 连续 3 次失败"; exit 1; }
    done
    python3 $REPO/Scripts/analyze-menu-frames.py $out > $ROOT/$g-$n.analyze.txt 2>&1 \
      || { echo "FAILED analyze $g-$n"; tail -5 $ROOT/$g-$n.analyze.txt; exit 1; }
    # 运行目录里的 Product 是重签名副本；源产品另有保留，identity.json 记有其 SHA-256。
    rm -rf $out/Product
    # 孤立的 xctrace 会继续占用临时空间；出现就结束它。
    if pgrep -f 'xctrace record' >/dev/null; then echo "WARN 遗留的 xctrace（$g-$n 之后）"; pkill -INT -f 'xctrace record'; sleep 10; pkill -9 -f 'xctrace record' || true; fi
    echo "done $g-$n $(date +%T) free=$(free_mib)MiB"
  done
done
python3 $REPO/Scripts/summarize-menu-frames.py $ROOT > $ROOT/summarize.txt
echo "summary $ROOT/comparison-frames.json"
