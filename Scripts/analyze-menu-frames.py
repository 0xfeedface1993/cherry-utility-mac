#!/usr/bin/env python3
"""只分析命令指定的一次 `run-menu-profile.py --recording commits|frames` 录制；不索引其它 artifact。

屏幕帧 hitch 来自 Hitches / Display（需要物理显示器的 swap / vsync 事件）；没有这些事件时如实记为无效，
不把 0 行解释为不卡顿。主线程 Core Animation 提交、run loop 忙碌与潜在卡顿不依赖显示器，作为提交阶段的代理指标。
"""
import argparse, datetime, importlib.util, json, pathlib, re, xml.etree.ElementTree as E

# 复用固定场景分析的导出、统计与 run loop 计算，口径与 summary.json 一致。
spec = importlib.util.spec_from_file_location('analyze_menu_profile', pathlib.Path(__file__).resolve().parent / 'analyze-menu-profile.py')
profile = importlib.util.module_from_spec(spec); spec.loader.exec_module(profile)

def pid_of(element, resolve):
    pid = element.find('.//pid')
    return int(resolve(pid).text) if pid is not None else None

def refresh_hz(identity):
    for display in identity.get('displays') or []:
        match = re.search(r'@ ([0-9.]+)Hz', display.get('resolution') or '')
        if display.get('main') and match: return float(match.group(1))
    return 60.0

def over(values, ns): return sum(v > ns for v in values)

