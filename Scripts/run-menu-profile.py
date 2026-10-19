#!/usr/bin/env python3
"""XCUITest 驱动指定 Release 产品；xctrace 按唯一 PID 附加，具名证据不复用。"""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, shutil, signal, subprocess, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
# commits / frames 都不含 Time Profiler（Instruments 27.0 中它与 Core Animation Commits 同录会报 backtrace 类型错误并损坏 run）。
# frames 另加 Hitches / Display：依赖物理显示器的 swap / vsync 事件，虚拟显示器上这些表为空，由分析脚本据此判定无效；
# 它们的 GPUPlugin 在停止录制时偶发 SIGBUS，没有物理显示器时用 commits。
RECORDINGS = {'swiftui': ['--template', 'SwiftUI'],
              'commits': ['--instrument', 'Core Animation Commits', '--instrument', 'Hangs'],
              'frames': ['--instrument', 'Core Animation Commits', '--instrument', 'Hangs', '--instrument', 'Hitches', '--instrument', 'Display']}

def displays():
    # 记录采集时的显示器；厂商 / 产品 ID 为 unkn / virt 的是虚拟显示器。
    try: data=json.loads(subprocess.check_output(['system_profiler','SPDisplaysDataType','-json'],text=True))
    except (subprocess.CalledProcessError, ValueError): return None
    found=[]
    for gpu in data.get('SPDisplaysDataType',[]):
        for d in gpu.get('spdisplays_ndrvs',[]):
            ascii=lambda h: bytes.fromhex(h).decode('ascii','replace') if h and len(h)==8 else h
            found.append({'name':d.get('_name'),'vendor_id':d.get('_spdisplays_display-vendor-id'),'product_id':d.get('_spdisplays_display-product-id'),
                          'vendor_ascii':ascii(d.get('_spdisplays_display-vendor-id')),'product_ascii':ascii(d.get('_spdisplays_display-product-id')),
                          'resolution':d.get('_spdisplays_resolution'),'pixels':d.get('_spdisplays_pixels'),'main':d.get('spdisplays_main')=='spdisplays_yes'})
    return found

