import CherryAdapters
import CherryControl
import CherryControlService
import CherryCore
import CherrySimulation
import Dispatch
import Foundation
import Synchronization

/// The command line's own composition root, used when no app answers: the core is assembled in this process and the
/// same `ControlService` handles the same requests, so texts, validation and error codes match the app exactly.
///
/// It shares with the app what `SharedLocations` names: presets, the automation switches and activity record, the
/// per-keyboard lock (so neither interleaves the other's transactions) and cross-process signals (so writes made here
/// reach the app's menu bar and windows, and the app's automation writes reach a `watch` running here).
///
/// A process assembles it at most once (the HID manager stays up); the calls of a `cherry mcp` session share it.
/// Two supervised tasks live as long as it does: the discovery feed (which keeps the write queue's connection set
/// current) and the relay of other processes' writes. Both are cancelled in `deinit`.
final class LocalControl: Sendable {
    let service: ControlService
    let access: InputMonitoringStatus
    private let tasks: [Task<Void, Never>]

    private init(service: ControlService, access: InputMonitoringStatus, tasks: [Task<Void, Never>]) {
        self.service = service
        self.access = access
        self.tasks = tasks
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    private static let assembled = Mutex<[SharedLocations: LocalControl]>([:])

    /// The process-wide instance for `locations` (a real process only ever has one). A failure (no Input Monitoring) is
    /// not cached, so a later call can succeed once the user has granted access.
    static func shared(_ locations: SharedLocations) throws(CLIError) -> LocalControl {
        if let existing = assembled.withLock({ $0[locations] }) { return existing }
        let made = try make(locations)
        return assembled.withLock { table in
            if let current = table[locations] { return current }
            table[locations] = made
            return made
        }
    }

    static func make(_ locations: SharedLocations) throws(CLIError) -> LocalControl {
        let discovery: any KeyboardDiscoveryPort
        let channels: any ReportChannelProvider
        let accessPort: any InputMonitoringPort
        if let scenario = locations.simulation {
            var named = SimulatedKeyboardHub.Scenario.named(scenario)
            named.sharedState = locations.simulationState
            let hub = SimulatedKeyboardHub(scenario: named)
            (discovery, channels, accessPort) = (hub, hub, hub)
        } else {
            let hid = IOKitHIDService(loop: HIDEventLoop(name: "cherry.HID"))
            (discovery, channels, accessPort) = (hid, hid, InputMonitoringAccess())
        }
        let access = accessPort.status()
        guard access == .granted else { throw .rejected(Self.accessFailure(access)) }

        let lock = FileDeviceLock(directory: locations.locks)
        let signals = DarwinNotifySignal(namespace: locations.signalNamespace)
        let services = CoreServices(
            discovery: discovery, channels: channels, catalog: UnavailableFirmwareCatalog(), downloader: UnavailableFirmwareCatalog(),
            lock: lock
        )
        let presets = PresetLibrary(store: FileProfilePresetStore(directory: locations.presets))
        let automation = services.automation(presets: presets, signals: signals)
        let entries = AutomationEntries(
            preferences: SharedAutomationPreferences(domain: locations.preferencesDomain),
            activity: FileAutomationActivityStore(file: locations.activity), signals: signals,
            installer: NoCommandLineToolInstaller(), registry: NoMCPClientRegistry(), route: .direct
        )
        let version = CherryVersion.current()
        let service = ControlService(automation: automation, entries: entries, appVersion: version.app, build: version.build)
        let tasks = [
            Task { for await _ in services.keyboardUpdates() { guard !Task.isCancelled else { return } } },
            Task { await automation.relayChangesFromOtherProcesses() },
        ]
        return LocalControl(service: service, access: access, tasks: tasks)
    }

    /// Without Input Monitoring the terminal (or the MCP client) that started `cherry` cannot open the keyboard.
    static func accessFailure(_ status: InputMonitoringStatus) -> ControlFailure {
        let reason = status == .denied ? "没有「输入监控」权限" : "还没有授予「输入监控」权限"
        return ControlFailure(
            code: "accessDenied",
            message: "\(reason)：CHERRY Utility 没在运行时，cherry 直接连接键盘，需要在「系统设置 › 隐私与安全性 › 输入监控」里允许运行 cherry 的终端"
                + "（或 Claude 等 MCP 客户端）；也可以先打开 CHERRY Utility，命令会经由它执行"
        )
    }

    // MARK: - Blocking bridge

    // `cherry` commands run synchronously on the main thread and MCP tool calls on a GCD thread (`offload`), never on a
    // cooperative thread, so blocking here while the request runs in a Task cannot starve the concurrency pool.

    /// One request, one response.
    func call(_ request: ControlRequest) -> ControlResponse {
        let response = Mutex<ControlResponse?>(nil)
        let done = DispatchSemaphore(value: 0)
        let service = service
        // 只取第一条响应（锁内只赋值）。
        let keep: @Sendable (ControlResponse) -> Void = { reply in response.withLock { $0 = $0 ?? reply } }
        let task = Task {
            await service.handle(request, reply: keep)
            done.signal()
        }
        done.wait()
        _ = task
        return response.withLock { $0 }
            ?? .failure(request.id, ControlFailure(code: "internalError", message: "没有得到结果"))
    }

    /// `watch`: hands every pushed response to `handle` until it returns false or the stream ends.
    func watch(_ request: ControlRequest, _ handle: @escaping @Sendable (ControlResponse) -> Bool) {
        let done = DispatchSemaphore(value: 0)
        let service = service
        let task = Task {
            let (events, continuation) = AsyncStream.makeStream(of: ControlResponse.self)
            let producer = Task {
                await service.handle(request) { continuation.yield($0) }
                continuation.finish()
            }
            for await event in events {
                if Task.isCancelled || !handle(event) { break }
            }
            producer.cancel()
            done.signal()
        }
        done.wait()
        _ = task
    }
}

/// The version of this `cherry` binary: from its embedded Info.plist, else from the app it sits in, else `dev`
/// (`swift build`).
enum CherryVersion {
    static func current(executable: URL? = Bundle.main.executableURL, own: [String: Any]? = Bundle.main.infoDictionary) -> ControlVersion {
        func pair(_ info: [String: Any]?) -> ControlVersion? {
            guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
            return ControlVersion(app: version, build: info?["CFBundleVersion"] as? String ?? "?")
        }
        let appPlist = Session.enclosingAppBundle(executable: executable)?.appending(path: "Contents/Info.plist")
        let appInfo = appPlist.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return pair(own) ?? pair(appInfo) ?? ControlVersion(app: "dev", build: "dev")
    }
}
