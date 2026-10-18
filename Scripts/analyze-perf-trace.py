#!/usr/bin/env python3
"""汇总一份 Time Profiler trace 里某个进程的 CPU 热点（Scripts/run-perf.py --trace 录制的）。

  Scripts/analyze-perf-trace.py <x.trace> [--pid N] [--top 25] [--exclude 帧名片段]... [--json out.json]

只读给定的 trace；导出的 XML 放在 trace 旁边（<x>.time-profile.xml），再次分析时复用。
输出总采样权重、按二进制（模块）的自身权重、自身热点和包含子调用的热点（同一栈里重复出现的帧只计一次）。
--exclude 把栈里含这些帧的采样单独计入 excluded_ms 并从其余统计中剔除（例如 SimulatedKeyboardHub：模拟键盘自身的
开销不属于产品，比较前后版本时只看剩下的部分）。
"""
import argparse, collections, json, pathlib, subprocess, xml.etree.ElementTree as E


def export(trace):
    path = trace.with_suffix(".time-profile.xml")
    if not path.exists():
        subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', "--output", str(path)],
                       check=True, capture_output=True)
    return path


def analyze(trace, pid, top, exclude=()):
    root = E.parse(export(trace)).getroot()
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}
    resolve = lambda e: ids.get(e.get("ref"), e) if e is not None else None
    total = excluded = 0
    threads = collections.Counter()
    selfs, inclusive, modules = collections.Counter(), collections.Counter(), collections.Counter()
    for row in root.iter("row"):
        cells = {resolve(c).tag: resolve(c) for c in row}
        process = cells.get("process")
        if pid is not None:
            p = resolve(process.find("pid")) if process is not None else None
            if p is None or int(p.text) != pid:
                continue
        weight = int(cells["weight"].text) if "weight" in cells else 1
        stack = cells.get("tagged-backtrace")
        if stack is None:
            stack = cells.get("backtrace")
        # 帧直接挂在 tagged-backtrace 下；旧格式里还有一层 backtrace。
        inner = stack.find("backtrace") if stack is not None else None
        frames = [resolve(f) for f in (inner if inner is not None else stack).findall("frame")] if stack is not None else []
        names = [f.get("name") or f.get("addr", "?") for f in frames]
        if exclude and any(part in name for name in names for part in exclude):
            excluded += weight
            continue
        total += weight
        thread = cells.get("thread")
        threads[thread.get("fmt", "?") if thread is not None else "?"] += weight
        if stack is None:
            selfs["<no stack>"] += weight
            continue
        if not names:
            selfs["<no frames>"] += weight
            continue
        selfs[names[0]] += weight
        binary = resolve(frames[0].find("binary"))
        modules[binary.get("name") if binary is not None else "?"] += weight
        for name in set(names):
            inclusive[name] += weight
    ms = lambda v: round(v / 1e6, 2)
    return {
        "trace": str(trace), "pid": pid, "total_ms": ms(total), "excluded_ms": ms(excluded), "excluded": list(exclude),
        "main_thread_ms": ms(sum(v for k, v in threads.items() if k.startswith("Main Thread"))),
        "threads_ms": {k: ms(v) for k, v in threads.most_common(8)},
        "modules_self_ms": {k: ms(v) for k, v in modules.most_common(12)},
        "self_ms": {k: ms(v) for k, v in selfs.most_common(top)},
        "inclusive_ms": {k: ms(v) for k, v in inclusive.most_common(top)},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=pathlib.Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--json", type=pathlib.Path)
    args = parser.parse_args()
    result = analyze(args.trace.resolve(), args.pid, args.top, tuple(args.exclude))
    if args.json:
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
