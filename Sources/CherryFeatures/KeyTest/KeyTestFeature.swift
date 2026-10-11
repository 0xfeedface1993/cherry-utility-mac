import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct KeyTestFeature: Sendable {
    public struct LoggedEvent: Equatable, Identifiable, Sendable {
        public let id: Int
        public let usage: HIDUsage
        public let label: String
        public let isDown: Bool
        /// Milliseconds since the previous event.
        public let deltaMs: Double?
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboard: KeyboardSummary
        public var isConnected = true
        public var layout: KeyboardLayout?
        public var access: InputMonitoringStatus = .undetermined
        public var isCapturing = false
        public var captureError: String?
        public var suppressAppShortcuts = true
        public var pressed: Set<HIDUsage> = []
        public var tested: Set<HIDUsage> = []
        public var maxSimultaneous = 0
        public var eventCount = 0
        public var log: [LoggedEvent] = []
        var lastTimestamp: UInt64?

        public static let logLimit = 40

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
            self.layout = keyboard.model?.layout
        }

        public var testableCount: Int { layout?.testableKeys.count ?? 0 }

        public var testedLayoutCount: Int {
            guard let layout else { return 0 }
            return layout.testableKeys.filter { tested.contains($0.usage!) }.count
        }

        public func label(for usage: HIDUsage) -> String {
            if let key = layout?.key(for: usage), !key.label.isEmpty { return key.label }
            if usage == .keyboard(0x2C) { return "Space" }
            return usage.description
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case viewDisappeared
        case accessChecked(InputMonitoringStatus)
        case requestAccessTapped
        case accessResponse(Bool)
        case openSettingsTapped
        case startCapture
        case keyEvent(KeyEvent)
        case captureEnded(String?)
        case resetTapped
        case keyboardUpdated(KeyboardSummary?)
    }

    enum CancelID { case capture, suppress }

    @Dependency(\.keyTestClient) var client
    @Dependency(\.diagnostics) var diagnostics

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                return .send(.accessChecked(client.accessStatus()))

            case .viewDisappeared:
                state.isCapturing = false
                state.pressed.removeAll()
                return .merge(.cancel(id: CancelID.capture), .cancel(id: CancelID.suppress))

            case .accessChecked(let status):
                state.access = status
                return status == .granted ? .send(.startCapture) : .none

            case .requestAccessTapped:
                return .run { send in await send(.accessResponse(await client.requestAccess())) }

            case .accessResponse:
                return .send(.accessChecked(client.accessStatus()))

            case .openSettingsTapped:
                return .run { _ in await client.openAccessSettings() }

            case .startCapture:
                guard state.isConnected, state.access == .granted else { return .none }
                state.isCapturing = true
                state.captureError = nil
                let id = state.keyboard.id
                return .merge(
                    .run { send in
                        let diagnostics = diagnostics
                        for try await event in client.keyEvents(id) {
                            try Task.checkCancellation()
                            if let stamp = event.diagnosticTimestampNs {
                                let now = diagnostics.now()
                                diagnostics.emit(.keyDispatch, context: event.diagnosticContext, origin: .keytest,
                                                 metrics: .init(durationNs: now >= stamp ? now - stamp : 0))
                            }
                            await send(.keyEvent(event))
                        }
                        await send(.captureEnded(nil))
                    } catch: { error, send in
                        // TCA does not route CancellationError here: a capture stopped by the view just ends.
                        await send(.captureEnded(error.userMessage))
                    }
                    .cancellable(id: CancelID.capture, cancelInFlight: true),
                    suppression(enabled: state.suppressAppShortcuts)
                )

            case .keyEvent(let event):
                state.eventCount += 1
                if event.isDown {
                    state.pressed.insert(event.usage)
                    state.tested.insert(event.usage)
                    state.maxSimultaneous = max(state.maxSimultaneous, state.pressed.count)
                } else {
                    state.pressed.remove(event.usage)
                }
                let delta = state.lastTimestamp.map { Double(event.timestamp &- $0) / 1_000_000 }
                state.lastTimestamp = event.timestamp
                state.log.insert(
                    LoggedEvent(id: state.eventCount, usage: event.usage, label: state.label(for: event.usage), isDown: event.isDown, deltaMs: delta),
                    at: 0
                )
                if state.log.count > State.logLimit { state.log.removeLast(state.log.count - State.logLimit) }
                if let stamp = event.diagnosticTimestampNs {
                    let diagnostics = diagnostics
                    let now = diagnostics.now()
                    diagnostics.emit(.keyPipeline, context: event.diagnosticContext, origin: .keytest,
                                     metrics: .init(durationNs: now >= stamp ? now - stamp : 0))
                }
                return .none

            case .captureEnded(let message):
                state.isCapturing = false
                state.pressed.removeAll()
                state.captureError = message
                return .cancel(id: CancelID.suppress)

            case .resetTapped:
                state.pressed.removeAll()
                state.tested.removeAll()
                state.maxSimultaneous = 0
                state.eventCount = 0
                state.log.removeAll()
                state.lastTimestamp = nil
                return .none

            case .keyboardUpdated(let keyboard):
                let wasConnected = state.isConnected
                state.isConnected = keyboard != nil
                if let keyboard { state.keyboard = keyboard }
                // Capture ends by itself on disconnect (the event stream finishes); resume on reconnect.
                return !wasConnected && state.isConnected && state.access == .granted ? .send(.startCapture) : .none

            case .binding(\.suppressAppShortcuts):
                return state.isCapturing ? suppression(enabled: state.suppressAppShortcuts) : .none

            case .binding:
                return .none
            }
        }
    }

    private func suppression(enabled: Bool) -> Effect<Action> {
        guard enabled else { return .cancel(id: CancelID.suppress) }
        return .run { _ in await client.suppressAppKeyEvents() }
            .cancellable(id: CancelID.suppress, cancelInFlight: true)
    }
}
