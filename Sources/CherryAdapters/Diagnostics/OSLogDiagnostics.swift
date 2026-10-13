import CherryCore
import Foundation
import os
import Synchronization

/// 固定 Logger 与 signposter；文件 sink 只接收同一份白名单事件。
public final class OSLogDiagnostics: Sendable {
    public static let subsystem = "online.odeployer.CherryUtility"
    private let clock: DiagnosticClock
    private let wallClock: @Sendable () -> Date
    private let outputs: [String: Output]
    private let sink: @Sendable (DiagnosticEvent) -> Void
    private let journal: DiagnosticJournal?
    private let policy: DiagnosticPolicy
    private let aggregates = DiagnosticAggregates()
    private let sequence = Mutex<UInt64>(0)
    private let runID = UUID()

    private struct Output: Sendable {
        let logger: Logger
        let signposter: OSSignposter
    }

    public init(mode: DiagnosticMode = .standard, clock: DiagnosticClock = .continuous(), journal: DiagnosticJournal? = nil,
                configuration: DiagnosticPolicyConfiguration = .init(), wallClock: @escaping @Sendable () -> Date = Date.init,
                sink: @escaping @Sendable (DiagnosticEvent) -> Void = { _ in }) {
        self.clock = clock; self.sink = sink; self.journal = journal; self.wallClock = wallClock
        policy = DiagnosticPolicy(mode: mode, clock: clock, configuration: configuration, wallClock: wallClock)
        outputs = Dictionary(uniqueKeysWithValues: Set(DiagnosticOperation.allCases.map(\.category)).map {
            let logger = Logger(subsystem: Self.subsystem, category: $0)
            // 通用 Points of Interest 模板可直接捕获；日志仍按业务 category 分组。
            return ($0, Output(logger: logger, signposter: OSSignposter(subsystem: Self.subsystem, category: .pointsOfInterest)))
        })
    }

    public var port: Diagnostics {
        Diagnostics(isEnabled: { [self] in policy.status.0 != .off }, now: clock.now, begin: { [self] operation, parent, origin, metrics in
            let included = policy.includes(operation, traceID: parent?.traceID)
            if !included {
                let start = clock.now()
                return DiagnosticSpan(context: parent) { [self] outcome, failure, _ in
                    let now = clock.now(), duration = now >= start ? now - start : 0
                    if let event = aggregates.add(operation, duration: duration, context: parent, origin: origin, outcome: outcome, now: now) { publish(event) }
                    if let failure, policy.includesFailure(operation) {
                        publish(.init(operation: operation, phase: .summary, context: TraceContext(parent: parent, origin: origin),
                                      outcome: outcome, failure: failure, metrics: .init(durationNs: duration), elapsedNs: now))
                    }
                }
            }
            let context = TraceContext(parent: parent, origin: origin)
            let start = clock.now()
            let output = outputs[operation.category]!
            let interval = output.signposter.isEnabled
                ? output.signposter.beginInterval(operation.signpostName, id: output.signposter.makeSignpostID(),
                    "trace=\(context.traceID.uuidString, privacy: .public) span=\(context.spanID.uuidString, privacy: .public)") : nil
            publish(.init(operation: operation, phase: .began, context: context, metrics: metrics, elapsedNs: start))
            return DiagnosticSpan(context: context) { [self] outcome, failure, final in
                if let interval { output.signposter.endInterval(operation.signpostName, interval, "outcome=\(outcome.rawValue, privacy: .public)") }
                let now = clock.now()
                var combined = final
                combined.durationNs = now >= start ? now - start : 0
                combined.sampleDivisor = operation.isDetail ? max(1, policy.configuration.detailSampleDivisor) : 1
                if operation.isDetail, let event = aggregates.add(operation, duration: combined.durationNs ?? 0, context: context,
                                                                   origin: origin, outcome: outcome, now: now) { publish(event) }
                publish(.init(operation: operation, phase: .finished, context: context, outcome: outcome,
                              failure: failure, metrics: combined, elapsedNs: now))
            }
        }, emit: { [self] operation, context, origin, outcome, metrics in
            if operation.isDetail {
                if let event = aggregates.add(operation, duration: metrics.durationNs ?? 0, dropped: metrics.dropped ?? 0,
                                              peak: metrics.peak ?? 0, context: context, origin: origin, outcome: outcome, now: clock.now()) { publish(event) }
                guard policy.includes(operation, traceID: context?.traceID) else { return }
            }
            publish(.init(operation: operation, phase: .summary, context: context ?? TraceContext(origin: origin),
                          outcome: outcome, metrics: metrics, elapsedNs: clock.now()))
        })
    }

    private func publish(_ event: DiagnosticEvent) {
        let record = journal?.append(event)
            ?? DiagnosticRecord(runID: runID, sequence: sequence.withLock { $0 &+= 1; return $0 }, wallTimeUTC: wallClock(), event: event)
        let recordID = record.recordID
        let logger = outputs[event.operation.category]!.logger
        let op = event.operation.rawValue, phase = event.phase.rawValue
        let trace = event.context.traceID.uuidString, span = event.context.spanID.uuidString
        let outcome = event.outcome?.rawValue ?? "none", failure = event.failure?.rawValue ?? "none"
        let duration = event.metrics.durationNs ?? 0
        if event.failure != nil && event.failure != .cancelled {
            logger.error("record=\(recordID, privacy: .public) op=\(op, privacy: .public) phase=\(phase, privacy: .public) trace=\(trace, privacy: .public) span=\(span, privacy: .public) outcome=\(outcome, privacy: .public) failure=\(failure, privacy: .public) duration_ns=\(duration)")
        } else if event.isImportant {
            logger.notice("record=\(recordID, privacy: .public) op=\(op, privacy: .public) phase=\(phase, privacy: .public) trace=\(trace, privacy: .public) span=\(span, privacy: .public) outcome=\(outcome, privacy: .public) duration_ns=\(duration)")
        } else {
            logger.debug("record=\(recordID, privacy: .public) op=\(op, privacy: .public) phase=\(phase, privacy: .public) trace=\(trace, privacy: .public) span=\(span, privacy: .public) outcome=\(outcome, privacy: .public) duration_ns=\(duration)")
        }
        sink(event)
    }

    public func setMode(_ mode: DiagnosticMode) {
        policy.set(mode)
        publish(.init(operation: .modeChange, phase: .changed, context: TraceContext(),
                      metrics: .init(statusCode: DiagnosticMode.allCases.firstIndex(of: mode)), elapsedNs: clock.now()))
    }
    public var modeStatus: (DiagnosticMode, Date?) { policy.status }
    public func flushAggregates() { for event in aggregates.flush(now: clock.now()) { publish(event) } }
}
