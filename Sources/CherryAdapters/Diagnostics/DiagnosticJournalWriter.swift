import CherryCore
import Foundation

/// 可变文件状态严格归属 queue；入口不直接访问这些字段。
final class DiagnosticJournalWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "online.odeployer.CherryUtility.diagnostic-writer", qos: .utility)
    let directory: URL
    let runID: UUID
    let limits: DiagnosticJournalLimits
    let wallClock: @Sendable () -> Date
    private var file: FileHandle?
    private var current: URL?
    private var size = 0
    private var index = 0
    private var initialized = false
    private var recoveredLines = 0
    private var retryAfter = Date.distantPast
    private struct Coverage: Codable {
        var evictedThrough: Date
        var lastEvictedRun: UUID
    }
    private var coverage: Coverage?
    private var evictedCurrentRun = false
    private var eventBudget: Int { max(1, limits.totalBytes - 256) }
    private var coverageURL: URL { directory.appendingPathComponent("coverage.json") }
    /// 目录列举返回解析过符号链接的路径（/private/var/…），不能与自己拼出的 URL 直接比较；同目录内按文件名区分。
    private func isActiveSegment(_ url: URL) -> Bool { url.lastPathComponent == current?.lastPathComponent }

    init(directory: URL, runID: UUID, limits: DiagnosticJournalLimits, wallClock: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory; self.runID = runID; self.limits = limits; self.wallClock = wallClock
    }

    deinit { try? file?.close() }

    private func segments() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "ndjson" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prepare() throws {
        guard !initialized else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if (try? coverageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= 256,
           let data = try? Data(contentsOf: coverageURL), data.count <= 256 {
            coverage = try? JSONDecoder().decode(Coverage.self, from: data)
            evictedCurrentRun = coverage?.lastEvictedRun == runID
        }
        for url in try segments() {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            guard length > 0 else { continue }
            try handle.seek(toOffset: length - min(length, 4096))
            let tail = try handle.readToEnd() ?? Data()
            if tail.last != 0x0A {
                let validEnd = tail.lastIndex(of: 0x0A).map { UInt64($0 + 1) } ?? 0
                try handle.truncate(atOffset: length - UInt64(tail.count) + validEnd)
                recoveredLines += 1
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        initialized = true
        try prune()
    }

    private func rotate() throws {
        try file?.close(); file = nil
        index += 1
        let timestamp = String(format: "%020.0f", wallClock().timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("events-\(timestamp)-\(runID.uuidString)-\(index).ndjson")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DiagnosticExportError.storage }
        current = url; size = 0; file = try FileHandle(forWritingTo: url)
    }

    @discardableResult private func prune() throws -> Int {
        let files = try segments()
        var total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let oldest = wallClock().addingTimeInterval(-limits.retention)
        for url in files where !isActiveSegment(url) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if total > eventBudget || (values.contentModificationDate ?? .distantPast) < oldest {
                try recordEviction(url, modified: values.contentModificationDate ?? wallClock())
                try FileManager.default.removeItem(at: url); total -= values.fileSize ?? 0
            }
        }
        return total
    }

    private func recordEviction(_ url: URL, modified: Date) throws {
        let isCurrent = url.lastPathComponent.contains(runID.uuidString)
        evictedCurrentRun = evictedCurrentRun || isCurrent
        // 名称只包含程序生成的随机 run ID；不读取报文或用户身份。
        let components = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        let candidate = components.count >= 8 ? UUID(uuidString: components[2...6].joined(separator: "-")) : nil
        coverage = Coverage(evictedThrough: max(coverage?.evictedThrough ?? .distantPast, modified),
                            lastEvictedRun: evictedCurrentRun ? runID : candidate ?? UUID())
        let data = try JSONEncoder().encode(coverage)
        try data.write(to: coverageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: coverageURL.path)
    }

    func write(_ records: [DiagnosticRecord]) throws -> (written: Int, oversized: Int, bytes: Int) {
        guard wallClock() >= retryAfter else { throw DiagnosticExportError.storage }
        do { return try writeBatch(records) }
        catch { retryAfter = wallClock().addingTimeInterval(10); throw error }
    }

    private func writeBatch(_ records: [DiagnosticRecord]) throws -> (written: Int, oversized: Int, bytes: Int) {
        try prepare()
        let encoder = DiagnosticRecord.encoder()
        var written = 0, oversized = 0
        var total = try prune()
        for record in records {
            var data = try encoder.encode(record)
            guard data.count <= 1024, data.count + 1 <= limits.segmentBytes, data.count + 1 <= eventBudget else { oversized += 1; continue }
            data.append(0x0A)
            if file == nil || size + data.count > limits.segmentBytes { try rotate() }
            // 在写入前腾出空间，当前 segment 的大小同样计入总预算。
            if total + data.count > eventBudget {
                for url in try segments() where !isActiveSegment(url) {
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? wallClock()
                    try recordEviction(url, modified: modified)
                    try FileManager.default.removeItem(at: url); total -= bytes
                    if total + data.count <= eventBudget { break }
                }
            }
            guard total + data.count <= eventBudget else { oversized += 1; continue }
            try file?.write(contentsOf: data)
            size += data.count; total += data.count; written += 1
        }
        return (written, oversized, try prune())
    }

    func snapshot(range: DiagnosticRange, cutoff: UInt64, dropped: UInt64, cancellation: DiagnosticCancellation) throws -> DiagnosticJournalSnapshot {
        try prepare()
        let since = wallClock().addingTimeInterval(-Double(range.rawValue))
        let decoder = DiagnosticRecord.decoder()
        var records: [DiagnosticRecord] = [], bytes = 0
        var truncated = range == .currentRun ? evictedCurrentRun : (coverage?.evictedThrough ?? .distantPast) >= since
        var invalid = recoveredLines
        var recordIDs = Set<String>()
        for url in try segments().reversed() {
            try cancellation.check()
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if range != .currentRun, (values.contentModificationDate ?? .distantPast) < since { continue }
            guard (values.fileSize ?? 0) <= limits.segmentBytes else { truncated = true; continue }
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 0x0A).reversed() {
                try cancellation.check()
                guard line.count <= 1024, let record = try? decoder.decode(DiagnosticRecord.self, from: Data(line)), record.schemaVersion == 1 else { invalid += 1; continue }
                if record.runID == runID && record.sequence > cutoff { continue }
                if range == .currentRun && record.runID != runID { continue }
                if range != .currentRun && record.wallTimeUTC < since { continue }
                guard recordIDs.insert(record.recordID).inserted else { continue }
                if records.count >= limits.snapshotRecords || bytes + line.count > limits.snapshotBytes { truncated = true; continue }
                records.append(record); bytes += line.count + 1
            }
        }
        records.sort { $0.runID == $1.runID ? $0.sequence < $1.sequence : $0.runID.uuidString < $1.runID.uuidString }
        return .init(records: records, cutoff: cutoff, dropped: dropped, recoveredLines: invalid, truncated: truncated)
    }
}
