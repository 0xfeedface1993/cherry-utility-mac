#!/usr/bin/env python3
"""只分析命令指定的一次完整菜单录制；不索引其它 artifact。"""
import argparse, bisect, collections, datetime, json, math, pathlib, statistics, subprocess, xml.etree.ElementTree as E

def stats(values):
    v=sorted(values)
    return {'count':len(v),'p50_ms':statistics.median(v)/1e6,'p95_ms':v[math.ceil(.95*len(v))-1]/1e6,'max_ms':v[-1]/1e6} if v else {'count':0,'max_ms':0}

def table(directory,name):
    path=directory/(name+'.xml')
    if not path.exists():
        subprocess.run(['xcrun','xctrace','export','--input',str(directory/'ui.trace'),'--xpath',f'/trace-toc/run[@number="1"]/data/table[@schema="{name}"]','--output',str(path)],check=True,capture_output=True)
    root=E.parse(path).getroot();ids={e.get('id'):e for e in root.iter() if e.get('id')}
    return root.findall('.//row'),lambda e:ids.get(e.get('ref'),e)

def runloop_busy(rows,resolve,a,b):
    return stats(runloop_busy_values(rows,resolve,a,b))

def runloop_busy_values(rows,resolve,a,b):
    opens={};iterations=[];waits=[]
    for row in rows:
        c=[resolve(x) for x in row]
        if len(c)<9 or c[7].text!='1':continue
        t=int(c[0].text);kind=c[2].get('fmt');phase=c[3].get('fmt');key=(kind,c[4].get('fmt'),c[8].get('fmt'))
        if phase=='START':opens[key]=t
        elif phase=='END':
            begin=opens.pop(key,None)
            if begin is not None:
                if kind=='waiting_for_events':waits.append((begin,t))
                if kind=='individual_iteration':iterations.append((begin,t))
    merged=[]
    for x,y in sorted(waits):
        if merged and x<=merged[-1][1]:merged[-1]=(merged[-1][0],max(y,merged[-1][1]))
        else:merged.append((x,y))
    ends=[y for x,y in merged];values=[]
    for x,y in iterations:
        x=max(a,x);y=min(b,y)
        if x>=y:continue
        waiting=0;i=bisect.bisect_right(ends,x)
        while i<len(merged) and merged[i][0]<y:
            u,v=merged[i];waiting+=max(0,min(y,v)-max(x,u));i+=1
        values.append(max(0,y-x-waiting))
    return values

