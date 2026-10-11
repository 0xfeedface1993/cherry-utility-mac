import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct DiagnosticsFeature: Sendable {
    public enum Phase: Equatable, Sendable { case idle, exporting, ready, saving, saved, failed, cancelled }
    @ObservableState
    public struct State: Equatable {
        public var status = DiagnosticStatus()
        public var range: DiagnosticRange = .recent
        public var phase: Phase = .idle
        public var artifact: DiagnosticExport?
        public var error: String?
        public var requestID: UUID?
        public init() {}
        public var isBusy: Bool { phase == .exporting || phase == .saving }
    }
    public enum Action {
        case task, refreshStatus, dismissed, cancelTapped, exportTapped, saveTapped
        case modeChanged(DiagnosticMode), rangeChanged(DiagnosticRange)
        case exportFinished(UUID, Result<DiagnosticExport, DiagnosticExportError>)
        case saveFinished(UUID, Result<Bool, DiagnosticExportError>)
    }
    private enum CancelID { case status, work }
    @Dependency(\.diagnosticsClient) var client
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid

    public init() {}
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.status = client.status()
                return .run { send in
                    for await _ in clock.timer(interval: .seconds(1)) { await send(.refreshStatus) }
                }.cancellable(id: CancelID.status, cancelInFlight: true)
            case .refreshStatus:
                state.status = client.status(); return .none
            case .modeChanged(let mode):
                client.setMode(mode); state.status = client.status(); return .none
            case .rangeChanged(let range):
                guard !state.isBusy else { return .none }
                state.range = range; return .none
            case .exportTapped:
                guard !state.isBusy else { return .none }
                if let artifact = state.artifact { client.discard(artifact) }
                state.artifact = nil; state.error = nil; state.phase = .exporting
                let id = uuid(), range = state.range
                state.requestID = id
                return .run { send in
                    do { await send(.exportFinished(id, .success(try await client.export(range)))) }
                    catch is CancellationError { /* 取消状态由发起动作设置，避免向已取消 Effect 发送结果。 */ }
                    catch { await send(.exportFinished(id, .failure(error as? DiagnosticExportError ?? .storage))) }
                }.cancellable(id: CancelID.work, cancelInFlight: true)
            case .exportFinished(let id, let result):
                guard state.requestID == id, state.phase == .exporting else {
                    if case .success(let artifact) = result { client.discard(artifact) }
                    return .none
                }
                switch result {
                case .success(let artifact): state.artifact = artifact; state.phase = .ready
                case .failure(let error): state.error = error.message; state.phase = .failed
                }
                state.status = client.status(); return .none
            case .saveTapped:
                guard state.phase == .ready, let artifact = state.artifact else { return .none }
                let id = uuid(); state.requestID = id; state.phase = .saving
                return .run { send in
                    do { await send(.saveFinished(id, .success(try await client.save(artifact)))) }
                    catch is CancellationError { }
                    catch { await send(.saveFinished(id, .failure(error as? DiagnosticExportError ?? .storage))) }
                }.cancellable(id: CancelID.work, cancelInFlight: true)
            case .saveFinished(let id, let result):
                guard state.requestID == id, state.phase == .saving else { return .none }
                switch result {
                case .success(true):
                    if let artifact = state.artifact { client.discard(artifact) }
                    state.artifact = nil; state.phase = .saved
                case .success(false): state.phase = .ready
                case .failure(let error): state.error = error.message; state.phase = .ready
                }
                return .none
            case .cancelTapped, .dismissed:
                state.requestID = nil
                if let artifact = state.artifact { client.discard(artifact) }
                state.artifact = nil; state.phase = .cancelled; state.error = nil
                return .merge(.cancel(id: CancelID.work), action.isDismissed ? .cancel(id: CancelID.status) : .none)
            }
        }
    }
}

private extension DiagnosticsFeature.Action {
    var isDismissed: Bool { if case .dismissed = self { true } else { false } }
}
