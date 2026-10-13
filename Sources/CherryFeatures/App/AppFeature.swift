import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct AppFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        public var keyboards: IdentifiedArrayOf<KeyboardSummary> = []
        public var detail: KeyboardFeature.State?
        public var menuBar = MenuBarFeature.State()
        public var diagnostics = DiagnosticsFeature.State()
        public var settings = SettingsFeature.State()
        /// `task` is sent both at launch (for the menu bar) and by the main window; only the first one starts work.
        public var hasStarted = false

        public init() {}

        public var selectedID: KeyboardID? { detail?.keyboard.id }
    }

    public enum Action {
        case task
        case keyboardsUpdated([KeyboardSummary])
        case selectKeyboard(KeyboardID?)
        case detail(KeyboardFeature.Action)
        case menuBar(MenuBarFeature.Action)
        case diagnostics(DiagnosticsFeature.Action)
        case settings(SettingsFeature.Action)
    }

    @Dependency(\.keyboardClient) var keyboardClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.menuBar, action: \.menuBar) { MenuBarFeature() }
        Scope(state: \.diagnostics, action: \.diagnostics) { DiagnosticsFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Reduce { state, action in
            switch action {
            case .task:
                guard !state.hasStarted else { return .none }
                state.hasStarted = true
                return .merge(
                    .run { send in
                        for await list in keyboardClient.updates() {
                            try Task.checkCancellation()
                            await send(.keyboardsUpdated(list))
                        }
                    },
                    .send(.menuBar(.task))
                )

            case .keyboardsUpdated(let list):
                state.keyboards = IdentifiedArray(uniqueElements: list)
                let menuBar: Effect<Action> = .send(.menuBar(.keyboardsUpdated(list)))
                guard let detail = state.detail else {
                    if let first = list.first { state.detail = KeyboardFeature.State(keyboard: first) }
                    return menuBar
                }
                // The detail outlives a disconnect (an OTA reboots the keyboard mid-flow); children are told instead.
                let updated = state.keyboards[id: detail.keyboard.id]
                // 快速重枚举可能把中间的空列表合并掉；接口身份变化仍必须结束旧会话。
                if let updated, detail.keyboard.canConfigure, updated.canConfigure,
                   updated.configurationInterfaceIDs != detail.keyboard.configurationInterfaceIDs {
                    return .merge(menuBar, .concatenate(
                        .send(.detail(.keyboardUpdated(nil))),
                        .send(.detail(.keyboardUpdated(updated)))
                    ))
                }
                return .merge(menuBar, .send(.detail(.keyboardUpdated(updated))))

            case .selectKeyboard(let id):
                guard id != state.selectedID, state.detail?.isBusy != true else { return .none }
                state.detail = id.flatMap { state.keyboards[id: $0] }.map(KeyboardFeature.State.init)
                return .none

            case .menuBar(.delegate(.configurationChanged(let id, let change))):
                guard let detail = state.detail, detail.keyboard.id == id else { return .none }
                return .merge(
                    .send(.detail(.configuration(.configurationSynchronized(change)))),
                    .send(.detail(.info(.configurationSynchronized(change))))
                )

            case .detail(.configuration(.delegate(.configurationChanged(let id, let change)))):
                return .merge(
                    .send(.menuBar(.configurationSynchronized(id, change))),
                    .send(.detail(.info(.configurationSynchronized(change))))
                )

            case .detail, .menuBar, .diagnostics, .settings:
                return .none
            }
        }
        .ifLet(\.detail, action: \.detail) {
            KeyboardFeature()
        }
    }
}

@Reducer
public struct KeyboardFeature: Sendable {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case info = "概览"
        case configuration = "灯光与配置档"
        case keyTest = "按键测试"
        case firmware = "固件升级"
        case customFirmware = "自定义固件"
        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .info: "gauge.with.dots.needle.67percent"
            case .configuration: "lightbulb.led"
            case .keyTest: "keyboard"
            case .firmware: "arrow.down.circle"
            case .customFirmware: "flask"
            }
        }

        /// Only shown once the user turned on the experimental section in Settings.
        public var isExperimental: Bool { self == .customFirmware }
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboard: KeyboardSummary
        public var isConnected = true
        public var section: Section = .info
        public var info: DeviceInfoFeature.State
        public var configuration: ConfigurationFeature.State
        public var keyTest: KeyTestFeature.State
        public var firmware: FirmwareFeature.State
        public var customFirmware: CustomFirmwareFeature.State
        @Shared(.customFirmwareEnabled) public var customFirmwareEnabled

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
            info = DeviceInfoFeature.State(keyboard: keyboard)
            configuration = ConfigurationFeature.State(keyboard: keyboard)
            keyTest = KeyTestFeature.State(keyboard: keyboard)
            firmware = FirmwareFeature.State(keyboard: keyboard)
            customFirmware = CustomFirmwareFeature.State(keyboard: keyboard)
        }

        public var isBusy: Bool { firmware.isBusy || customFirmware.isBusy || configuration.isBusy }

        /// Sections in the sidebar. The experimental one stays while it is flashing, even if it was just switched off.
        public var visibleSections: [Section] {
            Section.allCases.filter { !$0.isExperimental || customFirmwareEnabled || customFirmware.isBusy }
        }

        /// The section actually on screen: falls back to the overview when the selected one was hidden.
        public var displayedSection: Section {
            visibleSections.contains(section) ? section : .info
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case keyboardUpdated(KeyboardSummary?)
        case info(DeviceInfoFeature.Action)
        case configuration(ConfigurationFeature.Action)
        case keyTest(KeyTestFeature.Action)
        case firmware(FirmwareFeature.Action)
        case customFirmware(CustomFirmwareFeature.Action)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.info, action: \.info) { DeviceInfoFeature() }
        Scope(state: \.configuration, action: \.configuration) { ConfigurationFeature() }
        Scope(state: \.keyTest, action: \.keyTest) { KeyTestFeature() }
        Scope(state: \.firmware, action: \.firmware) { FirmwareFeature() }
        Scope(state: \.customFirmware, action: \.customFirmware) { CustomFirmwareFeature() }
        Reduce { state, action in
            switch action {
            case .keyboardUpdated(let keyboard):
                if let keyboard { state.keyboard = keyboard }
                state.isConnected = keyboard != nil
                return .merge(
                    .send(.info(.keyboardUpdated(keyboard))),
                    .send(.configuration(.keyboardUpdated(keyboard))),
                    .send(.keyTest(.keyboardUpdated(keyboard))),
                    .send(.firmware(.keyboardUpdated(keyboard))),
                    .send(.customFirmware(.keyboardUpdated(keyboard)))
                )
            case .info(.delegate(.show(let target))):
                state.section = target
                return .none
            case .binding, .info, .configuration, .keyTest, .firmware, .customFirmware:
                return .none
            }
        }
    }
}
