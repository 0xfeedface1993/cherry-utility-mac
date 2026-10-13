import ComposableArchitecture
import Foundation

@Reducer
public struct SettingsFeature: Sendable {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case general = "通用"
        case updates = "更新"
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
    }

    @Dependency(\.appUpdateClient) var updates
    @Dependency(\.loginItemClient) var loginItem

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                return .run { send in
                    async let snapshot = updates.snapshot()
                    async let login = loginItem.isEnabled()
                    await send(.snapshotLoaded(await snapshot, launchAtLogin: await login))
                }

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
            }
        }
    }
}
