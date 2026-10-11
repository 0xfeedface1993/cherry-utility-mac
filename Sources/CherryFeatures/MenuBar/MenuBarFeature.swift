import CherryCore
import ComposableArchitecture
import Foundation

/// Status-item panel: battery / device / mode / lighting at a glance, plus quick lighting and profile changes
/// applied straight to the active profile.
@Reducer
public struct MenuBarFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        public var keyboards: IdentifiedArrayOf<KeyboardSummary> = []
        public var selectedID: KeyboardID?
        public var snapshot: Loadable<VendorSnapshot> = .idle
        /// Keyboard the snapshot belongs to.
        public var snapshotID: KeyboardID?
        public var presets: [ProfilePreset] = []
        /// Number of writes still running (writes are queued, never cancelled half-way).
        public var pendingWrites = 0
        public var errorMessage: String?
        public var lastUpdated: Date?

        public init() {}

        public var keyboard: KeyboardSummary? {
            selectedID.flatMap { keyboards[id: $0] } ?? keyboards.first
        }

        public var model: KeyboardModel? { keyboard?.model }

        /// Snapshot of the current keyboard only (a stale one from another keyboard is never shown).
        public var currentSnapshot: VendorSnapshot? {
            snapshotID == keyboard?.id ? snapshot.value : nil
        }

        public var isApplying: Bool { pendingWrites > 0 }
        public var needsInputMonitoring: Bool { errorMessage == CherryError.accessDenied.userMessage }
    }

    public enum Action {
        case task
        case tick
        case panelAppeared
        case keyboardsUpdated([KeyboardSummary])
        case selectKeyboard(KeyboardID)
        case refresh
        case snapshotLoaded(KeyboardID, Result<VendorSnapshot, any Error>)
        case presetsLoaded(Result<[ProfilePreset], any Error>)
        case activateProfile(Int)
        case activationFinished(KeyboardID, Result<KeyboardConfiguration, any Error>)
        case setEffect(UInt8)
        case setBrightness(Int)
        case setSpeed(Int)
        case setColor(LEDColor)
        case setRandomColor
        case applyPreset(ProfilePreset.ID)
        case writeFinished(KeyboardID, Result<ProfileConfig, any Error>)
        case remoteConfigurationChanged(KeyboardID)
        case openInputMonitoringTapped
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case configurationChanged(KeyboardID)
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

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // Background status poll for the status-item label; lives as long as the app's store.
                return .run { send in
                    for await _ in clock.timer(interval: Self.pollInterval) {
                        try Task.checkCancellation()
                        await send(.tick)
                    }
                }
                .cancellable(id: CancelID.poll, cancelInFlight: true)

            case .tick:
                return state.isApplying ? .none : .send(.refresh)

            case .panelAppeared:
                return .merge(
                    .send(.refresh),
                    .run { send in await send(.presetsLoaded(Result { try await presetClient.presets() })) }
                )

            case .keyboardsUpdated(let list):
                let previous = state.keyboard?.id
                state.keyboards = IdentifiedArray(uniqueElements: list)
                if let id = state.selectedID, state.keyboards[id: id] == nil { state.selectedID = nil }
                guard state.keyboard?.id != previous else { return .none }
                state.errorMessage = nil
                return .send(.refresh)

            case .selectKeyboard(let id):
                guard state.keyboards[id: id] != nil, id != state.keyboard?.id else { return .none }
                state.selectedID = id
                state.errorMessage = nil
                return .send(.refresh)

            case .refresh:
                guard let keyboard = state.keyboard, keyboard.model != nil else {
                    state.snapshot = .idle
                    state.snapshotID = nil
                    return .cancel(id: CancelID.refresh)
                }
                if state.snapshotID != keyboard.id { state.snapshot = .loading }
                return .run { send in
                    await send(.snapshotLoaded(keyboard.id, Result { try await keyboardClient.vendorSnapshot(keyboard) }))
                }
                .cancellable(id: CancelID.refresh, cancelInFlight: true)

            case .snapshotLoaded(let id, .success(let snapshot)):
                guard id == state.keyboard?.id else { return .none }
                state.snapshot = .loaded(snapshot)
                state.snapshotID = id
                state.errorMessage = nil
                state.lastUpdated = now
                return .none

            case .snapshotLoaded(let id, .failure(let error)):
                guard id == state.keyboard?.id else { return .none }
                state.errorMessage = error.userMessage
                if state.snapshotID != id { state.snapshot = .failed(error.userMessage) }
                return .none

            case .presetsLoaded(.success(let presets)):
                state.presets = presets
                return .none

            case .presetsLoaded(.failure):
                return .none

            case .activateProfile(let n):
                guard let keyboard = state.keyboard, let snapshot = state.currentSnapshot,
                      state.pendingWrites > 0 || n != snapshot.configuration.activeProfile else { return .none }
                state.pendingWrites += 1
                return .run { send in
                    await send(.activationFinished(keyboard.id, Result { try await configurationClient.activateProfile(n, keyboard) }))
                }

            case .activationFinished(let id, let result):
                state.pendingWrites = max(0, state.pendingWrites - 1)
                switch result {
                case .success(let configuration):
                    if id == state.snapshotID, let snapshot = state.currentSnapshot {
                        state.snapshot = .loaded(snapshot.with(configuration: configuration))
                    }
                    if id == state.keyboard?.id { state.errorMessage = nil }
                    return .send(.delegate(.configurationChanged(id)))
                case .failure(let error):
                    guard id == state.keyboard?.id else { return .none }
                    state.errorMessage = error.userMessage
                    return .send(.refresh)
                }

            case .setEffect(let v):
                return write(&state) { .set(\.effect, v, field: .effect, on: $0) }

            case .setBrightness(let v):
                return write(&state) { .set(\.brightness, v, field: .brightness, on: $0) }

            case .setSpeed(let v):
                return write(&state) { .set(\.speed, v, field: .speed, on: $0) }

            case .setColor(let color):
                return write(&state) { current in
                    var s = current
                    s.color = color
                    s.randomColor = false
                    return ProfilePatch(s, fields: [.color, .randomColor])
                }

            case .setRandomColor:
                return write(&state) { .set(\.randomColor, true, field: .randomColor, on: $0) }

            case .applyPreset(let id):
                guard let preset = state.presets.first(where: { $0.id == id }) else { return .none }
                guard let keyboard = state.keyboard, preset.isCompatible(with: keyboard) else {
                    state.errorMessage = "预设「\(preset.name)」来自其他型号"
                    return .none
                }
                return write(&state) { _ in .all(preset.settings) }

            case .writeFinished(let id, let result):
                state.pendingWrites = max(0, state.pendingWrites - 1)
                switch result {
                case .success(let saved):
                    if id == state.snapshotID, let snapshot = state.currentSnapshot {
                        state.snapshot = .loaded(snapshot.with(configuration: snapshot.configuration.replacing(saved)))
                    }
                    if id == state.keyboard?.id { state.errorMessage = nil }
                    return .send(.delegate(.configurationChanged(id)))
                case .failure(let error):
                    guard id == state.keyboard?.id else { return .none }
                    state.errorMessage = error.userMessage
                    return .send(.refresh)
                }

            case .remoteConfigurationChanged(let id):
                return id == state.keyboard?.id ? .send(.refresh) : .none

            case .openInputMonitoringTapped:
                return .run { _ in await accessClient.openAccessSettings() }

            case .delegate:
                return .none
            }
        }
    }

    /// Writes a patch derived from the active profile's current settings to the active profile.
    private func write(_ state: inout State, _ makePatch: (ProfileSettings) -> ProfilePatch) -> Effect<Action> {
        guard let keyboard = state.keyboard, let snapshot = state.currentSnapshot else { return .none }
        let active = snapshot.configuration.active
        let patch = makePatch(active.settings)
        let changes = ProfileField.differences(between: active.settings, and: patch.applied(to: active.settings))
        // 有写入排队时，快照仍是旧值；改回旧值也必须排队，否则会丢失最后一次操作。
        guard state.pendingWrites > 0 || !changes.isDisjoint(with: patch.fields) else { return .none }
        state.pendingWrites += 1
        let n = active.profile
        return .run { send in
            await send(.writeFinished(keyboard.id, Result { try await configurationClient.updateProfile(n, keyboard, patch) }))
        }
    }
}
