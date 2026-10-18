import Foundation
import Synchronization

/// 外部自动化入口（命令行、MCP）的应用服务：开关、调用记录、App 的 socket 状态，以及把 cherry 装进 PATH、
/// 注册到 MCP 客户端。App 与独立运行的命令行进程各有一个实例；开关与调用记录经端口共用，两边看到的是同一份。
///
/// 执行模型：端点状态与订阅者表用 `Mutex` 保护，锁内只拷入拷出；记录与读取走端口（适配器负责跨进程的原子性）。
/// 记录之后先推给本进程的订阅者，再发跨进程信号；其他进程的信号由每个订阅自带的 Task 接收，订阅结束时取消。
public final class AutomationEntries: Sendable {
    private struct State {
        var endpoint: ControlEndpointStatus = .off
        var subscribers: [UUID: AsyncStream<AutomationActivity>.Continuation] = [:]
    }

    private let preferences: any AutomationPreferencesPort
    private let store: any AutomationActivityStore
    private let signals: any CrossProcessSignalPort
    private let installer: any CommandLineToolInstallerPort
    private let registry: any MCPClientRegistryPort
    private let route: AutomationRoute
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    public init(
        preferences: any AutomationPreferencesPort, activity: any AutomationActivityStore, signals: any CrossProcessSignalPort,
        installer: any CommandLineToolInstallerPort, registry: any MCPClientRegistryPort, route: AutomationRoute,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.preferences = preferences
        store = activity
        self.signals = signals
        self.installer = installer
        self.registry = registry
        self.route = route
        self.now = now
    }

    // MARK: - Switches

    public func isEnabled(_ entry: AutomationEntry) -> Bool {
        preferences.isEnabled(entry)
    }

    public func setEnabled(_ entry: AutomationEntry, _ enabled: Bool) {
        preferences.setEnabled(entry, enabled)
    }

    /// 被关闭的入口在到达键盘之前就被拒绝；App 与命令行直连都遵守同一个开关。
    public func authorize(_ entry: AutomationEntry) throws(AutomationError) {
        guard preferences.isEnabled(entry) else { throw .entryDisabled(entry) }
    }

    // MARK: - Activity

    /// 记录失败（例如磁盘只读）不影响请求本身。
    public func record(_ entry: AutomationEntry, operation: String, succeeded: Bool) {
        try? store.record(AutomationCall(entry: entry, operation: operation, succeeded: succeeded, route: route, date: now()))
        let current = store.load()
        let targets = state.withLock { Array($0.subscribers.values) }
        for continuation in targets { continuation.yield(current) }
        signals.post(.automationActivityChanged)
    }

    public func activity() -> AutomationActivity {
        store.load()
    }

    /// 先给当前记录，之后本进程或其他进程每记录一次就再给一次最新的。
    public func activityUpdates() -> AsyncStream<AutomationActivity> {
        let (stream, continuation) = AsyncStream.makeStream(of: AutomationActivity.self, bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        state.withLock { $0.subscribers[token] = continuation }
        continuation.yield(store.load())
        let remote = signals.signals(.automationActivityChanged)
        let relay = Task { [store] in
            for await _ in remote {
                guard !Task.isCancelled else { return }
                continuation.yield(store.load())
            }
        }
        continuation.onTermination = { [weak self] _ in
            relay.cancel()
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: token) }
        }
        return stream
    }

    // MARK: - Endpoint (app only)

    public func endpointChanged(_ status: ControlEndpointStatus) {
        state.withLock { $0.endpoint = status }
    }

    public var endpoint: ControlEndpointStatus {
        state.withLock { $0.endpoint }
    }

    // MARK: - Setup

    public func snapshot() async -> AutomationEntriesSnapshot {
        let tool = await installer.status()
        var registrations: [MCPClient: MCPClientRegistration] = [:]
        for client in MCPClient.allCases {
            registrations[client] = await registry.registration(in: client)
        }
        return AutomationEntriesSnapshot(
            enabled: Dictionary(uniqueKeysWithValues: AutomationEntry.allCases.map { ($0, isEnabled($0)) }),
            activity: activity(), endpoint: endpoint, commandLineTool: tool, bundledTool: installer.bundledTool,
            registrations: registrations, launch: Self.launch(tool: tool, bundled: installer.bundledTool)
        )
    }

    public func installCommandLineTool() async throws {
        try await installer.install()
    }

    public func uninstallCommandLineTool() async throws {
        try await installer.uninstall()
    }

    public func registerMCP(in client: MCPClient) async throws {
        guard let launch = Self.launch(tool: await installer.status(), bundled: installer.bundledTool) else {
            throw AutomationSetupError.noCommandLineTool
        }
        try await registry.register(launch, in: client)
    }

    /// MCP 客户端调用的 cherry：PATH 里可用的那一个优先（独立安装的不随 App 移动而失效），其次是 App 包内的。
    static func launch(tool: CommandLineToolStatus, bundled: String?) -> MCPServerLaunch? {
        (tool.installedPath ?? bundled).map { MCPServerLaunch(command: $0) }
    }
}
