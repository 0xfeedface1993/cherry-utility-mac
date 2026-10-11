import CherryCore
import ComposableArchitecture
import Foundation

@DependencyClient
public struct DiagnosticsClient: Sendable {
    public var status: @Sendable () -> DiagnosticStatus = { .init() }
    public var setMode: @Sendable (DiagnosticMode) -> Void = { _ in }
    public var export: @Sendable (DiagnosticRange) async throws -> DiagnosticExport
    public var save: @Sendable (DiagnosticExport) async throws -> Bool = { _ in false }
    public var discard: @Sendable (DiagnosticExport) -> Void = { _ in }
}

extension DiagnosticsClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self()
}

private enum DiagnosticPortKey: TestDependencyKey {
    static let testValue = Diagnostics.noop
    static let previewValue = Diagnostics.noop
}

extension DependencyValues {
    public var diagnosticsClient: DiagnosticsClient {
        get { self[DiagnosticsClient.self] }
        set { self[DiagnosticsClient.self] = newValue }
    }
    public var diagnostics: Diagnostics {
        get { self[DiagnosticPortKey.self] }
        set { self[DiagnosticPortKey.self] = newValue }
    }
}
