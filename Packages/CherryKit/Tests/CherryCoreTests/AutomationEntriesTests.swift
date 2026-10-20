import Foundation
import Synchronization
import Testing
@testable import CherryCore

/// 记录取得与释放的租约；`failure` 非空时取租约失败。
final class RecordingLock: DeviceLockPort, Sendable {
    enum Event: Equatable { case acquired(DeviceLockPurpose), released(DeviceLockPurpose) }
    private let log = Mutex<[Event]>([])
    private let failure = Mutex<CherryError?>(nil)

    var events: [Event] { log.withLock { $0 } }
    func fail(with error: CherryError?) { failure.withLock { $0 = error } }

    func acquire(_ keyboard: KeyboardID, purpose: DeviceLockPurpose) async throws -> any DeviceLease {
        if let error = failure.withLock({ $0 }) { throw error }
        log.withLock { $0.append(.acquired(purpose)) }
        return Lease { [weak self] in self?.log.withLock { $0.append(.released(purpose)) } }
    }

    final class Lease: DeviceLease, Sendable {
        private let body: Mutex<(@Sendable () -> Void)?>
        init(_ body: @escaping @Sendable () -> Void) { self.body = Mutex(body) }
        func release() { body.withLock { b in defer { b = nil }; return b }?() }
    }
}

/// 记录本进程发出的信号；`deliver` 模拟另一个进程发来的信号。
final class FakeSignals: CrossProcessSignalPort, Sendable {
    private let posted = Mutex<[CrossProcessSignal]>([])
    private let listeners = Mutex<[CrossProcessSignal: [AsyncStream<Void>.Continuation]]>([:])

    var posts: [CrossProcessSignal] { posted.withLock { $0 } }

    func post(_ signal: CrossProcessSignal) { posted.withLock { $0.append(signal) } }

    func signals(_ signal: CrossProcessSignal) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        listeners.withLock { $0[signal, default: []].append(continuation) }
        return stream
    }

    func deliver(_ signal: CrossProcessSignal) {
        for continuation in listeners.withLock({ $0[signal] ?? [] }) { continuation.yield() }
    }

    func listening(_ signal: CrossProcessSignal) -> Bool { listeners.withLock { !($0[signal] ?? []).isEmpty } }
}

final class MemoryPreferences: AutomationPreferencesPort, Sendable {
    private let values = Mutex<[AutomationEntry: Bool]>([:])
    func isEnabled(_ entry: AutomationEntry) -> Bool { values.withLock { $0[entry] ?? true } }
    func setEnabled(_ entry: AutomationEntry, _ enabled: Bool) { values.withLock { $0[entry] = enabled } }
}

final class MemoryActivity: AutomationActivityStore, Sendable {
    private let value = Mutex(AutomationActivity())
    func load() -> AutomationActivity { value.withLock { $0 } }
    func record(_ call: AutomationCall) throws -> AutomationActivity { value.withLock { $0 = $0.recording(call); return $0 } }
}

struct FakeInstaller: CommandLineToolInstallerPort {
    var bundledTool: String?
    var current: CommandLineToolStatus
    func status() async -> CommandLineToolStatus { current }
    func install() async throws {}
    func uninstall() async throws {}
}

final class FakeRegistry: MCPClientRegistryPort, Sendable {
    private let registered = Mutex<[MCPServerLaunch]>([])
    var launches: [MCPServerLaunch] { registered.withLock { $0 } }
    func registration(in client: MCPClient) async -> MCPClientRegistration {
        registered.withLock { $0.last.map { .registered(command: $0.command) } ?? .notRegistered }
    }
    func register(_ launch: MCPServerLaunch, in client: MCPClient) async throws { registered.withLock { $0.append(launch) } }
}

@Suite("跨进程协调：租约与信号")
struct CrossProcessCoordinationTests {
    /// 通道打开时取会话租约，关闭时释放；取租约失败时释放进程内的排队，下一个调用不被卡住。
    @Test func channelsHoldALeaseUntilClosed() async throws {
        let lock = RecordingLock()
        let gate = ChannelGate<ExclusiveChannelProvider.Key>()
        let raw = SimulatedChannel(inputReportIDs: [5]) { .reports([$0]) }
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [raw]), gate: gate, lock: lock)
        let keyboard = ServiceBranchTests.keyboard.id
        let channel = try await provider.openChannel(keyboard: keyboard, usagePage: 0xFFEF, reportID: 5)
        #expect(lock.events == [.acquired(.session)])
        await channel.close()
        #expect(lock.events == [.acquired(.session), .released(.session)])

        lock.fail(with: .deviceBusy(.updatingFirmware))
        await #expect(throws: CherryError.deviceBusy(.updatingFirmware)) {
            try await provider.openChannel(keyboard: keyboard, usagePage: 0xFFEF, reportID: 5)
        }
        #expect(!gate.isHeld(ExclusiveChannelProvider.Key(keyboard: keyboard, usagePage: 0xFFEF)))
        lock.fail(with: nil)
        await (try await provider.openChannel(keyboard: keyboard, usagePage: 0xFFEF, reportID: 5)).close()
    }

    /// 刷写全程持有 `.firmwareUpdate` 租约；取不到时不标记为刷写中。
    @Test func firmwareActivityHoldsAnUpdateLease() async throws {
        let lock = RecordingLock()
        let activity = FirmwareActivity(lock: lock)
        let keyboard = ServiceBranchTests.keyboard.id
        try await activity.during(keyboard) {
            #expect(activity.isBusy(keyboard))
            #expect(lock.events == [.acquired(.firmwareUpdate)])
        }
        #expect(lock.events == [.acquired(.firmwareUpdate), .released(.firmwareUpdate)])
        lock.fail(with: .deviceBusy(.inUse))
        await #expect(throws: CherryError.deviceBusy(.inUse)) { try await activity.during(keyboard) { 1 } }
        #expect(!activity.isBusy(keyboard))
    }

    /// 自动化写入后发跨进程信号；收到另一个进程的信号时重读配置，推给本进程的订阅者。
    @Test func automationWritesSignalAndRemoteSignalsAreRelayed() async throws {
        let signals = FakeSignals()
        let probe = AutomationProbe()
        let automation = probe.automation(KeyboardAutomationTests.discovery(KeyboardAutomationTests.pixiu75), signals: signals)
        var changes = automation.changes().makeAsyncIterator()
        _ = try await automation.activate(profile: 2, on: nil)
        #expect(signals.posts == [.configurationChanged])
        #expect(await changes.next()?.keyboardID == KeyboardAutomationTests.pixiu75.id)

        let relay = Task { await automation.relayChangesFromOtherProcesses() }
        defer { relay.cancel() }
        while !signals.listening(.configurationChanged) { await Task.yield() }
        let reads = probe.readCount
        signals.deliver(.configurationChanged)
        let relayed = await changes.next()
        #expect(relayed == ExternalConfigurationChange(keyboardID: KeyboardAutomationTests.pixiu75.id, change: .configuration(probe.base)))
        #expect(probe.readCount == reads + 1)
        #expect(signals.posts == [.configurationChanged], "重读不再发信号，不会在两个进程之间来回触发")
    }
}

