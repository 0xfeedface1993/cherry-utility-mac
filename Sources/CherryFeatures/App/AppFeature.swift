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
    }

    @Dependency(\.keyboardClient) var keyboardClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.menuBar, action: \.menuBar) { MenuBarFeature() }
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
                return .merge(menuBar, .send(.detail(.keyboardUpdated(state.keyboards[id: detail.keyboard.id]))))

            case .selectKeyboard(let id):
                guard id != state.selectedID, state.detail?.isBusy != true else { return .none }
                state.detail = id.flatMap { state.keyboards[id: $0] }.map(KeyboardFeature.State.init)
                return .none

            case .menuBar(.delegate(.configurationChanged(let id))):
                // Changed from the status item: screens that already show this keyboard re-read it.
                guard let detail = state.detail, detail.keyboard.id == id else { return .none }
                return .merge(
                    detail.configuration.configuration == .idle ? .none : .send(.detail(.configuration(.refresh))),
                    detail.info.vendor == .idle ? .none : .send(.detail(.info(.refresh)))
                )

            case .detail(.configuration(.delegate(.configurationChanged(let id)))):
                return .merge(
                    .send(.menuBar(.remoteConfigurationChanged(id))),
                    state.detail?.info.vendor == .idle ? .none : .send(.detail(.info(.refresh)))
                )

            case .detail, .menuBar:
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
        case info = "设备信息"
        case configuration = "灯效与配置"
        case keyTest = "按键测试"
        case firmware = "固件升级"
        public var id: String { rawValue }
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

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
            info = DeviceInfoFeature.State(keyboard: keyboard)
            configuration = ConfigurationFeature.State(keyboard: keyboard)
            keyTest = KeyTestFeature.State(keyboard: keyboard)
            firmware = FirmwareFeature.State(keyboard: keyboard)
        }

        public var isBusy: Bool { firmware.isBusy || configuration.isBusy }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case keyboardUpdated(KeyboardSummary?)
        case info(DeviceInfoFeature.Action)
        case configuration(ConfigurationFeature.Action)
        case keyTest(KeyTestFeature.Action)
        case firmware(FirmwareFeature.Action)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.info, action: \.info) { DeviceInfoFeature() }
        Scope(state: \.configuration, action: \.configuration) { ConfigurationFeature() }
        Scope(state: \.keyTest, action: \.keyTest) { KeyTestFeature() }
        Scope(state: \.firmware, action: \.firmware) { FirmwareFeature() }
        Reduce { state, action in
            switch action {
            case .keyboardUpdated(let keyboard):
                if let keyboard { state.keyboard = keyboard }
                state.isConnected = keyboard != nil
                return .merge(
                    .send(.info(.keyboardUpdated(keyboard))),
                    .send(.configuration(.keyboardUpdated(keyboard))),
                    .send(.keyTest(.keyboardUpdated(keyboard))),
                    .send(.firmware(.keyboardUpdated(keyboard)))
                )
            case .binding, .info, .configuration, .keyTest, .firmware:
                return .none
            }
        }
    }
}
