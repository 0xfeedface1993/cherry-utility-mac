import CherryCore
import Foundation

/// App 与菜单栏共用一个实例；服务持有 port，从而保留运行期基础设施。
public final class DiagnosticsRuntime: Sendable {
    public let journal: DiagnosticJournal
    public let logger: OSLogDiagnostics
    public let exporter: DiagnosticExporter
    public var port: Diagnostics { logger.port }

    public init(directory: URL, environment: DiagnosticEnvironment, mode: DiagnosticMode = .standard,
                configuration: DiagnosticPolicyConfiguration = .init(), wallClock: @escaping @Sendable () -> Date = Date.init) {
        let journal = DiagnosticJournal(directory: directory, limits: configuration.journal, wallClock: wallClock)
        self.journal = journal
        logger = OSLogDiagnostics(mode: mode, journal: journal, configuration: configuration, wallClock: wallClock)
        exporter = DiagnosticExporter(journal: journal, directory: directory.appendingPathComponent("Exports", isDirectory: true),
                                      environment: environment, configuration: configuration, wallClock: wallClock)
    }

    public var status: DiagnosticStatus {
        var status = journal.status
        let mode = logger.modeStatus
        status.mode = mode.0; status.expiresAt = mode.1
        return status
    }
    public func setMode(_ mode: DiagnosticMode) { logger.setMode(mode) }
    public func export(range: DiagnosticRange, includeSystemLog: Bool = true) async throws -> DiagnosticExport {
        logger.flushAggregates()
        return try await exporter.export(range: range, includeSystemLog: includeSystemLog)
    }
    public func discard(_ export: DiagnosticExport) { exporter.discard(export) }
    public func save(_ export: DiagnosticExport, to destination: URL) async throws { try await exporter.save(export, to: destination) }
    public func flush() async throws { logger.flushAggregates(); try await journal.flush() }
}
