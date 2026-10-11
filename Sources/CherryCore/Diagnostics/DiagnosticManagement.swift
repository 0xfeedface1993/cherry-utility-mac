import Foundation

public enum DiagnosticMode: String, Codable, CaseIterable, Sendable {
    case standard, detailed, profile, off
    public var title: String {
        switch self { case .standard: "标准"; case .detailed: "详细诊断（15 分钟）"; case .profile: "性能采集（10 分钟）"; case .off: "关闭观测" }
    }
}

public enum DiagnosticRange: Int, Codable, CaseIterable, Sendable {
    case recent = 900, currentRun = 0, day = 86400
    public var title: String {
        switch self { case .recent: "最近 15 分钟"; case .currentRun: "当前运行"; case .day: "最近 24 小时" }
    }
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
    public var message: String {
        switch self {
        case .busy: "上一份诊断仍在收尾，请稍后重试。"
        case .timedOut: "生成诊断包超时，请缩小时间范围后重试。"
        case .storage: "诊断文件暂不可用，请检查可用空间后重试。"
        case .tooLarge: "诊断包超过容量限制，请缩小时间范围后重试。"
        }
    }
}
