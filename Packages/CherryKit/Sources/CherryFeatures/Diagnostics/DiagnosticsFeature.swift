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
        case task, dismissed, cancelTapped, exportTapped, saveTapped
        case modeChanged(DiagnosticMode), rangeChanged(DiagnosticRange)
        case statusLoaded(DiagnosticStatus)
        case exportFinished(UUID, Result<DiagnosticExport, DiagnosticExportError>)
        case saveFinished(UUID, Result<Bool, DiagnosticExportError>)
    }
    private enum CancelID { case status, work }
    @Dependency(\.diagnosticsClient) var client
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid

    public init() {}
    /// reducer 只改状态；读取状态、切换模式和删除临时包都在 effect 中执行。
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    await send(.statusLoaded(client.status()))
                    for await _ in clock.timer(interval: .seconds(1)) { await send(.statusLoaded(client.status())) }
                }.cancellable(id: CancelID.status, cancelInFlight: true)
            case .statusLoaded(let status):
                state.status = status; return .none
            case .modeChanged(let mode):
                // 先显示用户的选择；到期时间等由 effect 读回的状态补齐。
                state.status.mode = mode
                return .run(origin: .app) { send in
                    client.setMode(mode)
                    await send(.statusLoaded(client.status()))
                }
            case .rangeChanged(let range):
                guard !state.isBusy else { return .none }
                state.range = range; return .none
            case .exportTapped:
                guard !state.isBusy else { return .none }
                let previous = state.artifact
                state.artifact = nil; state.error = nil; state.phase = .exporting
                let id = uuid(), range = state.range
                state.requestID = id
                return .merge(
                    discard(previous),
                    .run { send in
                        do { await send(.exportFinished(id, .success(try await client.export(range)))) }
                        catch is CancellationError { /* 取消状态由发起动作设置，避免向已取消 Effect 发送结果。 */ }
                        catch { await send(.exportFinished(id, .failure(error as? DiagnosticExportError ?? .storage))) }
                    }.cancellable(id: CancelID.work, cancelInFlight: true)
                )
            case .exportFinished(let id, let result):
                guard state.requestID == id, state.phase == .exporting else {
                    // 晚到的成功结果不再展示，只删除它生成的临时包。
                    if case .success(let artifact) = result { return discard(artifact) }
                    return .none
                }
                switch result {
                case .success(let artifact): state.artifact = artifact; state.phase = .ready
                case .failure(let error): state.error = error.message; state.phase = .failed
                }
                return .run { send in await send(.statusLoaded(client.status())) }
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
                    let saved = state.artifact
                    state.artifact = nil; state.phase = .saved
                    return discard(saved)
                case .success(false): state.phase = .ready
                case .failure(let error): state.error = error.message; state.phase = .ready
                }
                return .none
            case .cancelTapped, .dismissed:
                let artifact = state.artifact
                state.requestID = nil
                state.artifact = nil; state.phase = .cancelled; state.error = nil
                return .merge(discard(artifact), .cancel(id: CancelID.work), action.isDismissed ? .cancel(id: CancelID.status) : .none)
            }
        }
    }

    private func discard(_ artifact: DiagnosticExport?) -> Effect<Action> {
        guard let artifact else { return .none }
        return .run { _ in client.discard(artifact) }
    }
}

private extension DiagnosticsFeature.Action {
    var isDismissed: Bool { if case .dismissed = self { true } else { false } }
}
