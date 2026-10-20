import CherryCore
import CherryPresentation
import ComposableArchitecture
import Foundation

@Reducer
public struct SettingsFeature: Sendable {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case general = "通用"
        case updates = "更新"
        case automation = "自动化"
        case labs = "实验性功能"
        public var id: String { rawValue }
    }

    @ObservableState
    public struct State: Equatable {
        public var tab: Tab = .general
        @Shared(.customFirmwareEnabled) public var customFirmwareEnabled
        @Shared(.showMainWindowAtLaunch) public var showMainWindowAtLaunch
        @Shared(.showBatteryInMenuBar) public var showBatteryInMenuBar
        public var update: AppUpdateSnapshot = .unavailable
        public var launchAtLogin = false
        public var loginItemError: String?
        /// Risk confirmation shown before the experimental section is turned on.
        public var isConfirmingCustomFirmware = false
        public var riskAcknowledged = false
        /// 自动化入口的状态；没有加载到时为 nil。
        public var automation: AutomationEntriesSnapshot?
        /// 最近一次安装、移除、注册、复制的结果，显示在「自动化」页底部。
        public var automationNotice: AutomationNotice?
        public var isPerformingAutomationSetup = false

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case snapshotLoaded(AppUpdateSnapshot, launchAtLogin: Bool)
        case automaticallyChecksChanged(Bool)
        case automaticallyDownloadsChanged(Bool)
        case checkForUpdatesTapped
        case launchAtLoginChanged(Bool)
        case loginItemFailed(String, actual: Bool)
        case customFirmwareToggled(Bool)
        case confirmCustomFirmwareTapped
        case cancelCustomFirmwareTapped
        case automationLoaded(AutomationEntriesSnapshot?)
        case automationActivityChanged(AutomationActivity)
        case automationEntryToggled(AutomationEntry, Bool)
        case installCommandLineToolTapped
        case uninstallCommandLineToolTapped
        case registerMCPTapped(MCPClient)
        case automationSetupFinished(AutomationNotice)
        /// 视图把文字放进剪贴板后通知一声，用来显示提示。
        case automationCopied(String)
    }

    public struct AutomationNotice: Equatable, Sendable {
        public var text: String
        public var isError: Bool

        public init(_ text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    @Dependency(\.appUpdateClient) var updates
    @Dependency(\.loginItemClient) var loginItem
    @Dependency(\.automationEntriesClient) var automation

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                return .merge(
                    .run { send in
                        async let snapshot = updates.snapshot()
                        async let login = loginItem.isEnabled()
                        await send(.snapshotLoaded(await snapshot, launchAtLogin: await login))
                    },
                    .run { send in await send(.automationLoaded(await automation.snapshot())) },
                    // 设置窗口打开期间，命令行与 MCP 的每次调用都实时显示（包括命令行直连时的调用）。
                    .run { send in
                        for await activity in automation.activityUpdates() {
                            await send(.automationActivityChanged(activity))
                        }
                    }
                )

            case .snapshotLoaded(let snapshot, let login):
                state.update = snapshot
                state.launchAtLogin = login
                return .none

            case .automaticallyChecksChanged(let enabled):
                state.update.automaticallyChecks = enabled
                if !enabled { state.update.automaticallyDownloads = false }
                return .run { send in
                    await updates.setAutomaticallyChecks(enabled)
                    if !enabled { await updates.setAutomaticallyDownloads(false) }
                    await send(.snapshotLoaded(await updates.snapshot(), launchAtLogin: await loginItem.isEnabled()))
                }

            case .automaticallyDownloadsChanged(let enabled):
                state.update.automaticallyDownloads = enabled
                return .run { _ in await updates.setAutomaticallyDownloads(enabled) }

            case .checkForUpdatesTapped:
                return .run { send in
                    await updates.checkForUpdates()
                    await send(.snapshotLoaded(await updates.snapshot(), launchAtLogin: await loginItem.isEnabled()))
                }

            case .launchAtLoginChanged(let enabled):
                state.launchAtLogin = enabled
                state.loginItemError = nil
                return .run { send in
                    do {
                        try await loginItem.setEnabled(enabled)
                    } catch {
                        await send(.loginItemFailed(error.localizedDescription, actual: await loginItem.isEnabled()))
                    }
                }

            case .loginItemFailed(let message, let actual):
                state.loginItemError = message
                state.launchAtLogin = actual
                return .none

            case .customFirmwareToggled(let enabled):
                if enabled {
                    state.riskAcknowledged = false
                    state.isConfirmingCustomFirmware = true
                } else {
                    state.$customFirmwareEnabled.withLock { $0 = false }
                }
                return .none

            case .confirmCustomFirmwareTapped:
                guard state.riskAcknowledged else { return .none }
                state.$customFirmwareEnabled.withLock { $0 = true }
                state.isConfirmingCustomFirmware = false
                return .none

            case .cancelCustomFirmwareTapped:
                state.isConfirmingCustomFirmware = false
                state.riskAcknowledged = false
                return .none

            case .automationLoaded(let snapshot):
                state.automation = snapshot
                return .none

            case .automationActivityChanged(let activity):
                state.automation?.activity = activity
                return .none

            case .automationEntryToggled(let entry, let enabled):
                state.automation?.enabled[entry] = enabled
                return .run { send in
                    await automation.setEnabled(entry, enabled)
                    await send(.automationLoaded(await automation.snapshot()))
                }

            case .installCommandLineToolTapped:
                return setUp(&state, success: "已安装 cherry 命令，新开的终端窗口里可以直接使用") { try await automation.installCommandLineTool() }

            case .uninstallCommandLineToolTapped:
                return setUp(&state, success: "已移除 cherry 命令的链接") { try await automation.uninstallCommandLineTool() }

            case .registerMCPTapped(let client):
                return setUp(&state, success: "已添加到 \(AutomationText.name(of: client))，重启它后生效") { try await automation.registerMCP(client) }

            case .automationSetupFinished(let notice):
                state.isPerformingAutomationSetup = false
                state.automationNotice = notice
                return .run { send in await send(.automationLoaded(await automation.snapshot())) }

            case .automationCopied(let what):
                state.automationNotice = AutomationNotice("已复制\(what)")
                return .none
            }
        }
    }

    private func setUp(
        _ state: inout State, success: String, _ operation: @escaping @Sendable () async throws -> Void
    ) -> Effect<Action> {
        state.isPerformingAutomationSetup = true
        state.automationNotice = nil
        return .run { send in
            do {
                try await operation()
                await send(.automationSetupFinished(AutomationNotice(success)))
            } catch {
                await send(.automationSetupFinished(AutomationNotice(error.userMessage, isError: true)))
            }
        }
    }
}
