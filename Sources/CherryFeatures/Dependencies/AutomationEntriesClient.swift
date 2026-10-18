import CherryCore
import ComposableArchitecture
import Foundation

/// 「设置 › 自动化」经它调用 Core 的 `AutomationEntries`：开关、调用记录、App 的 socket 状态、把 cherry 装进 PATH、
/// 注册到 MCP 客户端。组合根接到真实服务；模拟模式下服务的文件路径都在临时目录。
@DependencyClient
public struct AutomationEntriesClient: Sendable {
    public var snapshot: @Sendable () async -> AutomationEntriesSnapshot? = { nil }
    /// 当前记录，之后本进程或命令行进程每记录一次就再给一次。
    public var activityUpdates: @Sendable () -> AsyncStream<AutomationActivity> = { .finished }
    public var setEnabled: @Sendable (_ entry: AutomationEntry, _ enabled: Bool) async -> Void
    public var installCommandLineTool: @Sendable () async throws -> Void
    public var uninstallCommandLineTool: @Sendable () async throws -> Void
    public var registerMCP: @Sendable (_ client: MCPClient) async throws -> Void
}

extension AutomationEntriesClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(
        snapshot: { .preview },
        activityUpdates: { AsyncStream { $0.yield(AutomationEntriesSnapshot.preview.activity) } },
        setEnabled: { _, _ in },
        installCommandLineTool: {},
        uninstallCommandLineTool: {},
        registerMCP: { _ in }
    )
}

extension DependencyValues {
    public var automationEntriesClient: AutomationEntriesClient {
        get { self[AutomationEntriesClient.self] }
        set { self[AutomationEntriesClient.self] = newValue }
    }
}

extension AutomationEntriesSnapshot {
    static let preview: Self = {
        var activity = AutomationActivity()
        activity.commandLine = AutomationEntryActivity(
            lastCall: AutomationCall(entry: .commandLine, operation: "status", succeeded: true, route: .direct, date: Date(timeIntervalSince1970: 1_792_000_000)),
            count: 12
        )
        let bundled = "/Applications/CherryUtility.app/Contents/MacOS/cherry"
        return Self(
            enabled: [.commandLine: true, .mcp: true], activity: activity,
            endpoint: .listening(path: "~/Library/Application Support/CherryUtility/control.sock"),
            commandLineTool: .linkedToBundledTool(path: "/usr/local/bin/cherry"), bundledTool: bundled,
            registrations: [.claudeDesktop: .notRegistered, .claudeCode: .clientNotInstalled],
            launch: MCPServerLaunch(command: "/usr/local/bin/cherry")
        )
    }()
}
