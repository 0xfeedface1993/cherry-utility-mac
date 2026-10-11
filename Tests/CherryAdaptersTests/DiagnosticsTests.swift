import CherryCore
import Foundation
import Synchronization
import Testing
@testable import CherryAdapters

@Suite struct DiagnosticAdapterTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CherryDiagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func event(_ op: DiagnosticOperation = .battery, phase: DiagnosticPhase = .summary) -> DiagnosticEvent {
        .init(operation: op, phase: phase, context: TraceContext(), elapsedNs: 1)
    }

    static func manifest(of export: DiagnosticExport) throws -> [String: Any] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", export.url.path, "manifest.json"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func boundedQueuesPreserveImportantRecordsAndSequence() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var limits = DiagnosticJournalLimits(); limits.normalCapacity = 2; limits.importantCapacity = 1
        let journal = DiagnosticJournal(directory: dir, limits: limits)
        for _ in 0..<20 { journal.append(event()) }
        let important = journal.append(event(.launch))
        #expect(journal.status.pending == 3)
        #expect(journal.status.dropped == 18)
        let snapshot = try await journal.snapshot(range: .currentRun)
        #expect(snapshot.records.count == 3)
        #expect(snapshot.records.last?.recordID == important.recordID)
        #expect(snapshot.records.map(\.sequence) == [19, 20, 21])
    }

    @Test func journalSurvivesRelaunchAndRepairsIncompleteTail() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = DiagnosticJournal(directory: dir)
        first.append(event(.launch)); try await first.flush()
        let segment = try #require(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "ndjson" })
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken SECRET".utf8)); try handle.close()
        let second = DiagnosticJournal(directory: dir)
        second.append(event(.modeChange)); try await second.flush()
        let all = try await second.snapshot(range: .day)
        #expect(all.records.count == 2)
        #expect(all.recoveredLines == 1)
        #expect(Set(all.records.map(\.runID)).count == 2)
        #expect(try await second.snapshot(range: .currentRun).records.count == 1)
        let permission = (try FileManager.default.attributesOfItem(atPath: segment.path)[.posixPermissions]) as? Int
        #expect(permission == 0o600)
    }

    @Test func retentionAndRotationRespectTotalQuota() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var limits = DiagnosticJournalLimits(); limits.segmentBytes = 1500; limits.totalBytes = 3000
        let journal = DiagnosticJournal(directory: dir, limits: limits)
        for _ in 0..<30 { journal.append(event(.launch)) }
        try await journal.flush()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(total <= 3000)
        let snapshot = try await journal.snapshot(range: .currentRun)
        #expect(snapshot.records.count < 30 && snapshot.truncated)
        let restarted = DiagnosticJournal(directory: dir, limits: limits)
        #expect(try await restarted.snapshot(range: .day).truncated)
    }

    @Test func failedStorageKeepsBoundedMemoryAndCanExportPartialEvidence() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("file")
        try Data().write(to: bad)
        let journal = DiagnosticJournal(directory: bad)
        journal.append(event(.launch))
        let snapshot = try await journal.snapshot(range: .currentRun)
        #expect(!journal.status.storageAvailable)
        #expect(snapshot.records.count == 1)
        #expect(snapshot.truncated)
        #expect(journal.status.pending == 1)
    }

    @Test func timedWorkerRejectsLateReplyAndRunsCleanup() async throws {
        let cleaned = Mutex(false)
        let queue = DispatchQueue(label: "diagnostic-worker-test")
        await #expect(throws: DiagnosticExportError.timedOut) {
            try await DiagnosticWorker.run(on: queue, timeout: 0.005, onFinish: { cleaned.withLock { $0 = true } }) { _ in
                Thread.sleep(forTimeInterval: 0.05)
                return 99
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(cleaned.withLock { $0 })
    }

    @Test func policyExpiresUsingMonotonicClock() {
        let time = Mutex<UInt64>(0)
        let policy = DiagnosticPolicy(mode: .detailed, clock: .init(now: { time.withLock { $0 } }))
        #expect(policy.status.0 == .detailed)
        time.withLock { $0 = 900_000_000_000 }
        #expect(policy.status.0 == .standard)
        #expect(policy.status.1 == nil)
    }

    @Test func systemLogParserRejectsExtraTextAndForeignRuns() {
        let run = UUID(), trace = UUID(), span = UUID()
        let message = "record=\(run):1 op=battery phase=finished trace=\(trace) span=\(span) outcome=success duration_ns=10"
        #expect(SafeSystemLog.parse(message, date: Date(), runID: run, cutoff: 1) != nil)
        #expect(SafeSystemLog.parse(message + " path=/Users/person/SECRET", date: Date(), runID: run, cutoff: 1) == nil)
        #expect(SafeSystemLog.parse(message, date: Date(), runID: UUID(), cutoff: 1) == nil)
        #expect(SafeSystemLog.parse(message, date: Date(), runID: run, cutoff: 0) == nil)
    }

    @Test func exportProducesStandardZipAndHashManifest() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = DiagnosticJournal(directory: dir.appendingPathComponent("Journal"))
        journal.append(event(.launch))
        let exporter = DiagnosticExporter(journal: journal, directory: dir.appendingPathComponent("Exports"),
            environment: .init(appVersion: "1.0", appBuild: "1", simulated: true))
        let exported = try await exporter.export(range: .currentRun, includeSystemLog: false)
        #expect(exported.events == 1)
        let manifest = try Self.manifest(of: exported)
        #expect(manifest["events"] as? Int == 1)
        #expect(manifest["retention_days"] as? Int == 7 && manifest["detail_sample_divisor"] as? Int == 64)
        #expect(manifest["system_log_status"] as? String == "not_requested")
        #expect((manifest["files"] as? [[String: Any]])?.allSatisfy { ($0["sha256"] as? String)?.count == 64 } == true)
    }
}

