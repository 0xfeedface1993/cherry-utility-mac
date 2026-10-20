import CherryCore
import Foundation
import OSLog
import Synchronization

struct SafeSystemLog: Codable, Sendable {
    let recordID: String
    let operation: DiagnosticOperation
    let phase: DiagnosticPhase
    let traceID: UUID
    let spanID: UUID
    let outcome: DiagnosticOutcome?
    let failure: DiagnosticFailure?
    let durationNs: UInt64
    let wallTimeUTC: Date

    /// 只接受本项目固定模板；未知 token/额外文本导致整条省略，private 开启也不会扩大导出字段。
    static func parse(_ message: String, date: Date, runID: UUID, cutoff: UInt64) -> Self? {
        guard message.utf8.count < 2048 else { return nil }
        var fields: [String: String] = [:]
        for token in message.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, fields[String(pair[0])] == nil else { return nil }
            fields[String(pair[0])] = String(pair[1])
        }
        let required: Set<String> = ["record", "op", "phase", "trace", "span", "outcome", "duration_ns"]
        guard Set(fields.keys) == required || Set(fields.keys) == required.union(["failure"]),
              let id = fields["record"], let op = fields["op"].flatMap(DiagnosticOperation.init(rawValue:)),
              let phase = fields["phase"].flatMap(DiagnosticPhase.init(rawValue:)),
              let trace = fields["trace"].flatMap(UUID.init(uuidString:)), let span = fields["span"].flatMap(UUID.init(uuidString:)),
              let duration = fields["duration_ns"].flatMap(UInt64.init) else { return nil }
        let parts = id.split(separator: ":")
        guard parts.count == 2, UUID(uuidString: String(parts[0])) == runID,
              let sequence = UInt64(parts[1]), sequence <= cutoff else { return nil }
        let outcome = fields["outcome"] == "none" ? nil : fields["outcome"].flatMap(DiagnosticOutcome.init(rawValue:))
        guard fields["outcome"] == "none" || outcome != nil else { return nil }
        let failure = fields["failure"].flatMap(DiagnosticFailure.init(rawValue:))
        guard fields["failure"] == nil || failure != nil else { return nil }
        return .init(recordID: id, operation: op, phase: phase, traceID: trace, spanID: span,
                     outcome: outcome, failure: failure, durationNs: duration, wallTimeUTC: date)
    }
}

struct SystemLogSnapshot: Sendable {
    var records: [SafeSystemLog] = []
    var status = "unavailable"
    var omitted = 0
    var truncated = false
}

final class OSLogSnapshotReader: Sendable {
    private let queue = DispatchQueue(label: "online.odeployer.CherryUtility.system-log", qos: .utility)
    private let busy = Mutex(false)

    func read(since: Date, runID: UUID, cutoff: UInt64) async -> SystemLogSnapshot {
        let acquired = busy.withLock { if $0 { return false }; $0 = true; return true }
        guard acquired else { return .init(status: "busy") }
        do {
            return try await DiagnosticWorker.run(on: queue, timeout: 2, onFinish: { [self] in busy.withLock { $0 = false } }) { cancellation in
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let predicate = NSPredicate(format: "subsystem == %@", OSLogDiagnostics.subsystem)
                let entries = try store.getEntries(at: store.position(date: since), matching: predicate)
                var snapshot = SystemLogSnapshot(status: "available"), count = 0, bytes = 0
                for entry in entries {
                    try cancellation.check()
                    guard let entry = entry as? OSLogEntryLog, entry.subsystem == OSLogDiagnostics.subsystem,
                          DiagnosticOperation.allCases.contains(where: { $0.category == entry.category }) else { continue }
                    count += 1
                    if count > 10000 || bytes > 5 * 1024 * 1024 { snapshot.truncated = true; break }
                    guard let record = SafeSystemLog.parse(entry.composedMessage, date: entry.date, runID: runID, cutoff: cutoff) else { snapshot.omitted += 1; continue }
                    bytes += entry.composedMessage.utf8.count
                    snapshot.records.append(record)
                }
                return snapshot
            }
        } catch is CancellationError { return .init(status: "cancelled") }
        catch DiagnosticExportError.timedOut { return .init(status: "timed_out") }
        catch { return .init(status: "unavailable") }
    }
}
