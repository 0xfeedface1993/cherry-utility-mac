import Foundation

// 诊断管理的契约类型；界面文案在 CherryFeatures。
public enum DiagnosticMode: String, Codable, CaseIterable, Sendable {
    case standard, detailed, profile, off
}

public enum DiagnosticRange: Int, Codable, CaseIterable, Sendable {
    case recent = 900, currentRun = 0, day = 86400
}

public struct DiagnosticStatus: Equatable, Sendable {
    public var mode: DiagnosticMode
    public var expiresAt: Date?
    public var recorded: UInt64
    public var dropped: UInt64
    public var pending: Int
    public var storedBytes: Int
    public var storageAvailable: Bool
    public init(mode: DiagnosticMode = .standard, expiresAt: Date? = nil, recorded: UInt64 = 0,
                dropped: UInt64 = 0, pending: Int = 0, storedBytes: Int = 0, storageAvailable: Bool = true) {
        self.mode = mode; self.expiresAt = expiresAt; self.recorded = recorded; self.dropped = dropped
        self.pending = pending; self.storedBytes = storedBytes; self.storageAvailable = storageAvailable
    }
}

public struct DiagnosticExport: Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let bytes: Int
    public let events: Int
    public let partial: Bool
    public let dropped: UInt64
    public init(id: UUID, url: URL, bytes: Int, events: Int, partial: Bool, dropped: UInt64) {
        self.id = id; self.url = url; self.bytes = bytes; self.events = events; self.partial = partial; self.dropped = dropped
    }
}

public enum DiagnosticExportError: Error, Equatable, Sendable {
    case busy, timedOut, storage, tooLarge
}