def wait_file(path, process, timeout):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if process.poll() is not None: raise RuntimeError(f'UI 驱动提前结束：{process.returncode}，见 uitest.txt')
        if time.monotonic() >= deadline: raise TimeoutError(path.name)
        time.sleep(.2)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--xctestrun', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--scenario',choices=['fixed','memory'],default='fixed')
    parser.add_argument('--recording',choices=sorted(RECORDINGS),default='swiftui',help='fixed 场景的 xctrace 配置')
    args = parser.parse_args()
    final_out=args.output.resolve(); final_out.mkdir(parents=True, exist_ok=False)
    # XCTest runner 对 Downloads 写入受 TCC 限制；握手和日志写入本次专属临时目录。
    out=pathlib.Path(tempfile.mkdtemp(prefix='cherry-menu-profile-',dir='/tmp'))
    # 独立 bundle ID 防止 XCTest 对同 bundle 的其他窗口进行终止或错误绑定。
    source_app=args.app.resolve(); app=out/'Product/CherryUtility.app'
    shutil.copytree(source_app,app,symlinks=True)
    info=app/'Contents/Info.plist'; metadata=plistlib.loads(info.read_bytes())
    metadata['CFBundleIdentifier']='online.odeployer.CherryUtility.profile'
    info.write_bytes(plistlib.dumps(metadata))
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True,capture_output=True)
    binary=app/'Contents/MacOS/CherryUtility'
    identity={'source_app':str(source_app), 'app':str(app), 'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
              'uuid':subprocess.check_output(['dwarfdump','--uuid',str(binary)],text=True).strip(),
              'scenario':'menu-effects20-profiles4-v1' if args.scenario=='fixed' else 'menu-memory20-v1', 'template':(' '.join(RECORDINGS[args.recording]) if args.recording!='swiftui' else 'SwiftUI') if args.scenario=='fixed' else 'RSS (no xctrace)',
              'recording':args.recording if args.scenario=='fixed' else None,'displays':displays(),
              'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (out/'identity.json').write_text(json.dumps(identity,ensure_ascii=False,indent=2))
    env=os.environ.copy();env['TEST_RUNNER_CHERRY_PROFILE_APP']=str(app);env['TEST_RUNNER_CHERRY_PROFILE_OUTPUT']=str(out)
    ui_log=(out/'uitest.txt').open('w');trace_log=(out/'xctrace.txt').open('w')
    driver=recorder=watcher=None; memory=[]; status='failed'
    try:
        auth=pathlib.Path.home()/'.codex/skills/xctest-uiautomation-auth/scripts/watch-auth.py'
        if auth.exists():
            watcher=subprocess.Popen(['python3',str(auth),'--report',str(out/'auth-status.txt'),
                '--stop-file',str(out/'auth.stop'),'--timeout','300'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            deadline=time.monotonic()+10
            while not (out/'auth-status.txt').exists() or 'WATCH_READY' not in (out/'auth-status.txt').read_text():
                if watcher.poll() is not None or time.monotonic()>deadline: raise RuntimeError('XCTest 认证检测器未就绪')
                time.sleep(.1)
        driver=subprocess.Popen(['xcodebuild','test-without-building','-xctestrun',str(args.xctestrun.resolve()),
             '-destination','platform=macOS','-parallel-testing-enabled','NO',
             '-only-testing:CherryUtilityUITests/MenuBarPerformanceUITests/' + ('testFixedMenuSequence' if args.scenario=='fixed' else 'testMenuMemorySequence'),
             '-resultBundlePath',str(out/'ui.xcresult')],cwd=ROOT,env=env,stdout=ui_log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+120
        ready=None
        while ready is None:
            for line in (out/'uitest.txt').read_text().splitlines():
                if line.startswith('CHERRY_PROFILE_READY '): ready=json.loads(line.removeprefix('CHERRY_PROFILE_READY '))
            if ready is not None: break
            if driver.poll() is not None or time.monotonic()>deadline: raise RuntimeError('UI 驱动未发出 ready，见 uitest.txt')
            time.sleep(.2)
        (out/'ready.json').write_text(json.dumps(ready,indent=2))
        pid=ready['pid']; identity['pid']=pid
        (out/'identity.json').write_text(json.dumps(identity,ensure_ascii=False,indent=2))
        if args.scenario=='fixed':
            recorder=subprocess.Popen(['xcrun','xctrace','record',*RECORDINGS[args.recording],
                '--attach',str(pid),'--time-limit','180s','--output',str(out/'ui.trace')],stdout=trace_log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+45
            while 'Ctrl-C' not in (out/'xctrace.txt').read_text():
                if recorder.poll() is not None: raise RuntimeError('xctrace 无法开始，见 xctrace.txt')
                if time.monotonic()>deadline: raise TimeoutError('xctrace tracing ready')
                time.sleep(.2)
        (out/'profile.go').touch()
        deadline=time.monotonic()+300
        while not (out/'actions.json').exists():
            for line in (out/'uitest.txt').read_text().splitlines():
                if line.startswith('CHERRY_PROFILE_ACTIONS '):
                    (out/'actions.json').write_text(json.dumps(json.loads(line.removeprefix('CHERRY_PROFILE_ACTIONS ')),indent=2))
            if (out/'actions.json').exists(): break
            if driver.poll() is not None: raise RuntimeError('UI 场景未完成，见 uitest.txt')
            if time.monotonic()>deadline: raise TimeoutError('UI sequence')
            sample=subprocess.run(['ps','-p',str(pid),'-o','rss=','-o','time='],capture_output=True,text=True)
            if sample.returncode==0: memory.append({'epoch':time.time(),'rss_cpu':sample.stdout.strip()})
            time.sleep(.25)
        if recorder:
            recorder.send_signal(signal.SIGINT)
            # 附加的目标 App 要活到 trace 落盘：测试收尾结束 App 时 xctrace 若仍在停止，会报「Target app exited」并偶发保存失败。
            code=recorder.wait(timeout=300)
            if code not in [0,54] or not (out/'ui.trace').exists(): raise RuntimeError(f'xctrace 保存失败：{code}')
        # UI 校验已完成；放行驱动收尾。
        (out/'profile.saved').touch()
        if driver.wait(timeout=45)!=0: raise RuntimeError('UI 场景断言失败，见 uitest.txt')
        status='completed'
    finally:
        (out/'auth.stop').touch()
        if watcher:
            try: watcher.wait(timeout=5)
            except subprocess.TimeoutExpired: watcher.terminate();watcher.wait(timeout=5)
        (out/'memory.json').write_text(json.dumps(memory,indent=2))
        (out/'profile.saved').touch()
        if recorder and recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)
            try: recorder.wait(timeout=45)
            except subprocess.TimeoutExpired: recorder.kill();recorder.wait()
        if driver and driver.poll() is None:
            driver.terminate()
            try: driver.wait(timeout=15)
            except subprocess.TimeoutExpired: driver.kill();driver.wait()
        # --launch 的进程可能因驱动失败仍存活；只回收本次唯一可执行路径。
        processes=subprocess.check_output(['ps','-axo','pid=,command='],text=True)
        for line in processes.splitlines():
            parts=line.strip().split(maxsplit=1)
            if len(parts)==2 and pathlib.Path(parts[1].split(maxsplit=1)[0]).resolve()==binary.resolve():
                try: os.kill(int(parts[0]),signal.SIGTERM)
                except ProcessLookupError: pass
        ui_log.close();trace_log.close()
        (out/'status.json').write_text(json.dumps({'status':status},indent=2))
        shutil.copytree(out,final_out,dirs_exist_ok=True,symlinks=True)
        shutil.rmtree(out)
    print(final_out,flush=True)

if __name__=='__main__': main()