def analyze(directory):
    assert json.loads((directory/'status.json').read_text())['status'] == 'completed'
    identity = json.loads((directory/'identity.json').read_text()); actions = json.loads((directory/'actions.json').read_text())
    recording = identity.get('recording')
    assert recording in ('commits', 'frames'), '只分析 --recording commits / frames 的录制'
    assert actions['verified'] and len(actions['actions']) == 24
    if not (directory/'toc.xml').exists():
        profile.subprocess.run(['xcrun','xctrace','export','--input',str(directory/'ui.trace'),'--toc','--output',str(directory/'toc.xml')],check=True,capture_output=True)
    toc = E.parse(directory/'toc.xml').getroot()
    start = datetime.datetime.fromisoformat(toc.findtext('.//summary/start-date')).timestamp()
    a = int((actions['start_epoch']-start)*1e9); b = int((actions['warm_end_epoch']-start)*1e9)
    assert 0 <= a < b
    pid = identity['pid']; hz = refresh_hz(identity); frame = 1e9/hz

    commits = []; main_commits = []; severities = {}
    rows, resolve = profile.table(directory, 'coreanimation-commit-interval')
    for row in rows:
        c = [resolve(x) for x in row]
        t = int(c[0].text)
        if not a <= t < b or pid_of(c[3], resolve) != pid: continue
        duration = int(c[1].text); commits.append(duration)
        if c[3].get('fmt', '').startswith('Main Thread'):
            main_commits.append(duration); severities[c[6].text] = severities.get(c[6].text, 0) + 1
    assert commits, 'Core Animation Commits 表没有目标进程的热窗口提交'

    rows, resolve = profile.table(directory, 'runloop-events')
    busy = profile.runloop_busy_values(rows, resolve, a, b)
    assert busy, 'runloop-events 没有热窗口的主 run loop 迭代'

    hangs = []
    rows, resolve = profile.table(directory, 'potential-hangs')
    for row in rows:
        c = [resolve(x) for x in row]
        if a <= int(c[0].text) < b and pid_of(c[3], resolve) == pid:
            hangs.append({'duration_ms': int(c[1].text)/1e6, 'type': c[2].get('fmt')})

    vsyncs = swaps = frame_rows = hitch_rows = []; hitches = []; causes = {}; renders = []
    if recording == 'frames':
        vsyncs, _ = profile.table(directory, 'display-vsyncs-interval')
        swaps, _ = profile.table(directory, 'display-surface-swap')
        frame_rows, _ = profile.table(directory, 'hitches-frame-lifetimes')
        hitch_rows, resolve = profile.table(directory, 'hitches')
        for row in hitch_rows:
            c = [resolve(x) for x in row]
            if a <= int(c[0].text) < b and pid_of(c[2], resolve) == pid and c[3].text == '0':
                hitches.append(int(c[1].text))
                # Instruments 的「Potential Issue」：渲染服务器合成慢（render）、App 提交慢（app update）、二者兼有或未归因。
                text = c[7].text or ''
                cause = '+'.join(k for k, m in (('app', 'app update'), ('render', 'expensive render'), ('gpu', 'GPU work')) if m in text) or 'none'
                causes[cause] = causes.get(cause, 0) + 1
        # 渲染服务器每帧合成耗时（全屏，不分进程）：与 App 的帧是否 hitch 无关，看合成本身变贵没有。
        rows, resolve = profile.table(directory, 'hitches-renders')
        for row in rows:
            c = [resolve(x) for x in row]
            if a <= int(c[0].text) < b: renders.append(int(c[1].text))
    hitch_valid = bool(vsyncs and swaps and frame_rows)
    virtual = [d for d in identity.get('displays') or [] if d.get('product_ascii') == 'virt' or d.get('vendor_ascii') == 'unkn']
    parts = ['未录制 Hitches / Display（commits 配置）'] if recording == 'commits' else []
    if virtual: parts.append('只有虚拟显示器，没有物理显示器的 swap / vsync 事件')
    elif recording == 'frames': parts.append('显示 swap / vsync 或帧生命周期表为空')
    reason = None if hitch_valid else '；'.join(parts)

    records = []
    for path in sorted((directory/'journal').glob('*.ndjson')):
        records += [json.loads(line) for line in path.read_text().splitlines() if line]
    assert records, '没有本次日志'
    pending = set(); unmatched = 0
    for record in records:
        e = record['event']; key = e['context']['span_id']
        if e['phase'] == 'began': pending.add(key)
        elif e['phase'] == 'finished':
            if key in pending: pending.discard(key)
            else: unmatched += 1
    assert not pending and not unmatched, 'span 未闭合'

    result = {'status': 'validated', 'pid': pid, 'recording': identity['template'], 'warm_duration_s': (b-a)/1e9,
              'refresh_hz': hz, 'frame_budget_ms': frame/1e6, 'displays': identity.get('displays'),
              'screen_hitch_capture_valid': hitch_valid, 'screen_hitch_invalid_reason': reason,
              'vsync_rows': len(vsyncs), 'swap_rows': len(swaps), 'frame_rows': len(frame_rows),
              'screen_hitches': profile.stats(hitches) if hitch_valid else None,
              'screen_hitches_over50ms': over(hitches, 50e6) if hitch_valid else None,
              'screen_hitch_causes': causes if hitch_valid else None,
              'render_server_frames': profile.stats(renders) if hitch_valid and renders else None,
              'render_server_frames_over_budget': over(renders, frame) if hitch_valid and renders else None,
              'commits_all_threads': len(commits),
              'main_commits': profile.stats(main_commits), 'main_commit_severity': severities,
              'main_commits_over_frame': over(main_commits, frame), 'main_commits_over_2_frames': over(main_commits, 2*frame),
              'main_commits_over50ms': over(main_commits, 50e6),
              'main_runloop_non_wait': profile.stats(busy), 'main_runloop_over_frame': over(busy, frame),
              'main_runloop_over50ms': over(busy, 50e6),
              'potential_hangs': hangs, 'hangs_ge250ms': sum(h['duration_ms'] >= 250 for h in hangs),
              'journal_records': len(records)}
    (directory/'summary-frames.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k not in ('displays', 'potential_hangs')}, ensure_ascii=False))

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('directory', type=pathlib.Path); args = p.parse_args(); analyze(args.directory.resolve())
