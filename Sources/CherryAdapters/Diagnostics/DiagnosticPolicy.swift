import CherryCore
import Foundation
import Synchronization

/// 观测策略的唯一来源：模式时长、采样、限流、保留与导出上限。运行期组件和导出 manifest 读同一份值。
public struct DiagnosticPolicyConfiguration: Sendable {
    public var journal = DiagnosticJournalLimits()
    /// 详细 / Profile 模式到期后回到标准模式。
    public var detailedDuration: Duration = .seconds(900)
    public var profileDuration: Duration = .seconds(600)
    /// 高频操作每 N 个保留一个时间线样本；所有样本仍进入直方图。
    public var detailSampleDivisor: UInt64 = 64
    /// 每分钟窗口内的时间线样本限流。
    public var tracesPerWindow = 128
    public var samplesPerTrace = 256
    /// 高频失败的独立记录上限（每操作每分钟）；聚合不受影响。
    public var failuresPerOperation = 30
    /// 单个诊断包与临时导出目录共用的容量上限，以及临时包的保留时间。
    public var exportBytes = 20 * 1024 * 1024
    public var exportRetention: TimeInterval = 86400
    public var exportTimeout: TimeInterval = 30

    public init() {}

    func duration(of mode: DiagnosticMode) -> Duration? {
        switch mode {
        case .detailed: detailedDuration
        case .profile: profileDuration
        case .standard, .off: nil
        }
    }
}

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
    /// 到期判断用单调时钟；`wallClock` 只用于给界面显示到期时刻。
    private let wallClock: @Sendable () -> Date
    let configuration: DiagnosticPolicyConfiguration

    init(mode: DiagnosticMode, clock: DiagnosticClock, configuration: DiagnosticPolicyConfiguration = .init(),
         wallClock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock; self.configuration = configuration; self.wallClock = wallClock; state = Mutex(State(mode: mode))
        set(mode)
    }

    func set(_ mode: DiagnosticMode) {
        let duration = configuration.duration(of: mode)
        let now = clock.now(), wall = wallClock()
        state.withLock {
            $0.mode = mode
            $0.expires = duration.map { wall.addingTimeInterval(Double(DiagnosticClock.nanoseconds($0)) / 1_000_000_000) }
            $0.deadline = duration.map { now &+ DiagnosticClock.nanoseconds($0) }
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
            guard $0.counter % max(1, configuration.detailSampleDivisor) == 0 else { return false }
            if let traceID {
                if $0.traceCounts.count >= configuration.tracesPerWindow && $0.traceCounts[traceID] == nil { return false }
                let count = $0.traceCounts[traceID, default: 0]
                guard count < configuration.samplesPerTrace else { return false }
                $0.traceCounts[traceID] = count + 1
            }
            return true
        }
    }

    /// 高频失败仍进入完整聚合；独立错误记录每操作每分钟受 `failuresPerOperation` 限制。
    func includesFailure(_ operation: DiagnosticOperation) -> Bool {
        let window = clock.now() / 60_000_000_000
        return state.withLock {
            if $0.window != window { $0.window = window; $0.failureCounts.removeAll(); $0.traceCounts.removeAll() }
            let count = $0.failureCounts[operation, default: 0]
            guard count < configuration.failuresPerOperation else { return false }
            $0.failureCounts[operation] = count + 1
            return true
        }
    }
}
