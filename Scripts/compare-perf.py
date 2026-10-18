#!/usr/bin/env python3
"""对比两次 Scripts/run-perf.py 的结果，输出 Markdown 表。

  Scripts/compare-perf.py <基线目录> <优化后目录>
"""
import json, pathlib, sys

METRICS = [
    ("idle-background", ["app", "cpu_percent"], "后台常驻 · 平均 CPU（%）"),
    ("idle-background", ["app", "interrupt_wakeups_per_s"], "后台常驻 · 中断唤醒（次/秒）"),
    ("idle-background", ["app", "footprint_end_mib"], "后台常驻 · 内存占用（MiB）"),
    ("idle-window", ["app", "cpu_percent"], "开着主窗口 · 平均 CPU（%）"),
    ("idle-window", ["app", "interrupt_wakeups_per_s"], "开着主窗口 · 中断唤醒（次/秒）"),
    ("idle-window", ["app", "footprint_end_mib"], "开着主窗口 · 内存占用（MiB）"),
    ("idle-window", ["app", "lifetime_peak_mib"], "开着主窗口 · 启动以来峰值（MiB）"),
    ("automation", ["app_cpu_ms_per_call"], "MCP 调用 · App CPU（ms/次）"),
    ("automation", ["mcp_cpu_ms_per_call"], "MCP 调用 · cherry mcp CPU（ms/次）"),
    ("automation", ["read_ms", "p50"], "MCP 读 · 延迟 p50（ms）"),
    ("automation", ["read_ms", "p90"], "MCP 读 · 延迟 p90（ms）"),
    ("automation", ["write_ms", "p50"], "MCP 写 · 延迟 p50（ms）"),
    ("automation", ["write_ms", "p90"], "MCP 写 · 延迟 p90（ms）"),
    ("automation", ["app_footprint_growth_mib"], "MCP 调用 · App 内存增长（MiB）"),
    ("automation", ["cli", "app_cpu_ms_per_call"], "cherry status 经由 App · App CPU（ms/次）"),
    ("automation", ["cli", "wall_ms", "p50"], "cherry status 经由 App · 耗时 p50（ms）"),
    ("cli-direct", ["wall_ms", "p50"], "cherry status 直连 · 耗时 p50（ms）"),
    ("cli-direct", ["cpu_ms", "p50"], "cherry status 直连 · CPU p50（ms）"),
    ("cli-direct", ["maxrss_mib"], "cherry status 直连 · 最大内存（MiB）"),
    ("mcp-idle", ["mcp", "cpu_percent"], "cherry mcp 空闲 · 平均 CPU（%）"),
    ("mcp-idle", ["mcp", "interrupt_wakeups_per_s"], "cherry mcp 空闲 · 中断唤醒（次/秒）"),
    ("mcp-idle", ["mcp", "idle_wakeups_per_s"], "cherry mcp 空闲 · 空闲唤醒（次/秒）"),
    ("mcp-idle", ["mcp", "footprint_end_mib"], "cherry mcp 空闲 · 内存占用（MiB）"),
]


def value(results, scenario, path):
    node = results["scenarios"].get(scenario)
    for key in path:
        if node is None:
            return None
        node = node.get(key)
    return node


def main():
    before, after = (json.loads((pathlib.Path(p) / "results.json").read_text()) for p in sys.argv[1:3])
    print("| 指标 | 基线 | 优化后 | 变化 |")
    print("|---|---:|---:|---:|")
    for scenario, path, label in METRICS:
        a, b = value(before, scenario, path), value(after, scenario, path)
        if a is None or b is None:
            continue
        change = f"{(b - a) / a * 100:+.1f}%" if a else "—"
        print(f"| {label} | {a:g} | {b:g} | {change} |")


if __name__ == "__main__":
    main()
