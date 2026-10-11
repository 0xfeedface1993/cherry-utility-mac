import CherryCore
import CryptoKit
import Foundation
import Synchronization

public final class DiagnosticExporter: Sendable {
    private let journal: DiagnosticJournal
    private let logs = OSLogSnapshotReader()
    private let environment: DiagnosticEnvironment
    private let directory: URL
    private let configuration: DiagnosticPolicyConfiguration
    private let queue = DispatchQueue(label: "dev.local.cherry.utility.diagnostic-export", qos: .utility)
    private let active = Mutex(false)
    private let packaging = Mutex(false)

    public init(journal: DiagnosticJournal, directory: URL, environment: DiagnosticEnvironment,
                configuration: DiagnosticPolicyConfiguration = .init()) {
        self.journal = journal; self.directory = directory; self.environment = environment; self.configuration = configuration
    }

    public func export(range: DiagnosticRange, includeSystemLog: Bool = true) async throws -> DiagnosticExport {
        let acquired = active.withLock { if $0 { return false }; $0 = true; return true }
        guard acquired else { throw DiagnosticExportError.busy }
        defer { active.withLock { $0 = false } }
        guard !packaging.withLock({ $0 }) else { throw DiagnosticExportError.busy }
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let snapshot: DiagnosticJournalSnapshot
        let journalStatus: String
        do { snapshot = try await journal.snapshot(range: range); journalStatus = journal.status.storageAvailable ? "available" : "partial" }
        catch is CancellationError { throw CancellationError() }
        catch {
            snapshot = .init(records: [], cutoff: 0, dropped: journal.status.dropped, recoveredLines: 0, truncated: true)
            journalStatus = "unavailable"
        }
        try Task.checkCancellation()
        let since = range == .currentRun ? (snapshot.records.map(\.wallTimeUTC).min() ?? Date()) : Date().addingTimeInterval(-Double(range.rawValue))
        let system = includeSystemLog ? await logs.read(since: since, runID: journal.runID, cutoff: snapshot.cutoff) : SystemLogSnapshot(status: "not_requested")
        try Task.checkCancellation()
        let elapsed = Double(DiagnosticClock.nanoseconds(start.duration(to: .now))) / 1_000_000_000
        guard elapsed < configuration.exportTimeout else { throw DiagnosticExportError.timedOut }
        packaging.withLock { $0 = true }
        return try await DiagnosticWorker.run(on: queue, timeout: configuration.exportTimeout - elapsed,
            onFinish: { [self] in packaging.withLock { $0 = false } }) { [self] cancellation in
                try makePackage(snapshot, system: system, journalStatus: journalStatus, range: range,
                                pending: journal.status.pending, cancellation: cancellation)
            }
    }

