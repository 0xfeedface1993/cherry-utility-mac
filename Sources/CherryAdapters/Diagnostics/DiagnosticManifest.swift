import CherryCore
import Foundation

public struct DiagnosticEnvironment: Codable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let architecture: String
    public let simulated: Bool
    public init(appVersion: String, appBuild: String, simulated: Bool) {
        // 版本字段只允许构建版本常用字符，不能借此导出任意用户文本。
        func version(_ text: String) -> String { String(text.unicodeScalars.filter { CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_").contains($0) }.prefix(64)) }
        self.appVersion = version(appVersion); self.appBuild = version(appBuild); self.simulated = simulated
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "x86_64"
        #endif
    }
}

struct DiagnosticManifest: Encodable {
    struct File: Codable { let name: String; let bytes: Int; let sha256: String }
    let schemaVersion = 1
    let policyVersion = 1
    let retentionDays = 7
    let journalLimitBytes = 32 * 1024 * 1024
    let temporaryExportLimitBytes = 20 * 1024 * 1024
    let detailSampleDivisor = 64
    let droppedCountScope = "current_run"
    let coveragePolicy = "best_effort_with_persisted_eviction_marker"
    let exportID: UUID
    let environment: DiagnosticEnvironment
    let requestedRange: DiagnosticRange
    let generatedAt: Date
    let actualStart: Date?
    let actualEnd: Date?
    let runIDs: [UUID]
    let cutoff: UInt64
    let events: Int
    let dropped: UInt64
    let pendingUnflushed: Int
    let recoveredLines: Int
    let incompleteSpans: Int
    let truncated: Bool
    let partial: Bool
    let journalStatus: String
    let systemLogStatus: String
    let systemLogOmitted: Int
    let files: [File]
}
