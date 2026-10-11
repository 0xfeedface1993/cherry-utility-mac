import CherryCore
import ComposableArchitecture
import Foundation

/// Status-item panel: battery / device / mode / lighting at a glance, plus quick lighting and profile changes
/// applied straight to the active profile.
@Reducer
public struct MenuBarFeature: Sendable {
    enum PendingWrite: Equatable, Sendable {
        case patch(KeyboardSummary, Int, ProfilePatch)
        case activate(KeyboardSummary, Int)
        var keyboardID: KeyboardID {
            switch self { case .patch(let keyboard, _, _), .activate(let keyboard, _): keyboard.id }
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboards: IdentifiedArrayOf<KeyboardSummary> = []
        public var selectedID: KeyboardID?
        public var snapshot: Loadable<VendorSnapshot> = .idle
        /// Keyboard the snapshot belongs to.
        public var snapshotID: KeyboardID?
        var snapshotRevision: UInt64 = 0
        var pendingConfiguration: [ConfigurationChange] = []
        public var presets: [ProfilePreset] = []
        /// Number of writes still running (writes are queued, never cancelled half-way).
        public var pendingWrites = 0
        var inFlightWrite: PendingWrite?
        var queuedWrite: PendingWrite?
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
        public var isActivating: Bool {
            if case .activate = inFlightWrite { return true }
            if case .activate = queuedWrite { return true }
            return false
        }
        public var desiredSettings: ProfileSettings? {
            guard let snapshot = currentSnapshot else { return nil }
            var settings = snapshot.configuration.active.settings
            for request in [inFlightWrite, queuedWrite] {
                if case .patch(let keyboard, let profile, let patch) = request,
                   keyboard.id == self.keyboard?.id, profile == snapshot.configuration.activeProfile {
                    settings = patch.applied(to: settings)
                }
            }
            return settings
        }
        public var needsInputMonitoring: Bool { errorMessage == CherryError.accessDenied.userMessage }
    }

    public enum Action {
        case task
        case tick
        case panelAppeared
        case keyboardsUpdated([KeyboardSummary])
        case selectKeyboard(KeyboardID)
        case refresh
        case snapshotLoaded(KeyboardID, Result<VendorSnapshot, any Error>, revision: UInt64? = nil)
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
    @Dependency(\.diagnostics) var diagnostics

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
                discardQueuedWrite(&state)
                state.snapshotRevision &+= 1
                state.pendingConfiguration = []
                return .send(.refresh)

            case .selectKeyboard(let id):
                guard state.keyboards[id: id] != nil, id != state.keyboard?.id else { return .none }
                state.selectedID = id
                state.errorMessage = nil
                discardQueuedWrite(&state)
                state.snapshotRevision &+= 1
                state.pendingConfiguration = []
                return .send(.refresh)

            case .refresh:
                guard let keyboard = state.keyboard, keyboard.model != nil else {
                    state.snapshot = .idle
                    state.snapshotID = nil
                    return .cancel(id: CancelID.refresh)
                }
                if state.snapshotID != keyboard.id {
                    if !state.snapshot.isLoading { state.pendingConfiguration = [] }
                    state.snapshot = .loading
                }
                let revision = state.snapshotRevision
                return .run { send in
                    let result = await Result { try await diagnostics.measure(.refresh, origin: .menuBar) {
                        try await keyboardClient.vendorSnapshot(keyboard)
                    } }
                    guard !Task.isCancelled else { return }
                    await send(.snapshotLoaded(keyboard.id, result, revision: revision))
                }
                .cancellable(id: CancelID.refresh, cancelInFlight: true)

            case .snapshotLoaded(let id, .success(var snapshot), let revision):
                guard revision == nil || revision == state.snapshotRevision else { return .none }
                guard id == state.keyboard?.id else { diagnostics.emit(.resultIgnored, origin: .menuBar, outcome: .ignored); return .none }
                diagnostics.emit(.resultApplied, origin: .menuBar, outcome: .success)
                for change in state.pendingConfiguration {
                    snapshot = snapshot.with(configuration: change.applied(to: snapshot.configuration))
                }
                state.pendingConfiguration = []
                state.snapshot = .loaded(snapshot)
                state.snapshotID = id
                state.errorMessage = nil
                state.lastUpdated = now
                return .none

            case .snapshotLoaded(let id, .failure(let error), let revision):
                guard revision == nil || revision == state.snapshotRevision else { return .none }
                guard id == state.keyboard?.id else { diagnostics.emit(.resultIgnored, origin: .menuBar, outcome: .ignored); return .none }
                diagnostics.emit(.resultApplied, origin: .menuBar, outcome: .failed)
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
                if case .patch = state.inFlightWrite { return .none }
                let request = PendingWrite.activate(keyboard, n)
                if state.inFlightWrite != nil {
                    if state.queuedWrite == nil { state.pendingWrites += 1 }
                    state.queuedWrite = request
                    return .none
                }
                state.pendingWrites += 1
                state.inFlightWrite = request
                return execute(request)