    private func makePackage(_ snapshot: DiagnosticJournalSnapshot, system: SystemLogSnapshot, journalStatus: String,
                             range: DiagnosticRange, pending: Int, cancellation: DiagnosticCancellation) throws -> DiagnosticExport {
        try cancellation.check()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for url in try temporaryPackages() {
            if (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast < Date().addingTimeInterval(-configuration.exportRetention) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let id = UUID(), url = directory.appendingPathComponent("CHERRY-\(id.uuidString).cherrydiag.zip")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        let encoder = DiagnosticRecord.encoder()
        var events = Data()
        for record in snapshot.records {
            try cancellation.check()
            events.append(try encoder.encode(record)); events.append(0x0A)
        }
        var systemData = Data()
        for record in system.records {
            try cancellation.check(); systemData.append(try encoder.encode(record)); systemData.append(0x0A)
        }
        let metrics = try encoder.encode(MetricDocument(records: snapshot.records))
        let begun = Set(snapshot.records.filter { $0.event.phase == .began }.map { $0.event.context.spanID })
        let ended = Set(snapshot.records.filter { $0.event.phase == .finished }.map { $0.event.context.spanID })
        let incomplete = begun.symmetricDifference(ended).count
        let partial = snapshot.truncated || snapshot.dropped > 0 || snapshot.recoveredLines > 0 || incomplete > 0 || journalStatus != "available"
            || system.truncated || !["available", "not_requested"].contains(system.status)
        let readme = Data("""
        CHERRY Utility 诊断包，格式版本 1。
        events.ndjson 是关键事件主来源；system-log.ndjson 仅为当前进程系统日志补充，统计不重复计算它。
        指标单位为纳秒，直方图分位数为桶近似；样本/采样比例和桶边界见 metrics.json。
        本包不包含按键内容、用户路径、预设名称、固件文件或原始错误字符串。
        journal 状态：\(journalStatus)；系统日志状态：\(system.status)；丢记录：\(snapshot.dropped)。
        裁剪：\(snapshot.truncated)；恢复/无效行：\(snapshot.recoveredLines)；未闭合 span：\(incomplete)。
        该包是尽力保留的调试证据，不保证历史完整。Instruments .trace 需独立采集。
        ZIP 使用 stored 格式，可用系统归档工具打开；不会向服务器自动提交。
        """.utf8)
        var entries = [("events.ndjson", events), ("metrics.json", metrics), ("README.txt", readme)]
        if !system.records.isEmpty { entries.append(("system-log.ndjson", systemData)) }
        let files = entries.map { DiagnosticManifest.File(name: $0.0, bytes: $0.1.count, sha256: SHA256.hash(data: $0.1).map { String(format: "%02x", $0) }.joined()) }
        let manifest = DiagnosticManifest(retentionDays: journal.limits.retention / 86400, journalLimitBytes: journal.limits.totalBytes,
            temporaryExportLimitBytes: configuration.exportBytes, detailSampleDivisor: max(1, configuration.detailSampleDivisor),
            exportID: id, environment: environment, requestedRange: range, generatedAt: Date(),
            actualStart: snapshot.records.map(\.wallTimeUTC).min(), actualEnd: snapshot.records.map(\.wallTimeUTC).max(),
            runIDs: Array(Set(snapshot.records.map(\.runID))).sorted { $0.uuidString < $1.uuidString }, cutoff: snapshot.cutoff,
            events: snapshot.records.count, dropped: snapshot.dropped, pendingUnflushed: journalStatus == "available" ? 0 : pending,
            recoveredLines: snapshot.recoveredLines, incompleteSpans: incomplete, truncated: snapshot.truncated, partial: partial,
            journalStatus: journalStatus, systemLogStatus: system.status, systemLogOmitted: system.omitted, files: files)
        entries.append(("manifest.json", try encoder.encode(manifest)))
        let bytes = try DiagnosticZIPWriter.write(entries, to: url, limit: configuration.exportBytes, cancellation: cancellation)
        // 临时导出总量与单包共用 exportBytes 上限，按最旧包淘汰；用户另存的文件不在这里。
        let packages = try temporaryPackages()
        var total = packages.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for old in packages where old != url && total > configuration.exportBytes {
            let size = (try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try FileManager.default.removeItem(at: old); total -= size
        }
        try cancellation.check()
        completed = true
        return .init(id: id, url: url, bytes: bytes, events: snapshot.records.count, partial: partial, dropped: snapshot.dropped)
    }

    private func temporaryPackages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            .filter {
                let name = $0.lastPathComponent
                guard name.hasPrefix("CHERRY-"), name.hasSuffix(".cherrydiag.zip"),
                      UUID(uuidString: String(name.dropFirst(7).dropLast(15))) != nil else { return false }
                return (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    public func discard(_ export: DiagnosticExport) {
        // 仅删除自己目录中的具名临时包，不能通过外部 URL 删除用户文件。
        guard export.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              export.url.lastPathComponent == "CHERRY-\(export.id.uuidString).cherrydiag.zip" else { return }
        queue.async { try? FileManager.default.removeItem(at: export.url) }
    }

    public func save(_ export: DiagnosticExport, to destination: URL) async throws {
        guard export.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              export.url.lastPathComponent == "CHERRY-\(export.id.uuidString).cherrydiag.zip" else { throw DiagnosticExportError.storage }
        try await DiagnosticWorker.run(on: queue, timeout: configuration.exportTimeout) { cancellation in
            try cancellation.check()
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".cherry-save-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: export.url, to: temporary)
            try cancellation.check()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        }
    }
}

private struct MetricDocument: Encodable {
    struct Row: Encodable {
        var operation: DiagnosticOperation
        var origin: DiagnosticOrigin
        var outcome: DiagnosticOutcome?
        var samples: UInt64 = 0
        var sumNs: UInt64 = 0
        var minNs: UInt64 = .max
        var maxNs: UInt64 = 0
        var dropped: UInt64 = 0
        var buckets = [UInt64](repeating: 0, count: DiagnosticAggregates.bounds.count + 1)
        var sampled = false
    }
    let unit = "nanoseconds"
    let bucketUpperBoundsNs = DiagnosticAggregates.bounds
    var rows: [Row] = []

    init(records: [DiagnosticRecord]) {
        var table: [String: Row] = [:]
        for record in records {
            let e = record.event, m = e.metrics
            let histogram = e.phase == .summary && m.buckets?.count == DiagnosticAggregates.bounds.count + 1
            guard histogram || (e.phase == .finished && !e.operation.isDetail) else { continue }
            let key = "\(e.operation.rawValue)-\(e.context.origin.rawValue)-\(e.outcome?.rawValue ?? "summary")"
            var row = table[key] ?? Row(operation: e.operation, origin: e.context.origin, outcome: e.outcome)
            row.samples &+= histogram ? m.count ?? 0 : 1
            row.sumNs &+= histogram ? m.sumNs ?? 0 : m.durationNs ?? 0
            row.minNs = min(row.minNs, histogram ? m.minNs ?? 0 : m.durationNs ?? 0)
            row.maxNs = max(row.maxNs, histogram ? m.maxNs ?? 0 : m.durationNs ?? 0)
            row.dropped &+= m.dropped ?? 0
            if let buckets = m.buckets { for i in row.buckets.indices { row.buckets[i] &+= buckets[i] } }
            row.sampled = row.sampled || (m.sampleDivisor ?? 1) > 1
            table[key] = row
        }
        rows = table.keys.sorted().compactMap { table[$0] }
    }
}
