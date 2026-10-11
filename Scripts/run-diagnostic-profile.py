#!/usr/bin/env python3
"""构建一次 Release，在同一源码下顺序对照；只读具名 source roots。"""
import argparse, hashlib, json, pathlib, platform, subprocess, datetime, uuid, zipfile, statistics
ROOT = pathlib.Path(__file__).resolve().parents[1]
def command(args, **kw):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, **kw)
def capture(args):
    return command(args, capture_output=True).stdout.strip()
def identity():
    files = [ROOT/'project.yml', ROOT/'Packages/CherryKit/Package.swift', pathlib.Path(__file__)]
    for name in ['App/Sources', 'Packages/CherryKit/Sources', 'Packages/CherryKit/Tests', 'UITests']:
        files += list((ROOT/name).rglob('*.swift'))
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return {'source_sha256': digest, 'file_sha256': hashes,
            'commit': capture(['git','rev-parse','HEAD']), 'git_status': capture(['git','status','--short']),
            'xcode': capture(['xcodebuild','-version']), 'swift': capture(['xcrun','swift','--version']),
            'os': platform.mac_ver()[0], 'architecture': platform.machine(),
            'hardware_model': capture(['sysctl','-n','hw.model']), 'memory_bytes': int(capture(['sysctl','-n','hw.memsize']))}
def validate(directory):
    result = json.loads((directory/'scenario.json').read_text())
    assert result['buildConfiguration'] == 'Release'
    assert result['incompleteSpans'] == 0 and result['droppedDiagnosticEvents'] == 0, result
    for row in result['rows']:
        if row['scenario'] == 'S4.input': assert row['sent'] == row['consumed']
    with zipfile.ZipFile(directory/'evidence.cherrydiag.zip') as archive:
        manifest = json.loads(archive.read('manifest.json'))
        for item in manifest['files']:
            data = archive.read(item['name']); assert len(data) == item['bytes']; assert hashlib.sha256(data).hexdigest() == item['sha256']
        assert manifest['incomplete_spans'] == 0
        events = archive.read('events.ndjson')
        for banned in [b'/Users/', b'fixture.exe', b'http://', b'https://', b'SECRET']:
            assert banned not in events
    return result
def summary(output, results):
    text = ['# Release 模拟 profile 结果', '', '源码与构建身份见 identity.json；所有场景顺序运行。诊断导出独立计时，未自动上传。', '',
            '| 场景 | 模式 | 样本 | 中位耗时 ms | CPU s | 峰值 RSS MiB | 发送/消费 |', '|---|---|---:|---:|---:|---:|---|']
    for result in results:
        for row in result['rows']:
            text.append(f"| {row['scenario']} | {result['mode']} | {row['samples']} | {row['medianNs']/1e6:.3f} | {row['cpuSeconds']:.6f} | {row['maximumRSSBytes']/1048576:.2f} | {row.get('sent','')}/{row.get('consumed','')} |")
    text += ['', '## 观测开销', '', '| 场景 | 模式 | 中位耗时变化 | CPU 绝对差 s | CPU 变化 |', '|---|---|---:|---:|---:|']
    for scenario in sorted({r['scenario'] for result in results for r in result['rows']}):
        by_mode = {}
        for result in results:
            for row in result['rows']:
                if row['scenario'] == scenario: by_mode.setdefault(result['mode'], []).append(row)
        if 'noop' not in by_mode: continue
        base_wall = statistics.median(r['medianNs'] for r in by_mode['noop'])
        base_cpu = statistics.median(r['cpuSeconds'] for r in by_mode['noop'])
        for mode in ['standard','profile']:
            if mode not in by_mode: continue
            wall = statistics.median(r['medianNs'] for r in by_mode[mode]); cpu = statistics.median(r['cpuSeconds'] for r in by_mode[mode])
            wall_delta = f'{(wall/base_wall-1)*100:+.2f}%' if base_wall else '无逐事件样本'
            cpu_delta = f'{(cpu/base_cpu-1)*100:+.2f}%' if base_cpu >= .1 else '低 CPU 基线，比较绝对差'
            text.append(f'| {scenario} | {mode} | {wall_delta} | {cpu-base_cpu:+.6f} | {cpu_delta} |')
    text += ['', '## 口径与限制', '', '- S1 为进程内模拟服务初始化，S4 包含真实 reducer，不包含 SwiftUI 绘制或真实 IOKit。',
             '- 固件输入 SHA-256 见各 scenario.json；S5 为内存暖解析，真实网络与冷磁盘未测。',
             '- S6 为合成 6000 字节 OTA；真实 OTA、ACK 超时与断连异常由单元测试及后续真机实验区分。',
             '- S7 为模拟 60 秒轮询；进程 context switch 不是系统唤醒。RSS 是进程累计高水位，不是分配数量或诊断独占内存。',
             '- 标准 3% / Profile 5% 为待验证目标；超过目标时应先优化观测开销，不据此宣称业务优化有效。',
             '- 单次运行与小样本只能作为初始证据；冷启动、Allocations、UI、真机及三次长跑稳定性需另采。']
    (output/'summary.md').write_text('\n'.join(text)+'\n')