            case .activationFinished(let id, let result):
                state.pendingWrites = max(0, state.pendingWrites - 1)
                state.inFlightWrite = nil
                let next = startQueuedWrite(&state)
                switch result {
                case .success(let configuration):
                    let previous = id == state.snapshotID ? state.currentSnapshot?.configuration : nil
                    if id == state.snapshotID, let snapshot = state.currentSnapshot {
                        state.snapshotRevision &+= 1
                        state.snapshot = .loaded(snapshot.with(configuration: configuration))
                    }
                    if id == state.keyboard?.id { state.errorMessage = nil }
                    return .merge(next, previous == configuration ? .none : .send(.delegate(.configurationChanged(id, .configuration(configuration)))))
                case .failure(let error):
                    guard id == state.keyboard?.id else { return next }
                    state.errorMessage = error.userMessage
                    return .merge(next, state.isApplying ? .none : .send(.refresh))
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
                state.inFlightWrite = nil
                let next = startQueuedWrite(&state)
                switch result {
                case .success(let saved):
                    let previous = id == state.snapshotID ? state.currentSnapshot?.configuration.profile(saved.profile) : nil
                    if id == state.snapshotID, let snapshot = state.currentSnapshot {
                        state.snapshotRevision &+= 1
                        state.snapshot = .loaded(snapshot.with(configuration: snapshot.configuration.replacing(saved)))
                    }
                    if id == state.keyboard?.id { state.errorMessage = nil }
                    return .merge(next, previous == saved ? .none : .send(.delegate(.configurationChanged(id, .profile(saved)))))
                case .failure(let error):
                    guard id == state.keyboard?.id else { return next }
                    state.errorMessage = error.userMessage
                    return .merge(next, state.isApplying ? .none : .send(.refresh))
                }

            case .configurationSynchronized(let id, let change):
                guard id == state.keyboard?.id else { return .none }
                if let snapshot = state.currentSnapshot {
                    state.snapshotRevision &+= 1
                    state.snapshot = .loaded(snapshot.with(configuration: change.applied(to: snapshot.configuration)))
                    return .cancel(id: CancelID.refresh)
                }
                if state.snapshot.isLoading {
                    if case .configuration = change { state.pendingConfiguration = [change] }
                    else {
                        if case .profile(let profile) = change {
                            state.pendingConfiguration.removeAll {
                                if case .profile(let previous) = $0 { return previous.profile == profile.profile }
                                return false
                            }
                        }
                        state.pendingConfiguration.append(change)
                    }
                }
                return .none

            case .openInputMonitoringTapped:
                return .run { _ in await accessClient.openAccessSettings() }

            case .delegate:
                return .none
            }
        }
    }

    /// 一个执行中事务 + 一个尚未执行的意图；只合并后者，不取消事务。
    private func write(_ state: inout State, _ makePatch: (ProfileSettings) -> ProfilePatch) -> Effect<Action> {
        guard let keyboard = state.keyboard, let snapshot = state.currentSnapshot,
              let settings = state.desiredSettings, !state.isActivating else { return .none }
        let patch = makePatch(settings)
        let changes = ProfileField.differences(between: settings, and: patch.applied(to: settings))
        guard !changes.isDisjoint(with: patch.fields) else { return .none }
        let n = snapshot.configuration.activeProfile
        if state.inFlightWrite != nil {
            if case .patch(let queuedKeyboard, let profile, let queued) = state.queuedWrite,
               queuedKeyboard.id == keyboard.id, profile == n {
                state.queuedWrite = .patch(keyboard, n, queued.merging(patch))
            } else {
                if state.queuedWrite == nil { state.pendingWrites += 1 }
                state.queuedWrite = .patch(keyboard, n, patch)
            }
            return .none
        }
        let request = PendingWrite.patch(keyboard, n, patch)
        state.pendingWrites += 1
        state.inFlightWrite = request
        return execute(request)
    }

    private func execute(_ request: PendingWrite) -> Effect<Action> {
        switch request {
        case .patch(let keyboard, let n, let patch):
            return .run { send in
                await send(.writeFinished(keyboard.id, Result { try await configurationClient.updateProfile(n, keyboard, patch) }))
            }
        case .activate(let keyboard, let n):
            return .run { send in
                await send(.activationFinished(keyboard.id, Result { try await configurationClient.activateProfile(n, keyboard) }))
            }
        }
    }

    private func startQueuedWrite(_ state: inout State) -> Effect<Action> {
        guard let request = state.queuedWrite else { return .none }
        state.queuedWrite = nil
        guard request.keyboardID == state.keyboard?.id else {
            state.pendingWrites = max(0, state.pendingWrites - 1)
            return .none
        }
        state.inFlightWrite = request
        return execute(request)
    }

    private func discardQueuedWrite(_ state: inout State) {
        if state.queuedWrite != nil { state.pendingWrites = max(0, state.pendingWrites - 1) }
        state.queuedWrite = nil
    }
}
