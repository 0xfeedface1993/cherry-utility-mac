import CherryCore
import Foundation

/// App 与菜单栏共用一个实例；服务持有 port，从而保留运行期基础设施。
public final class DiagnosticsRuntime: Sendable {
    public let journal: DiagnosticJournal
    public let logger: OSLogDiagnostics
    public let exporter: DiagnosticExporter
    public var port: Diagnostics { logger.port }

    public init(directory: URL, environment: DiagnosticEnvironment, mode: DiagnosticMode = .standard) {
        let journal = DiagnosticJournal(directory: directory)
        self.journal = journal
        logger = OSLogDiagnostics(mode: mode, journal: journal)
        exporter = DiagnosticExporter(journal: journal, directory: directory.appendingPathComponent("Exports", isDirectory: true), environment: environment)
    }

    public var status: DiagnosticStatus {
        var status = journal.status
        let mode = logger.modeStatus
        status.mode = mode.0; status.expiresAt = mode.1
        return status
    }
    public func setMode(_ mode: DiagnosticMode) { logger.setMode(mode) }
    public func export(range: DiagnosticRange) async throws -> DiagnosticExport {
        logger.flushAggregates()
        return try await exporter.export(range: range)
    }
    public func discard(_ export: DiagnosticExport) { exporter.discard(export) }
    public func flush() async throws { logger.flushAggregates(); try await journal.flush() }
}
