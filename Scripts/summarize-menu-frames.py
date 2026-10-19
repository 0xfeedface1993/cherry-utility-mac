#!/usr/bin/env python3
"""汇总显式根目录内 before-1..3 / after-1..3（以及可选 current-1..3）的 summary-frames.json。

屏幕帧 hitch 只有在每次运行都采到 swap / vsync 时才判定；否则 gate 为 null 并写明原因。
提交阶段的代理 gate 单独列出，不能当作屏幕帧 hitch 的通过。
"""
import argparse, json, pathlib, statistics

def read(path): return json.loads(path.read_text())

def group(root, prefix):
    runs = sorted(root.glob(f'{prefix}-[0-9]'))
    if not runs: return None
    summaries = [read(run/'summary-frames.json') for run in runs]
    identities = [read(run/'identity.json') for run in runs]
    assert len({i['binary_sha256'] for i in identities}) == 1 and len({i['template'] for i in identities}) == 1, prefix + ' 不是同一产品或配置'
    return {'runs': [run.name for run in runs], 'binary_sha256': identities[0]['binary_sha256'], 'source_app': identities[0]['source_app'], 'summaries': summaries}

def values(g, key): return [s[key] for s in g['summaries']]
def nested(g, key, field): return [s[key][field] for s in g['summaries']]

def describe(g):
    return {'runs': g['runs'], 'source_app': g['source_app'],
            'screen_hitch_capture_valid': values(g, 'screen_hitch_capture_valid'),
            'screen_hitch_count': [s['screen_hitches']['count'] if s['screen_hitches'] else None for s in g['summaries']],
            'screen_hitch_causes': [s.get('screen_hitch_causes') for s in g['summaries']],
            'screen_hitch_p95_ms': [s['screen_hitches'].get('p95_ms') if s['screen_hitches'] else None for s in g['summaries']],
            'screen_hitches_over50ms': values(g, 'screen_hitches_over50ms'),
            'screen_hitch_max_ms': [s['screen_hitches']['max_ms'] if s['screen_hitches'] else None for s in g['summaries']],
            'render_server_frame_p50_ms': [(s.get('render_server_frames') or {}).get('p50_ms') for s in g['summaries']],
            'render_server_frame_p95_ms': [(s.get('render_server_frames') or {}).get('p95_ms') for s in g['summaries']],
            'render_server_frames_over_budget': [s.get('render_server_frames_over_budget') for s in g['summaries']],
            'main_commits': nested(g, 'main_commits', 'count'),
            'main_commit_p95_ms': nested(g, 'main_commits', 'p95_ms'), 'main_commit_max_ms': nested(g, 'main_commits', 'max_ms'),
            'main_commits_over_frame': values(g, 'main_commits_over_frame'), 'main_commits_over50ms': values(g, 'main_commits_over50ms'),
            'main_runloop_max_ms': nested(g, 'main_runloop_non_wait', 'max_ms'),
            'main_runloop_over_frame': values(g, 'main_runloop_over_frame'), 'main_runloop_over50ms': values(g, 'main_runloop_over50ms'),
            'hangs_ge250ms': values(g, 'hangs_ge250ms'), 'warm_duration_s': values(g, 'warm_duration_s')}

def reduction(before, after):
    # 基线中位数为 0 时降低比例没有意义，记为 null。
    a = statistics.median(before); b = statistics.median(after)
    return {'before_median': a, 'after_median': b, 'change_percent': None if a == 0 else 100*(b/a-1)}

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('root', type=pathlib.Path); args = parser.parse_args(); root = args.root.resolve()
    groups = {name: group(root, name) for name in ['before', 'after', 'current']}
    before, after = groups['before'], groups['after']
    assert before and after and len(before['runs']) == len(after['runs']) == 3, '需要 before-1..3 与 after-1..3'
    result = {'scope': 'Release / profile / 模拟 pixiu75 / 固定真实 App UI（20 次灯效 + 4 次配置切换）；每组三次',
              'groups': {name: describe(g) for name, g in groups.items() if g}}
    valid = all(all(values(g, 'screen_hitch_capture_valid')) for g in (before, after))
    reasons = sorted({s['screen_hitch_invalid_reason'] for g in groups.values() if g for s in g['summaries'] if s['screen_hitch_invalid_reason']})
    over50 = reduction(values(before, 'screen_hitches_over50ms'), values(after, 'screen_hitches_over50ms')) if valid else None
    result['screen_hitch'] = {'valid': valid, 'invalid_reasons': reasons, 'over50ms': over50,
                              'count': reduction([s['screen_hitches']['count'] for s in before['summaries']],
                                                 [s['screen_hitches']['count'] for s in after['summaries']]) if valid else None}
    commit50 = reduction(values(before, 'main_commits_over50ms'), values(after, 'main_commits_over50ms'))
    commit_frame = reduction(values(before, 'main_commits_over_frame'), values(after, 'main_commits_over_frame'))
    result['commit_proxy'] = {'over50ms': commit50, 'over_frame': commit_frame,
                              'max_ms': {'before': nested(before, 'main_commits', 'max_ms'), 'after': nested(after, 'main_commits', 'max_ms')}}
    result['gates'] = {
        'hitch_reduction_at_least50percent': (None if over50['change_percent'] is None else over50['change_percent'] <= -50) if valid else None,
        'hitch_max_at_most50ms': all(s['screen_hitches']['max_ms'] <= 50 for s in after['summaries']) if valid else None,
        'warm_hangs_ge250ms_zero': all(v == 0 for v in values(after, 'hangs_ge250ms')),
        'proxy_commit_over50ms_reduction_at_least50percent': None if commit50['change_percent'] is None else commit50['change_percent'] <= -50,
        'proxy_commit_max_at_most50ms': all(v <= 50 for v in nested(after, 'main_commits', 'max_ms')),
    }
    if groups['current']:
        current = groups['current']
        result['gates']['current_warm_hangs_ge250ms_zero'] = all(v == 0 for v in values(current, 'hangs_ge250ms'))
        result['gates']['current_proxy_commit_max_at_most50ms'] = all(v <= 50 for v in nested(current, 'main_commits', 'max_ms'))
        result['gates']['current_hitch_max_at_most50ms'] = (all(s['screen_hitches']['max_ms'] <= 50 for s in current['summaries'])
                                                           if all(values(current, 'screen_hitch_capture_valid')) else None)
    (root/'comparison-frames.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
