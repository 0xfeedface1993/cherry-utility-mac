#!/usr/bin/env python3
"""独立 Release App 闲置采样。只终止本脚本启动的 PID；CPU 为单核累计时间差。"""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, shutil, signal, subprocess, tempfile, time

def seconds(value):
    parts=value.strip().split(':'); return sum(float(part)*60**index for index,part in enumerate(reversed(parts)))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--app',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True);parser.add_argument('--seconds',type=int,default=300)
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='cherry-idle-',dir='/tmp') as temp:
        app=pathlib.Path(temp)/'CherryUtility.app';shutil.copytree(args.app.resolve(),app,symlinks=True)
        info=app/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());data['CFBundleIdentifier']='dev.local.cherry.utility.idleprofile';info.write_bytes(plistlib.dumps(data))
        subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True,capture_output=True)
        binary=app/'Contents/MacOS/CherryUtility'
        env=os.environ.copy();env.update(CHERRY_SIMULATION='pixiu75',CHERRY_DIAGNOSTIC_MODE='profile',CHERRY_DIAGNOSTIC_DIR=str(out/'journal'),CHERRY_PRESET_DIR=str(pathlib.Path(temp)/'presets'))
        identity={'source_app':str(args.app.resolve()),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'uuid':subprocess.check_output(['dwarfdump','--uuid',str(binary)],text=True),'scenario':'idle-visible-info-300-v1','warmup_seconds':30}
        samples=[]
        with (out/'process.txt').open('w') as log:
            process=subprocess.Popen([str(binary)],env=env,stdout=log,stderr=subprocess.STDOUT)
            identity['pid']=process.pid;(out/'identity.json').write_text(json.dumps(identity,indent=2))
            try:
                started=time.monotonic();deadline=started+30+args.seconds
                while time.monotonic()<deadline:
                    if process.poll() is not None: raise RuntimeError('App 提前退出')
                    raw=subprocess.check_output(['ps','-p',str(process.pid),'-o','rss=','-o','time='],text=True).split()
                    samples.append({'epoch':time.time(),'elapsed_s':time.monotonic()-started,'rss_kib':int(raw[0]),'cpu_s':seconds(raw[1])})
                    time.sleep(1)
                measured=[s for s in samples if s['elapsed_s']>=30]
                a,b=measured[0],measured[-1];cpu=b['cpu_s']-a['cpu_s'];duration=b['elapsed_s']-a['elapsed_s']
                result={'status':'completed','duration_s':duration,'cpu_s':cpu,'single_core_percent':100*cpu/duration,
                        'peak_rss_mib':max(s['rss_kib'] for s in measured)/1024,'rss_growth_mib':(b['rss_kib']-a['rss_kib'])/1024}
                (out/'summary.json').write_text(json.dumps(result,indent=2))
                with (out/'leaks.txt').open('w') as leak_log:
                    try:
                        leak=subprocess.run(['leaks','--noContent',str(process.pid)],stdout=leak_log,stderr=subprocess.STDOUT,timeout=45)
                        result['leaks_exit_code']=leak.returncode
                    except subprocess.TimeoutExpired: result['leaks_exit_code']='timeout'
                (out/'summary.json').write_text(json.dumps(result,indent=2))
            finally:
                (out/'samples.json').write_text(json.dumps(samples,indent=2))
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: process.kill();process.wait()
    print(out,flush=True)

if __name__=='__main__':main()
