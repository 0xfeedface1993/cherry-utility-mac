import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct MenuBarFeature: Sendable {
    struct Request: Equatable, Sendable {
        let id: UUID
        let keyboardID: KeyboardID
        let intent: ConfigurationIntent
        let sequence: UInt64
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboards: IdentifiedArrayOf<KeyboardSummary> = []
        public var selectedID: KeyboardID?
        public var snapshot: Loadable<VendorSnapshot> = .idle
        public var snapshotID: KeyboardID?
        var snapshotRevision: UInt64 = 0
        var pendingConfiguration: [ConfigurationChange] = []
        var requests: [Request] = []
        var requestSequence: UInt64 = 0
        var confirmedSequence: [KeyboardID: UInt64] = [:]
        public var presets: [ProfilePreset] = []
        public var errorMessage: String?
        public var lastUpdated: Date?

        public init() {}
        public var keyboard: KeyboardSummary? { selectedID.flatMap { keyboards[id: $0] } ?? keyboards.first }
        public var model: KeyboardModel? { keyboard?.model }
        public var currentSnapshot: VendorSnapshot? { snapshotID == keyboard?.id ? snapshot.value : nil }
        public var pendingWrites: Int { requests.filter { $0.keyboardID == keyboard?.id }.count }
        public var isApplying: Bool { pendingWrites > 0 }

        /// 用户意图叠加在已校验配置上，中间读回不会使选择反跳。
        public var desiredConfiguration: KeyboardConfiguration? {
            guard let configuration = currentSnapshot?.configuration else { return nil }
            return requests.filter {
                $0.keyboardID == keyboard?.id && $0.sequence > (confirmedSequence[$0.keyboardID] ?? 0)
            }.reduce(configuration) { $1.intent.applied(to: $0) }
        }
        public var desiredSettings: ProfileSettings? { desiredConfiguration?.active.settings }
        public var canConfigure: Bool { keyboard?.canConfigure == true && currentSnapshot != nil }
        public var needsInputMonitoring: Bool { errorMessage == CherryError.accessDenied.userMessage }
    }

    public enum Action {
        case task, tick, panelAppeared, refresh
        case keyboardsUpdated([KeyboardSummary])
        case selectKeyboard(KeyboardID)
        case snapshotLoaded(KeyboardID, Result<VendorSnapshot, any Error>, revision: UInt64? = nil)
        case presetsLoaded(Result<[ProfilePreset], any Error>)
        case activateProfile(Int)
        case setEffect(UInt8)
        case setBrightness(Int)
        case setSpeed(Int)
        case setColor(LEDColor)
        case setRandomColor
        case applyPreset(ProfilePreset.ID)
        case intentFinished(UUID, KeyboardID, Result<KeyboardConfiguration, any Error>)
        case configurationSynchronized(KeyboardID, ConfigurationChange)
        case openInputMonitoringTapped
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case configurationChanged(KeyboardID, ConfigurationChange)
        }
    }

    enum CancelID { case poll, refresh }
    public static let pollInterval: Duration = .seconds(60)
    @Dependency(\.keyboardClient) var keyboardClient
    @Dependency(\.configurationClient) var configurationClient
    @Dependency(\.presetClient) var presetClient
    @Dependency(\.keyTestClient) var accessClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid
    @Dependency(\.diagnostics) var diagnostics

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    for await _ in clock.timer(interval: Self.pollInterval) {
                        try Task.checkCancellation()
                        await send(.tick)
                    }
                }.cancellable(id: CancelID.poll, cancelInFlight: true)
            case .tick: return state.isApplying ? .none : .send(.refresh)
            case .panelAppeared:
                return .merge(.send(.refresh), .run(origin: .menuBar) { send in
                    await send(.presetsLoaded(Result { try await presetClient.presets() }))
                })
            case .keyboardsUpdated(let list):
                let previous = state.keyboard
                let previousKeyboards = state.keyboards
                state.keyboards = IdentifiedArray(uniqueElements: list)
                // 断连使请求身份失效；重新插入同 ID 也不能接收旧会话结果。
                state.requests.removeAll { request in !list.contains {
                    $0.id == request.keyboardID && $0.canConfigure && $0.configurationInterfaceIDs == previousKeyboards[id: request.keyboardID]?.configurationInterfaceIDs
                } }
                if let previous {
                    state.selectedID = list.first(where: { $0.id == previous.id })?.id ?? list.first?.id
                }
                guard state.keyboard?.id != previous?.id || state.keyboard?.configurationInterfaceIDs != previous?.configurationInterfaceIDs else { return .none }
                resetSnapshot(&state)
                return .send(.refresh)
            case .selectKeyboard(let id):
                guard state.keyboards[id: id] != nil, id != state.keyboard?.id else { return .none }
                state.selectedID = id
                resetSnapshot(&state)
                return .send(.refresh)
            case .refresh:
                guard let keyboard = state.keyboard, keyboard.canConfigure else {
                    state.snapshot = .idle
                    state.snapshotID = nil
                    return .cancel(id: CancelID.refresh)
                }
                // 设备切换后仍需读取首次快照；已有快照时不与写入竞争。
                guard !state.isApplying || state.currentSnapshot == nil else { return .none }
                if state.snapshotID != keyboard.id { state.snapshot = .loading }
                let revision = state.snapshotRevision
                return .run(origin: .menuBar) { send in
                    let result = await Result { try await diagnostics.measure(.refresh) {
                        try await keyboardClient.vendorSnapshot(keyboard)
                    } }
                    guard !Task.isCancelled else { return }
                    await send(.snapshotLoaded(keyboard.id, result, revision: revision))
                }.cancellable(id: CancelID.refresh, cancelInFlight: true)
            case .snapshotLoaded(let id, let result, let revision):
                guard revision == nil || revision == state.snapshotRevision,
                      id == state.keyboard?.id, state.keyboard?.canConfigure == true else { return .none }
                switch result {
                case .success(var snapshot):
                    for change in state.pendingConfiguration { snapshot = snapshot.with(configuration: change.applied(to: snapshot.configuration)) }
                    state.pendingConfiguration = []
                    state.snapshot = .loaded(snapshot)
                    state.snapshotID = id
                    state.errorMessage = nil
                    state.lastUpdated = now
                    diagnostics.emit(.resultApplied, origin: .menuBar, outcome: .success)
                case .failure(let error):
                    state.errorMessage = error.userMessage
                    if state.snapshotID != id { state.snapshot = .failed(error.userMessage) }
                    diagnostics.emit(.resultApplied, origin: .menuBar, outcome: .failed)
                }
                return .none
            case .presetsLoaded(.success(let presets)): state.presets = presets; return .none
            case .presetsLoaded(.failure): return .none
            case .activateProfile(let profile):
                guard state.canConfigure, let model = state.model, (0..<model.profileCount).contains(profile),
                      profile != state.desiredConfiguration?.activeProfile else { return .none }
                return submit(.activate(profile), state: &state)
            case .setEffect(let value): return write(&state) { .set(\.effect, value, field: .effect, on: $0) }
            case .setBrightness(let value): return write(&state) { .set(\.brightness, value, field: .brightness, on: $0) }
            case .setSpeed(let value): return write(&state) { .set(\.speed, value, field: .speed, on: $0) }
            case .setColor(let color):
                return write(&state) { current in
                    var settings = current
                    settings.color = color
                    settings.randomColor = false
                    return ProfilePatch(settings, fields: [.color, .randomColor])
                }
            case .setRandomColor: return write(&state) { .set(\.randomColor, true, field: .randomColor, on: $0) }
            case .applyPreset(let id):
                guard let preset = state.presets.first(where: { $0.id == id }), let keyboard = state.keyboard else { return .none }
                guard preset.isCompatible(with: keyboard) else {
                    state.errorMessage = "预设「\(preset.name)」来自其他型号"
                    return .none
                }
                return write(&state) { _ in .all(preset.settings) }
            case .intentFinished(let requestID, let id, let result):
                guard let request = state.requests.first(where: { $0.id == requestID && $0.keyboardID == id }) else { return .none }
                state.requests.removeAll { $0.id == requestID }
                guard request.sequence >= (state.confirmedSequence[id] ?? 0) else { return .none }
                switch result {
                case .success(let configuration):
                    state.confirmedSequence[id] = request.sequence
                    let previous = id == state.snapshotID ? state.currentSnapshot?.configuration : nil
                    if id == state.snapshotID, let snapshot = state.currentSnapshot {
                        state.snapshotRevision &+= 1
                        state.snapshot = .loaded(snapshot.with(configuration: configuration))
                    } else if id == state.keyboard?.id, state.snapshot.isLoading {
                        state.pendingConfiguration = [.configuration(configuration)]
                    }
                    if id == state.keyboard?.id { state.errorMessage = nil }
                    return previous == configuration ? .none : .send(.delegate(.configurationChanged(id, .configuration(configuration))))
                case .failure(let error):
                    guard id == state.keyboard?.id else { return .none }
                    state.errorMessage = error.userMessage
                    return state.isApplying ? .none : .send(.refresh)
                }
            case .configurationSynchronized(let id, let change):
                guard id == state.keyboard?.id, state.keyboard?.canConfigure == true else { return .none }
                if let snapshot = state.currentSnapshot {
                    state.snapshotRevision &+= 1
                    state.snapshot = .loaded(snapshot.with(configuration: change.applied(to: snapshot.configuration)))
                    return .cancel(id: CancelID.refresh)
                }
                if state.snapshot.isLoading {
                    if case .configuration = change { state.pendingConfiguration = [change] }
                    else { state.pendingConfiguration.append(change) }
                }
                return .none
            case .openInputMonitoringTapped: return .run { _ in await accessClient.openAccessSettings() }
            case .delegate: return .none
            }
        }
    }

    private func resetSnapshot(_ state: inout State) {
        state.snapshotRevision &+= 1
        state.snapshot = .idle
        state.snapshotID = nil
        state.pendingConfiguration = []
        state.errorMessage = nil
        state.lastUpdated = nil
    }

    private func write(_ state: inout State, _ makePatch: (ProfileSettings) -> ProfilePatch) -> Effect<Action> {
        guard state.canConfigure, let configuration = state.desiredConfiguration else { return .none }
        let settings = configuration.active.settings
        let patch = makePatch(settings)
        guard !ProfileField.differences(between: settings, and: patch.applied(to: settings)).isDisjoint(with: patch.fields) else { return .none }
        return submit(.update(configuration.activeProfile, patch: patch), state: &state)
    }

    private func submit(_ intent: ConfigurationIntent, state: inout State) -> Effect<Action> {
        guard let keyboard = state.keyboard, state.canConfigure else { return .none }
        let requestID = uuid()
        state.requestSequence &+= 1
        state.requests.append(Request(id: requestID, keyboardID: keyboard.id, intent: intent, sequence: state.requestSequence))
        state.snapshotRevision &+= 1
        state.errorMessage = nil
        return .merge(.cancel(id: CancelID.refresh), .run(origin: .menuBar) { send in
            await send(.intentFinished(requestID, keyboard.id, Result { try await configurationClient.applyIntent(intent, keyboard) }))
        })
    }
}