@Suite("自动化入口服务")
struct AutomationEntriesTests {
    static func entries(
        _ preferences: MemoryPreferences = MemoryPreferences(), signals: FakeSignals = FakeSignals(),
        installer: FakeInstaller = FakeInstaller(bundledTool: "/Applications/CherryUtility.app/Contents/MacOS/cherry", current: .notInstalled),
        registry: FakeRegistry = FakeRegistry(), route: AutomationRoute = .viaApp
    ) -> AutomationEntries {
        AutomationEntries(
            preferences: preferences, activity: MemoryActivity(), signals: signals, installer: installer, registry: registry,
            route: route, now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    @Test func disabledEntriesAreRefused() throws {
        let preferences = MemoryPreferences()
        let entries = Self.entries(preferences)
        try entries.authorize(.mcp)
        entries.setEnabled(.mcp, false)
        #expect(throws: AutomationError.entryDisabled(.mcp)) { try entries.authorize(.mcp) }
        try entries.authorize(.commandLine)
        #expect(!entries.isEnabled(.mcp) && entries.isEnabled(.commandLine))
    }

    /// 记录先推给本进程的订阅者再发信号；另一个进程的信号让订阅者重新读取共享记录。
    @Test func activityIsPublishedLocallyAndAcrossProcesses() async throws {
        let signals = FakeSignals()
        let entries = Self.entries(signals: signals, route: .direct)
        var updates = entries.activityUpdates().makeAsyncIterator()
        #expect(await updates.next() == AutomationActivity())
        entries.record(.commandLine, operation: "status", succeeded: true)
        let first = try #require(await updates.next())
        #expect(first.commandLine.count == 1 && first.commandLine.lastCall?.route == .direct && first.mcp.count == 0)
        #expect(signals.posts == [.automationActivityChanged])
        while !signals.listening(.automationActivityChanged) { await Task.yield() }
        signals.deliver(.automationActivityChanged)
        #expect(await updates.next() == first)
    }

    /// 注册到 MCP 客户端用的 cherry：独立安装的优先，其次是 PATH 里链接到 App 的，最后是 App 包内的。
    @Test func theLaunchPrefersTheToolOnThePath() async throws {
        let bundled = "/Applications/CherryUtility.app/Contents/MacOS/cherry"
        #expect(AutomationEntries.launch(tool: .standalone(path: "/opt/homebrew/bin/cherry"), bundled: bundled)?.command == "/opt/homebrew/bin/cherry")
        #expect(AutomationEntries.launch(tool: .linkedToBundledTool(path: "/usr/local/bin/cherry"), bundled: bundled)?.command == "/usr/local/bin/cherry")
        #expect(AutomationEntries.launch(tool: .other(path: "/usr/local/bin/cherry", target: "/x"), bundled: bundled)?.command == bundled)
        #expect(AutomationEntries.launch(tool: .notInstalled, bundled: nil) == nil)

        let registry = FakeRegistry()
        let entries = Self.entries(registry: registry)
        try await entries.registerMCP(in: .claudeDesktop)
        #expect(registry.launches == [MCPServerLaunch(command: bundled)])
        let snapshot = await entries.snapshot()
        #expect(snapshot.registrations[.claudeDesktop] == .registered(command: bundled))
        #expect(snapshot.enabled == [.commandLine: true, .mcp: true] && snapshot.endpoint == .off && snapshot.bundledTool == bundled)

        let standalone = Self.entries(installer: FakeInstaller(bundledTool: nil, current: .notInstalled))
        await #expect(throws: AutomationSetupError.noCommandLineTool) { try await standalone.registerMCP(in: .claudeDesktop) }
    }

    @Test func theEndpointIsReportedByTheApp() {
        let entries = Self.entries()
        entries.endpointChanged(.listening(path: "/tmp/x.sock"))
        #expect(entries.endpoint == .listening(path: "/tmp/x.sock"))
    }
}
