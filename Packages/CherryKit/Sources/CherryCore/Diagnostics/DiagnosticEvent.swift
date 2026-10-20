import Foundation

/// 事件只接收枚举、随机身份和数值；不接受错误文本、路径、报文或按键内容。
public enum DiagnosticOperation: String, Codable, CaseIterable, Sendable {
    case launch, discovery, permission, modeChange, export
    case channelQueue, channelResume, channelOpen, channelHeld
    case hidSchedule, hidExecution, hidSend, mailbox
    case snapshot, battery, firmwareStatus, configurationRead, configurationWrite, profileActivate
    case vendorExchange, configurationBegin, configurationEnd, configurationReadBack
    case firmwareFlash, firmwareParse, firmwareMD5, firmwareExtract, firmwareCRC, otaReports, otaStart, otaTransfer, otaResult
    case otaACK, otaProgress, reconnectionVerify, reconnectionWait
    case catalogFetch, catalogDecode, firmwareDownload, cacheRead, cacheWrite, presetIO
    case customFirmwareBuild, customFirmwareIO
    case keyCapture, keyDecode, keyDispatch, keyPipeline, keyStream, resultApplied, resultIgnored, refresh

    public var isDetail: Bool {
        switch self {
        case .channelResume, .hidSchedule, .hidExecution, .hidSend, .vendorExchange,
             .otaACK, .otaProgress, .keyDecode, .keyDispatch, .keyPipeline, .keyStream, .mailbox: true
        default: false
        }
    }
}

public enum DiagnosticOutcome: String, Codable, Sendable {
    case success, failed, cancelled, timeout, disconnected, stopped, abandoned
    case unconfirmed, deviceRebooted, noChange, mismatch, dropped, ignored
}

public enum DiagnosticPhase: String, Codable, Sendable { case began, finished, summary, changed }

public enum DiagnosticOrigin: String, Codable, Sendable {
    case app, menuBar, deviceInfo, configuration, firmware, keytest, background, profile
    /// 快捷指令、Spotlight 等系统自动化入口（之后的 CLI / MCP 也经 App 走这里）。
    case automation
}

/// 固定数值字段不会携带用户可输入的任意文本。
public struct DiagnosticMetrics: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case durationNs, count, bytes, dropped, peak, command, offset, length, usagePage, reportID = "reportId", profile, statusCode, windowNs, minNs, maxNs, sumNs, buckets, sampleDivisor
    }
    public var sampleDivisor: UInt64?
    public var durationNs: UInt64?
    public var count: UInt64?
    public var bytes: UInt64?
    public var dropped: UInt64?
    public var peak: UInt64?
    public var command: UInt8?
    public var offset: UInt64?
    public var length: UInt64?
    public var usagePage: UInt16?
    public var reportID: UInt8?
    public var profile: Int?
    public var statusCode: Int?
    public var windowNs: UInt64?
    public var minNs: UInt64?
    public var maxNs: UInt64?
    public var sumNs: UInt64?
    public var buckets: [UInt64]?

    public init(durationNs: UInt64? = nil, count: UInt64? = nil, bytes: UInt64? = nil,
                dropped: UInt64? = nil, peak: UInt64? = nil, command: UInt8? = nil,
                offset: UInt64? = nil, length: UInt64? = nil, usagePage: UInt16? = nil,
                reportID: UInt8? = nil, profile: Int? = nil, statusCode: Int? = nil) {
        self.durationNs = durationNs; self.count = count; self.bytes = bytes
        self.dropped = dropped; self.peak = peak; self.command = command
        self.offset = offset; self.length = length; self.usagePage = usagePage
        self.reportID = reportID; self.profile = profile; self.statusCode = statusCode
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let operation: DiagnosticOperation
    public let phase: DiagnosticPhase
    public let context: TraceContext
    public let outcome: DiagnosticOutcome?
    public let failure: DiagnosticFailure?
    public let metrics: DiagnosticMetrics
    public let elapsedNs: UInt64

    public init(operation: DiagnosticOperation, phase: DiagnosticPhase, context: TraceContext,
                outcome: DiagnosticOutcome? = nil, failure: DiagnosticFailure? = nil,
                metrics: DiagnosticMetrics = .init(), elapsedNs: UInt64) {
        self.operation = operation; self.phase = phase; self.context = context
        self.outcome = outcome; self.failure = failure; self.metrics = metrics; self.elapsedNs = elapsedNs
    }

    public var isImportant: Bool {
        failure != nil || [.launch, .discovery, .permission, .modeChange, .configurationWrite,
                           .profileActivate, .otaTransfer, .otaResult, .reconnectionVerify, .export].contains(operation)
    }
}
