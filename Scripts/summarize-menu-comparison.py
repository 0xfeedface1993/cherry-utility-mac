#!/usr/bin/env python3
"""汇总显式根目录内具名运行；指标缺少有效数据时保留未验证。"""
import argparse, json, pathlib, re, statistics

def read(path): return json.loads(path.read_text())

def memory(directory):
    assert read(directory/'status.json')['status']=='completed'
    actions=read(directory/'actions.json');assert actions['verified'] and len(actions['actions'])==20
    values=[int(s['rss_cpu'].split()[0])/1024 for s in read(directory/'memory.json') if actions['start_epoch']<=s['epoch']<=actions['end_epoch']]
    assert len(values)>=24
    start=statistics.median(values[:12]);end=statistics.median(values[-12:])
    return {'duration_s':actions['end_epoch']-actions['start_epoch'],'rounds':20,'start_rss_mib':start,'end_rss_mib':end,
            'rss_growth_mib':end-start,'peak_rss_mib':max(values),'note':'首尾各约 3 秒 RSS 中位数；已经预热面板，RSS 不是 footprint 或堆存活量'}

def leak_report(directory):
    path=directory/'leaks.txt'
    if not path.exists():return {'valid':False}
    text=path.read_text();match=re.search(r'Process (\d+): (\d+) leaks for (\d+) total leaked bytes',text)
    if not match:return {'valid':False,'reason':'未返回有效 leaks 摘要'}
    identity=read(directory/'identity.json');assert int(match[1])==identity['pid']
    roots=re.findall(r'^ {6}\d+ \([^\n]+\) ROOT CYCLE: <([^ >]+)',text,re.M)
    footprint=re.search(r'Physical footprint:\s+([^\n]+)',text)
    peak=re.search(r'Physical footprint \(peak\):\s+([^\n]+)',text)
    return {'valid':True,'blocks':int(match[2]),'bytes':int(match[3]),'root_cycle_types':{kind:roots.count(kind) for kind in set(roots)},
            'physical_footprint_display':footprint[1].strip() if footprint else None,
            'peak_physical_footprint_display':peak[1].strip() if peak else None,
            'note':'单次 live-process 扫描；未启用分配栈，不能确认 ROOT CYCLE 的分配来源'}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('root',type=pathlib.Path);args=parser.parse_args();root=args.root.resolve()
    before=[read(root/f'before-{n}/summary.json') for n in range(1,4)]
    after=[read(root/f'after-{n}/summary.json') for n in range(1,4)]
    identities=[read(root/f'{prefix}-{n}/identity.json') for prefix in ['before','after'] for n in range(1,4)]
    for group in [identities[:3],identities[3:]]:
        assert len({i['binary_sha256'] for i in group})==1 and len({i['template'] for i in group})==1
    assert len({i['scenario'] for i in identities})==1 and len({i['template'] for i in identities})==1
    result={'scope':'Release / profile / 模拟 pixiu75 / 固定真实 App UI；三次中位数','metrics':{},'ui_hitch':'未验证：frame / update 表为空'}
    for key in ['cpu_weight_s','main_cpu_weight_s','peak_rss_mib']:
        a=statistics.median(s[key] for s in before);b=statistics.median(s[key] for s in after)
        result['metrics'][key]={'before':a,'after':b,'change_percent':100*(b/a-1)}
    result['ui_markers_inclusive_s']={}
    for key in before[0]['ui_markers_inclusive_s']:
        a=statistics.median(s['ui_markers_inclusive_s'][key] for s in before);b=statistics.median(s['ui_markers_inclusive_s'][key] for s in after)
        result['ui_markers_inclusive_s'][key]={'before':a,'after':b,'change_percent':100*(b/a-1)}
    result['full_snapshot_counts']={'before':[s['operation_counts_near_warm_window'].get('snapshot',0) for s in before],
                                    'after':[s['operation_counts_near_warm_window'].get('snapshot',0) for s in after]}
    result['main_runloop_non_wait_max_ms']={'before':[s['main_runloop_non_wait']['max_ms'] for s in before],
                                           'after':[s['main_runloop_non_wait']['max_ms'] for s in after]}
    result['warm_hangs_over250ms']={'before':[len(s['hang_rows']) if s['hang_capture_valid'] else None for s in before],
                                   'after':[len(s['hang_rows']) if s['hang_capture_valid'] else None for s in after]}
    result['memory']={version:memory(root/f'memory-{version}') for version in ['baseline','after']}
    result['idle']={version:read(root/f'idle-{version}/summary.json') for version in ['baseline','after']}
    result['leaks']={version:leak_report(root/f'idle-{version}') for version in ['baseline','after']}
    result['gates']={'cpu_reduction_at_least25percent':result['metrics']['cpu_weight_s']['change_percent']<=-25,
                     'snapshot_refresh_eliminated':all(x==0 for x in result['full_snapshot_counts']['after']),
                     'warm_peak_rss_increase_at_most10percent':result['metrics']['peak_rss_mib']['change_percent']<=10,
                     'stress_peak_rss_increase_at_most10percent':result['memory']['after']['peak_rss_mib']<=1.1*result['memory']['baseline']['peak_rss_mib'],
                     'stress_rss_growth_at_most5mib':result['memory']['after']['rss_growth_mib']<=5,
                     'idle_single_core_at_most1percent':result['idle']['after']['single_core_percent']<=1,
                     'hitch_reduction_at_least50percent':None,'hitch_max_at_most50ms':None}
    (root/'comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