def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--repetitions', type=int, choices=range(1,4), default=1)
    parser.add_argument('--idle-seconds', type=int, default=300); parser.add_argument('--input-seconds', type=int, default=60)
    parser.add_argument('--official-updater', type=pathlib.Path)
    parser.add_argument('--build-directory', type=pathlib.Path)
    args = parser.parse_args()
    assert 0 <= args.idle_seconds <= 300 and 1 <= args.input_seconds <= 60
    output = (args.output or ROOT/'build/profile'/f"{datetime.datetime.now():%Y%m%d-%H%M%S}-{str(uuid.uuid4())[:8]}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    source_before_build = identity()['source_sha256']
    build_directory = (args.build_directory or ROOT/'build/profile/toolchain-release').resolve()
    with (output/'build.txt').open('w') as log:
        command(['swift','build','--build-system','native','--scratch-path',str(build_directory),'--package-path',str(ROOT/'Packages/CherryKit'),'-c','release','-debug-info-format','none','--product','CherryProfiler'], stdout=log, stderr=subprocess.STDOUT, timeout=180)
    executable = pathlib.Path(capture(['swift','build','--build-system','native','--scratch-path',str(build_directory),'--package-path',str(ROOT/'Packages/CherryKit'),'-c','release','-debug-info-format','none','--show-bin-path']))/'CherryProfiler'
    provenance = identity(); provenance['executable_sha256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
    assert provenance['source_sha256'] == source_before_build, '构建期间源码变化，请重新建立证据'
    provenance['debug_info_format'] = 'none'
    provenance['build_system'] = 'native'
    provenance['command'] = vars(args) | {'output': str(output), 'official_updater': str(args.official_updater) if args.official_updater else None}
    (output/'identity.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2, default=str))
    results = []
    for repetition in range(args.repetitions):
        # 轮换顺序，减少持续温度/缓存对某一个模式的固定偏置。
        modes = ['noop','standard','profile']; modes = modes[repetition:] + modes[:repetition]
        for mode in modes:
            directory = output/f'{mode}-{repetition+1}'; directory.mkdir()
            arguments = [str(executable),'--mode',mode,'--output',str(directory),'--idle-seconds',str(args.idle_seconds),'--input-seconds',str(args.input_seconds)]
            if args.official_updater: arguments += ['--official-updater',str(args.official_updater.resolve())]
            print(f'start {directory.name}', flush=True)
            with (directory/'process.txt').open('w') as log: command(arguments, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            results.append(validate(directory)); summary(output, results)
            print(f'validated {directory.name}', flush=True)
    assert identity()['source_sha256'] == provenance['source_sha256'], '运行期间源码变化，请重新建立可比较基线'
    print(f'complete {output}', flush=True)
if __name__ == '__main__': main()
