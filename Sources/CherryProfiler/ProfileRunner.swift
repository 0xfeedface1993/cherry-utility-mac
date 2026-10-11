import CherryAdapters
import CherryCore
import CherryFeatures
import ComposableArchitecture
import CryptoKit
import Foundation

/// 只操作具名模拟键盘，所有计量在同一进程；结果不宣称 UI 绘制或真实 HID 性能。
@MainActor
final class ProfileRunner {
    let options: ProfileOptions
    let runtime: DiagnosticsRuntime
    let diagnostics: Diagnostics
    var rows: [ProfileRow] = []
    var officialHash: String?
    let runID = UUID()

    init(options: ProfileOptions) {
        self.options = options
        runtime = DiagnosticsRuntime(directory: options.output.appendingPathComponent("journal"),
            environment: .init(appVersion: "profile", appBuild: "1", simulated: true),
            mode: options.mode == "noop" ? .off : options.mode == "profile" ? .profile : .standard)
        diagnostics = options.mode == "noop" ? .noop : runtime.port
    }

    func run() async throws {
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        if options.scenario == "trace" {
            for _ in 0..<3 { try await reads(); try await firmware(); try await ota() }
        } else {
            try await startup(); try await reads(); try await writes()
            try await input(); try await firmware(); try await ota(); try await idle()
        }
        try await runtime.flush()
        let snapshot = try await runtime.journal.snapshot(range: .currentRun)
        let begins = Set(snapshot.records.filter { $0.event.phase == .began }.map { $0.event.context.spanID })
        let ends = Set(snapshot.records.filter { $0.event.phase == .finished }.map { $0.event.context.spanID })
        guard begins.subtracting(ends).isEmpty, ends.subtracting(begins).isEmpty else { throw ProfileError.assertion("incomplete trace") }
        // 导出独立于场景计时，禁止把打包成本混进业务延迟。
        let start = ContinuousClock.now, resources = ProfileResources.current()
        let artifact = try await runtime.exporter.export(range: .currentRun, includeSystemLog: false)
        let saved = options.output.appendingPathComponent("evidence.cherrydiag.zip")
        try await runtime.exporter.save(artifact, to: saved)
        runtime.discard(artifact)
        rows.append(ProfileRow("S7.export", durations: [DiagnosticClock.nanoseconds(start.duration(to: .now))], start: start, resources: resources))
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let result = ProfileResult(runID: runID, generatedAt: Date(), mode: options.mode, buildConfiguration: configuration,
            environment: .init(appVersion: "profile", appBuild: "1", simulated: true), simulatedReplyDelayNs: 1_000_000,
            inputSeconds: options.inputSeconds, idleSeconds: options.idleSeconds, inputRatePerSecond: 1000, rows: rows,
            diagnosticRunID: runtime.journal.runID, diagnosticEvents: snapshot.records.count,
            droppedDiagnosticEvents: snapshot.dropped, diagnosticPartial: artifact.partial, incompleteSpans: begins.subtracting(ends).count,
            sampledSpanBegins: begins.count, sampledSpanEnds: ends.intersection(begins).count, officialUpdaterSHA256: officialHash)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: options.output.appendingPathComponent("scenario.json"), options: .atomic)
        print("completed mode=\(options.mode) run=\(runID) events=\(snapshot.records.count) dropped=\(snapshot.dropped)")
    }

    func hub(delay: Duration = .milliseconds(1)) -> SimulatedKeyboardHub {
        var scenario = SimulatedKeyboardHub.Scenario(); scenario.replyDelay = delay; scenario.rebootDelay = .milliseconds(100)
        return SimulatedKeyboardHub(scenario: scenario, diagnostics: diagnostics)
    }
    func duration<T>(_ body: () async throws -> T) async rethrows -> UInt64 {
        let start = ContinuousClock.now; _ = try await body(); return DiagnosticClock.nanoseconds(start.duration(to: .now))
    }
    func keyboard(_ hub: SimulatedKeyboardHub) async throws -> KeyboardSummary {
        guard let keyboard = await hub.keyboards().first else { throw ProfileError.assertion("missing simulated device") }; return keyboard
    }
    func startup() async throws {
        for name in ["empty", "pixiu75"] {
            let start = ContinuousClock.now, resources = ProfileResources.current(); var samples: [UInt64] = []
            for _ in 0..<10 {
                samples.append(try await duration {
                    let hub = SimulatedKeyboardHub(scenario: .named(name), diagnostics: diagnostics)
                    if let keyboard = await hub.keyboards().first {
                        _ = try await KeyboardInspector(channels: ExclusiveChannelProvider(base: hub, diagnostics: diagnostics), diagnostics: diagnostics).vendorSnapshot(of: keyboard)
                    }
                })
            }
            rows.append(.init("S1.\(name)", durations: samples, start: start, resources: resources, note: "进程内服务初始化；未测 App 冷启动与绘制"))
        }
    }
    func reads() async throws {
        let hub = hub(), keyboard = try await keyboard(hub)
        let channels = ExclusiveChannelProvider(base: hub, diagnostics: diagnostics)
        let inspector = KeyboardInspector(channels: channels, diagnostics: diagnostics)
        let start = ContinuousClock.now, resources = ProfileResources.current(); var samples: [UInt64] = []
        for _ in 0..<30 { samples.append(try await duration { try await inspector.vendorSnapshot(of: keyboard) }) }
        rows.append(.init("S2.serial", durations: samples, start: start, resources: resources))
        let concurrentStart = ContinuousClock.now, concurrentResources = ProfileResources.current()
        let values = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let start = ContinuousClock.now
                    _ = try await inspector.vendorSnapshot(of: keyboard)
                    return DiagnosticClock.nanoseconds(start.duration(to: .now))
                }
            }
            var values: [UInt64] = []; for try await value in group { values.append(value) }; return values
        }
        rows.append(.init("S2.contention", durations: values, start: concurrentStart, resources: concurrentResources, note: "100 个安全读取并发共享 gate"))
    }
    func writes() async throws {
        let hub = hub(), keyboard = try await keyboard(hub)
        let configurator = KeyboardConfigurator(channels: ExclusiveChannelProvider(base: hub, diagnostics: diagnostics), diagnostics: diagnostics)
        let initial = try await configurator.configuration(of: keyboard)
        let start = ContinuousClock.now, resources = ProfileResources.current(); var values: [UInt64] = []
        for i in 0..<100 {
            values.append(try await duration {
                try await configurator.update(profile: 1, on: keyboard, patch: .set(\.brightness, i % 5, field: .brightness, on: initial.active.settings))
            })
        }
        rows.append(.init("S3.write", durations: values, start: start, resources: resources, note: "100 次有读回的受控写入；UI 意图合并由 feature 回归测试覆盖"))
    }
    func input() async throws {
        let hub = hub(delay: .zero), keyboard = try await keyboard(hub)
        var initial = KeyTestFeature.State(keyboard: keyboard); initial.suppressAppShortcuts = false
        let port = diagnostics
        let store = Store(initialState: initial) { KeyTestFeature() } withDependencies: {
            $0.diagnostics = port
            $0.keyTestClient.accessStatus = { .granted }
            $0.keyTestClient.keyEvents = { hub.keyEvents(keyboard: $0) }
        }
        store.send(.task)
        try await Task.sleep(for: .milliseconds(50))
        guard store.isCapturing else { throw ProfileError.assertion("capture did not start") }
        let start = ContinuousClock.now, resources = ProfileResources.current()
        let count = options.inputSeconds * 1000
        for i in 0..<count {
            try await ContinuousClock().sleep(until: start + .milliseconds(i), tolerance: .microseconds(50))
            hub.inject(.keyboard(0x04), isDown: i.isMultiple(of: 2), timestamp: UInt64(i) * 1_000_000)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while store.eventCount < count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let consumed = store.eventCount
        await store.send(.viewDisappeared).finish()
        guard consumed == count else { throw ProfileError.assertion("key events lost: \(consumed)/\(count)") }
        rows.append(.init("S4.input", durations: [], start: start, resources: resources, sent: count, consumed: consumed, note: "1000 事件/秒，真实 KeyTestFeature reducer；无窗口绘制"))
    }
    func firmware() async throws {
        let data: Data
        if let url = options.updater {
            data = try Data(contentsOf: url)
            officialHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else { data = SyntheticUpdater.updaterExe(for: .pixiu75, version: 0x0118) }
        let start = ContinuousClock.now, resources = ProfileResources.current(); var values: [UInt64] = []
        for _ in 0..<10 {
            values.append(try await duration {
                let package = try diagnostics.measure(.firmwareParse, origin: .profile, metrics: .init(bytes: UInt64(data.count))) {
                    try FirmwareUpdateService.makePackage(data: data, source: .localFile(URL(fileURLWithPath: "/fixture.exe")), diagnostics: diagnostics)
                }
                let proto = try TelinkOTAProtocol(reportID: package.image.reportID, reportLength: 64)
                let reports = diagnostics.measure(.otaReports, origin: .profile) { proto.transferReports(firmware: package.image.firmware) }
                guard !reports.0.isEmpty else { throw ProfileError.assertion("no reports") }
            })
        }
        rows.append(.init("S5.parse", durations: values, start: start, resources: resources, note: options.updater == nil ? "固定合成文件；内存暖解析" : "固定官方文件；内存暖解析"))
    }
    func ota() async throws {
        let hub = hub(), keyboard = try await keyboard(hub), catalog = SimulatedFirmwareCatalog()
        let channels = ExclusiveChannelProvider(base: hub, diagnostics: diagnostics)
        let service = FirmwareUpdateService(catalog: catalog, downloader: catalog, channels: channels, discovery: hub, diagnostics: diagnostics)
        let package = try FirmwareUpdateService.makePackage(data: SyntheticUpdater.updaterExe(for: .pixiu75, version: 0x0118), source: .localFile(URL(fileURLWithPath: "/fixture.exe")))
        let start = ContinuousClock.now, resources = ProfileResources.current()
        let value = try await duration {
            let outcome = try await service.flash(keyboard: keyboard, package: package) { _ in }
            guard outcome == .confirmed else { throw ProfileError.assertion("OTA unconfirmed") }
            _ = try await service.verifyAfterFlash(keyboard: keyboard.id, package: package, timeout: .seconds(3), pollInterval: .milliseconds(50))
        }
        rows.append(.init("S6.ota", durations: [value], start: start, resources: resources, note: "合成 6000 字节固件，1 ms 回复；含重连 CRC 核对"))
        let cancelHub = self.hub(delay: .milliseconds(3)), cancelKeyboard = try await self.keyboard(cancelHub)
        let cancelService = FirmwareUpdateService(catalog: catalog, downloader: catalog, channels: ExclusiveChannelProvider(base: cancelHub, diagnostics: diagnostics), discovery: cancelHub, diagnostics: diagnostics)
        let task = Task { try await cancelService.flash(keyboard: cancelKeyboard, package: package) { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        let cancelStart = ContinuousClock.now, cancelResources = ProfileResources.current(); task.cancel()
        do { _ = try await task.value; throw ProfileError.assertion("cancellation ignored") } catch is CancellationError { }
        _ = try await KeyboardInspector(channels: ExclusiveChannelProvider(base: cancelHub), diagnostics: .noop).vendorSnapshot(of: cancelKeyboard)
        rows.append(.init("S6.cancel", durations: [DiagnosticClock.nanoseconds(cancelStart.duration(to: .now))], start: cancelStart, resources: cancelResources, note: "中断后再次读取成功；含清理后读取"))
    }
    func idle() async throws {
        let start = ContinuousClock.now, resources = ProfileResources.current()
        let hub = hub(), keyboard = try await keyboard(hub)
        let inspector = KeyboardInspector(channels: ExclusiveChannelProvider(base: hub, diagnostics: diagnostics), diagnostics: diagnostics)
        var polls = 0
        for second in stride(from: 0, to: options.idleSeconds, by: 60) {
            _ = try await inspector.vendorSnapshot(of: keyboard); polls += 1
            try await ContinuousClock().sleep(until: start + .seconds(min(second + 60, options.idleSeconds)))
        }
        rows.append(.init("S7.idle", durations: [], start: start, resources: resources, sent: polls, note: "模拟常驻 60 秒读取周期；无 App/系统菜单栏绘制，switches 不是系统 wakeup"))
    }
}