@Suite("策略配置单一来源")
struct DiagnosticPolicyConfigurationTests {
    static func runtime(_ configuration: DiagnosticPolicyConfiguration) throws -> (DiagnosticsRuntime, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CherryDiagnostics-\(UUID().uuidString)")
        let runtime = DiagnosticsRuntime(directory: dir, environment: .init(appVersion: "1.0", appBuild: "1", simulated: true),
                                         mode: .standard, configuration: configuration)
        return (runtime, dir)
    }

    @Test func manifestReportsThePolicyActuallyInEffect() async throws {
        var configuration = DiagnosticPolicyConfiguration()
        configuration.journal.totalBytes = 3000
        configuration.journal.retention = 43_200
        configuration.exportBytes = 1024 * 1024
        configuration.detailSampleDivisor = 8
        let (runtime, dir) = try Self.runtime(configuration)
        defer { try? FileManager.default.removeItem(at: dir) }
        runtime.port.emit(.launch)
        let exported = try await runtime.export(range: .currentRun, includeSystemLog: false)
        let manifest = try DiagnosticAdapterTests.manifest(of: exported)
        #expect(manifest["journal_limit_bytes"] as? Int == 3000)
        #expect(manifest["retention_days"] as? Double == 0.5)
        #expect(manifest["temporary_export_limit_bytes"] as? Int == 1024 * 1024)
        #expect(manifest["detail_sample_divisor"] as? Int == 8)
        #expect(runtime.status.mode == .standard && runtime.status.expiresAt == nil)
    }

    @Test func policyUsesConfiguredDurationsSamplingAndCaps() {
        let time = Mutex<UInt64>(0)
        var configuration = DiagnosticPolicyConfiguration()
        configuration.detailedDuration = .seconds(2)
        configuration.detailSampleDivisor = 1
        configuration.samplesPerTrace = 3
        let policy = DiagnosticPolicy(mode: .detailed, clock: .init(now: { time.withLock { $0 } }), configuration: configuration)
        let trace = UUID()
        #expect((0..<5).map { _ in policy.includes(.otaACK, traceID: trace) } == [true, true, true, false, false])
        time.withLock { $0 = 2_000_000_000 }
        #expect(policy.status.0 == .standard)
        #expect(!policy.includes(.otaACK))
    }