def analyze(directory):
    assert json.loads((directory/'status.json').read_text())['status']=='completed'
    if not (directory/'toc.xml').exists():
        subprocess.run(['xcrun','xctrace','export','--input',str(directory/'ui.trace'),'--toc','--output',str(directory/'toc.xml')],check=True,capture_output=True)
    toc=E.parse(directory/'toc.xml').getroot()
    identity=json.loads((directory/'identity.json').read_text());actions=json.loads((directory/'actions.json').read_text())
    assert actions['verified'] and len(actions['actions'])==24
    start=datetime.datetime.fromisoformat(toc.findtext('.//summary/start-date')).timestamp()
    a=int((actions['start_epoch']-start)*1e9);b=int((actions['warm_end_epoch']-start)*1e9)
    assert 0<=a<b
    total=main=nostack=0;inclusive=collections.Counter();selfs=collections.Counter();ui=collections.Counter();markers=['CA::Transaction::commit()', 'layoutIfNeeded', 'GraphHost.flushTransactions()', 'MenuBarExtraLayout.sizeThatFits'];rows,resolve=table(directory,'time-profile')
    for row in rows:
        c=[resolve(x) for x in row]
        if not a<=int(c[0].text)<b:continue
        pid=resolve(c[2].find('pid'))
        if int(pid.text)!=identity['pid']:continue
        weight=int(c[5].text);total+=weight
        if 'Main Thread' in c[1].get('fmt',''):main+=weight
        if c[6].tag=='sentinel':nostack+=weight;continue
        frames=[resolve(f) for f in c[6].findall('frame')];names=[f.get('name','') for f in frames]
        for name in set(names):inclusive[name]+=weight
        if 'Main Thread' in c[1].get('fmt',''):
            for marker in markers:
                if any(marker in name for name in names):ui[marker]+=weight
        if names:selfs[names[0]]+=weight
    assert total>0,'CPU 表没有目标进程的热交互样本'
    hs=[];rows,resolve=table(directory,'hitches')
    for row in rows:
        c=[resolve(x) for x in row];t=int(c[0].text)
        if a<=t<b and int(resolve(c[2].find('pid')).text)==identity['pid'] and c[3].text=='0':hs.append(int(c[1].text))
    frame_rows,_=table(directory,'hitches-frame-lifetimes')
    update_rows,_=table(directory,'hitches-updates')
    runloop_rows,runloop_resolve=table(directory,'runloop-events')
    frame_valid=bool(frame_rows and update_rows)
    hang_valid=bool(runloop_rows)
    rows,resolve=table(directory,'potential-hangs');hangs=[]
    for row in rows:
        c=[resolve(x) for x in row]
        if a<=int(c[0].text)<b:hangs.append([{'tag':x.tag,'text':x.text,'fmt':x.get('fmt')} for x in c])
    records=[]
    for path in sorted((directory/'journal').glob('*.ndjson')):
        records += [json.loads(line) for line in path.read_text().splitlines() if line]
    assert records,'没有本次日志'
    pending={};unmatched=[];counts=collections.Counter();root_counts=collections.Counter()
    # wall_time_utc 只有整秒；窗口边缘 ±1 秒的误差不适合精确定位单个操作。
    for record in records:
        e=record['event'];key=e['context']['span_id'];phase=e['phase']
        if phase=='began':pending[key]=e
        elif phase=='finished':
            if key not in pending:unmatched.append(key)
            else:pending.pop(key)
        epoch=datetime.datetime.fromisoformat(record['wall_time_utc'].replace('Z','+00:00')).timestamp()
        if actions['start_epoch']-1<=epoch<=actions['warm_end_epoch']+1 and phase=='began':
            counts[e['operation']]+=1
            if e['operation']=='refresh':root_counts[e['context']['origin']]+=1
    rss=[]
    for s in json.loads((directory/'memory.json').read_text()):
        if actions['start_epoch']<=s['epoch']<=actions['warm_end_epoch']:
            rss.append(int(s['rss_cpu'].split()[0])/1024)
    result={'status':'validated','pid':identity['pid'],'template':identity['template'],'warm_duration_s':(b-a)/1e9,
            'window_start_ns':a,'window_end_ns':b,'cpu_weight_s':total/1e9,'main_cpu_weight_s':main/1e9,'no_stack_weight_s':nostack/1e9,
            'hitch_capture_valid':frame_valid,'frame_rows':len(frame_rows),'update_rows':len(update_rows),
            'hitches':stats(hs) if frame_valid else None,'over50ms':sum(x>50e6 for x in hs) if frame_valid else None,
            'main_runloop_non_wait':runloop_busy(runloop_rows,runloop_resolve,a,b),
            'ui_markers_inclusive_s':{k:v/1e9 for k,v in ui.items()},
            'hang_capture_valid':hang_valid,'runloop_rows':len(runloop_rows),'hang_rows':hangs if hang_valid else None,'peak_rss_mib':max(rss) if rss else None,
            'operation_counts_near_warm_window':dict(counts),'refresh_by_origin_near_warm_window':dict(root_counts),
            'journal_incomplete_spans':len(pending),'journal_unmatched_finishes':len(unmatched),
            'inclusive_hotspots_s':{k:v/1e9 for k,v in inclusive.most_common(20)},'self_hotspots_s':{k:v/1e9 for k,v in selfs.most_common(15)}}
    assert not pending and not unmatched,'span 未闭合'
    (directory/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in result.items() if 'hotspot' not in k},ensure_ascii=False))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);args=p.parse_args();analyze(args.directory.resolve())
