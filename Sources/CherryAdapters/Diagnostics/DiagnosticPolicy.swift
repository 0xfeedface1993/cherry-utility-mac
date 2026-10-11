import CherryCore
import Foundation
import Synchronization

final class DiagnosticPolicy: Sendable {
    private struct State {
        var mode: DiagnosticMode
        var expires: Date?
        var deadline: UInt64?
        var counter: UInt64 = 0
        var traceCounts: [UUID: Int] = [:]
        var failureCounts: [DiagnosticOperation: Int] = [:]
        var window: UInt64 = 0
    }
    private let state: Mutex<State>
    private let clock: DiagnosticClock

    init(mode: DiagnosticMode, clock: DiagnosticClock) {
        self.clock = clock; state = Mutex(State(mode: mode))
        set(mode)
    }

    func set(_ mode: DiagnosticMode) {
        let seconds: UInt64? = mode == .detailed ? 900 : mode == .profile ? 600 : nil
        let now = clock.now()
        state.withLock {
            $0.mode = mode
            $0.expires = seconds.map { Date().addingTimeInterval(Double($0)) }
            $0.deadline = seconds.map { now &+ $0 * 1_000_000_000 }
        }
    }

    var status: (DiagnosticMode, Date?) {
        let now = clock.now()
        return state.withLock {
            if let deadline = $0.deadline, now >= deadline {
                $0.mode = .standard; $0.deadline = nil; $0.expires = nil
            }
            return ($0.mode, $0.expires)
        }
    }

    func includes(_ operation: DiagnosticOperation, traceID: UUID? = nil) -> Bool {
        let mode = status.0
        guard mode != .off else { return false }
        guard operation.isDetail else { return true }
        guard mode != .standard else { return false }
        let window = clock.now() / 60_000_000_000
        return state.withLock {
            if $0.window != window { $0.window = window; $0.failureCounts.removeAll(); $0.traceCounts.removeAll() }
            $0.counter &+= 1
            guard $0.counter % 64 == 0 else { return false }
            if let traceID {
                if $0.traceCounts.count >= 128 && $0.traceCounts[traceID] == nil { return false }
                let count = $0.traceCounts[traceID, default: 0]
                guard count < 256 else { return false }
                $0.traceCounts[traceID] = count + 1
            }
            return true
        }
    }

    /// 高频失败仍进入完整聚合；独立错误记录每操作每分钟最多 30 条。
    func includesFailure(_ operation: DiagnosticOperation) -> Bool {
        let window = clock.now() / 60_000_000_000
        return state.withLock {
            if $0.window != window { $0.window = window; $0.failureCounts.removeAll(); $0.traceCounts.removeAll() }
            let count = $0.failureCounts[operation, default: 0]
            guard count < 30 else { return false }
            $0.failureCounts[operation] = count + 1
            return true
        }
    }
}