    @Test func timelineSamplesCarryTheConfiguredDivisor() {
        var configuration = DiagnosticPolicyConfiguration()
        configuration.detailSampleDivisor = 4
        let events = Mutex<[DiagnosticEvent]>([])
        let logger = OSLogDiagnostics(mode: .profile, configuration: configuration, sink: { event in events.withLock { $0.append(event) } })
        for _ in 0..<8 { logger.port.begin(.otaACK, context: TraceContext(origin: .profile)).finish() }
        let finished = events.withLock { $0.filter { $0.phase == .finished } }
        #expect(finished.count == 2 && finished.allSatisfy { $0.metrics.sampleDivisor == 4 })
    }

    /// 保存与删除只作用于本目录下的具名临时包，伪造的路径不会触及用户文件。
    @Test func saveAndDiscardOnlyTouchOwnPackages() async throws {
        let (runtime, dir) = try Self.runtime(.init())
        defer { try? FileManager.default.removeItem(at: dir) }
        runtime.port.emit(.launch)
        let exported = try await runtime.export(range: .currentRun, includeSystemLog: false)
        let saved = dir.appendingPathComponent("saved.cherrydiag.zip")
        try await runtime.save(exported, to: saved)
        #expect(FileManager.default.fileExists(atPath: saved.path))

        let elsewhere = dir.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let victim = elsewhere.appendingPathComponent(exported.url.lastPathComponent)
        try Data("user".utf8).write(to: victim)
        let forged = DiagnosticExport(id: exported.id, url: victim, bytes: 4, events: 0, partial: false, dropped: 0)
        await #expect(throws: DiagnosticExportError.storage) { try await runtime.save(forged, to: dir.appendingPathComponent("x.zip")) }
        runtime.discard(forged)
        runtime.discard(exported)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: exported.url.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!FileManager.default.fileExists(atPath: exported.url.path))
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }
}

@Suite("高频统计口径")
struct DiagnosticAggregateTests {
    @Test func sampledAndUnsampledSpansBothCountOnceAndSeparateFailures() {
        let events = Mutex<[DiagnosticEvent]>([])
        let logger = OSLogDiagnostics(mode: .profile, sink: { event in events.withLock { $0.append(event) } })
        let parent = TraceContext(origin: .profile)
        for i in 0..<128 {
            let span = logger.port.begin(.otaACK, context: parent)
            span.finish(i < 100 ? .success : .timeout)
        }
        logger.flushAggregates()
        let rows = events.withLock { $0.filter { $0.phase == .summary && $0.metrics.buckets != nil } }
        #expect(rows.filter { $0.outcome == .success }.reduce(0) { $0 + ($1.metrics.count ?? 0) } == 100)
        #expect(rows.filter { $0.outcome == .timeout }.reduce(0) { $0 + ($1.metrics.count ?? 0) } == 28)
        #expect(rows.reduce(0) { $0 + ($1.metrics.buckets?.reduce(0, +) ?? 0) } == 128)
        #expect(rows.allSatisfy { $0.context.origin == .profile })
    }

    @Test func detailFailureLimitPreservesFullHistogram() {
        let events = Mutex<[DiagnosticEvent]>([])
        let logger = OSLogDiagnostics(mode: .standard, sink: { event in events.withLock { $0.append(event) } })
        for _ in 0..<100 { logger.port.begin(.otaACK).finish(error: CherryError.timeout("SECRET")) }
        logger.flushAggregates()
        #expect(events.withLock { $0.filter { $0.failure == .timeout }.count } == 30)
        #expect(events.withLock { $0.filter { $0.phase == .summary }.reduce(0) { $0 + ($1.metrics.count ?? 0) } } == 100)
    }
}
