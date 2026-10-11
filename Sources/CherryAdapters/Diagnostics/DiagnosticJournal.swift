import CherryCore
import Foundation
import Synchronization

public struct DiagnosticJournalLimits: Sendable {
    public var normalCapacity = 2048
    public var importantCapacity = 256
    public var segmentBytes = 4 * 1024 * 1024
    public var totalBytes = 32 * 1024 * 1024
    public var retention: TimeInterval = 7 * 86400
    public init() {}
}

/// 入口只做短锁和有界值拷贝；所有文件 I/O 在 writer.queue 上执行。
public final class DiagnosticJournal: Sendable {
    struct State {
        var normal: [DiagnosticRecord] = []
        var important: [DiagnosticRecord] = []
        var sequence: UInt64 = 0
        var dropped: UInt64 = 0
        var written: UInt64 = 0
        var storedBytes = 0
        var available = true
        var scheduled = false
    }
    public let runID: UUID
    let state = Mutex(State())
    let limits: DiagnosticJournalLimits
    let writer: DiagnosticJournalWriter
    private let snapshotBusy = Mutex(false)

    public init(directory: URL, runID: UUID = UUID(), limits: DiagnosticJournalLimits = .init()) {
        self.runID = runID; self.limits = limits
        writer = DiagnosticJournalWriter(directory: directory, runID: runID, limits: limits)
    }

    @discardableResult
    public func append(_ event: DiagnosticEvent) -> DiagnosticRecord {
        let result = state.withLock { s -> (DiagnosticRecord, Bool) in
            s.sequence &+= 1
            let record = DiagnosticRecord(runID: runID, sequence: s.sequence, event: event)
            if event.metrics.buckets?.count ?? 0 > 12 { s.dropped &+= 1; return (record, false) }
            if event.isImportant {
                if s.important.count >= max(1, limits.importantCapacity) { s.important.removeFirst(); s.dropped &+= 1 }
                s.important.append(record)
            } else {
                if s.normal.count >= max(1, limits.normalCapacity) { s.normal.removeFirst(); s.dropped &+= 1 }
                s.normal.append(record)
            }
            let schedule = !s.scheduled
            s.scheduled = true
            return (record, schedule)
        }
        if result.1 {
            writer.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drain() }
        }
        return result.0
    }

    func drain() {
        let batch = state.withLock { s -> [DiagnosticRecord] in
            let batch = (s.normal + s.important).sorted { $0.sequence < $1.sequence }
            s.normal.removeAll(keepingCapacity: true); s.important.removeAll(keepingCapacity: true)
            s.scheduled = false
            return batch
        }
        guard !batch.isEmpty else { return }
        do {
            let result = try writer.write(batch)
            state.withLock {
                $0.written &+= UInt64(result.written); $0.dropped &+= UInt64(result.oversized)
                $0.storedBytes = result.bytes; $0.available = true
            }
        } catch {
            let retry = state.withLock { s -> Bool in
                s.available = false
                let retained = (batch + s.normal + s.important).sorted { $0.sequence < $1.sequence }
                s.normal = Array(retained.filter { !$0.event.isImportant }.suffix(max(1, limits.normalCapacity)))
                s.important = Array(retained.filter { $0.event.isImportant }.suffix(max(1, limits.importantCapacity)))
                s.dropped &+= UInt64(retained.count - s.normal.count - s.important.count)
                let schedule = !s.scheduled; s.scheduled = true
                return schedule
            }
            if retry { writer.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.drain() } }
        }
    }

    public var status: DiagnosticStatus {
        state.withLock { .init(recorded: $0.written, dropped: $0.dropped, pending: $0.normal.count + $0.important.count,
                              storedBytes: $0.storedBytes, storageAvailable: $0.available) }
    }

    /// 放到同一串行队列的 barrier 固定 cutoff，生产者仍可继续 append。
    public func snapshot(range: DiagnosticRange, deadline: TimeInterval = 2) async throws -> DiagnosticJournalSnapshot {
        let acquired = snapshotBusy.withLock { if $0 { return false }; $0 = true; return true }
        guard acquired else { throw DiagnosticExportError.busy }
        let cutoff = state.withLock { $0.sequence }
        return try await DiagnosticWorker.run(on: writer.queue, timeout: deadline,
            onFinish: { [self] in snapshotBusy.withLock { $0 = false } }) { [self] cancellation in
            try cancellation.check()
            drain()
            var snapshot = (try? writer.snapshot(range: range, cutoff: cutoff, dropped: status.dropped, cancellation: cancellation))
                ?? .init(records: [], cutoff: cutoff, dropped: status.dropped, recoveredLines: 0, truncated: true)
            try cancellation.check()
            let since = Date().addingTimeInterval(-Double(range.rawValue))
            let memory = state.withLock { s in (s.normal + s.important).filter { $0.sequence <= cutoff && (range == .currentRun || $0.wallTimeUTC >= since) } }
            var ids = Set(snapshot.records.map(\.recordID))
            snapshot.records += memory.filter { ids.insert($0.recordID).inserted }
            snapshot.records.sort { $0.wallTimeUTC == $1.wallTimeUTC ? $0.recordID < $1.recordID : $0.wallTimeUTC < $1.wallTimeUTC }
            if snapshot.records.count > 10000 {
                snapshot.records = Array(snapshot.records.suffix(10000)); snapshot.truncated = true
            }
            snapshot.records.sort { $0.runID == $1.runID ? $0.sequence < $1.sequence : $0.runID.uuidString < $1.runID.uuidString }
            return snapshot
        }
    }

    public func flush() async throws {
        try await DiagnosticWorker.run(on: writer.queue, timeout: 2) { [self] cancellation in
            try cancellation.check(); drain()
        }
    }
}

public struct DiagnosticJournalSnapshot: Sendable {
    public var records: [DiagnosticRecord]
    public var cutoff: UInt64
    public var dropped: UInt64
    public var recoveredLines: Int
    public var truncated: Bool
}
