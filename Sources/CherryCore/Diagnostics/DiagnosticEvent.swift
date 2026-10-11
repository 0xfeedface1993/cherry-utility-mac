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
    case keyCapture, keyDecode, keyDispatch, keyPipeline, keyStream, resultApplied, resultIgnored, refresh

    public var category: String {
        switch self {
        case .launch: "app"
        case .discovery, .permission: "discovery"
        case .channelQueue, .channelResume, .channelOpen, .channelHeld: "channel"
        case .hidSchedule, .hidExecution, .hidSend, .mailbox: "hid"
        case .snapshot, .battery, .configurationRead, .configurationWrite, .profileActivate,
             .vendorExchange, .configurationBegin, .configurationEnd, .configurationReadBack: "configuration"
        case .firmwareStatus, .firmwareFlash, .firmwareParse, .firmwareMD5, .firmwareExtract, .firmwareCRC,
             .otaReports, .otaStart, .otaTransfer, .otaResult, .otaACK, .otaProgress, .reconnectionVerify, .reconnectionWait: "firmware"
        case .catalogFetch, .catalogDecode, .firmwareDownload: "network"
        case .cacheRead, .cacheWrite, .presetIO: "storage"
        case .keyCapture, .keyDecode, .keyDispatch, .keyPipeline, .keyStream: "keytest"
        case .modeChange, .export: "diagnostics"
        case .resultApplied, .resultIgnored, .refresh: "app"
        }
    }

    public var signpostName: StaticString {
        switch self {
        case .launch: "LaunchReady"
        case .discovery: "Discovery"
        case .permission: "Permission"
        case .modeChange: "DiagnosticMode"
        case .export: "DiagnosticExport"
        case .channelQueue: "ChannelQueue"
        case .channelResume: "ChannelResume"
        case .channelOpen: "ChannelOpen"
        case .channelHeld: "ChannelHeld"
        case .hidSchedule: "HIDSchedule"
        case .hidExecution: "HIDExecution"
        case .hidSend: "HIDSend"
        case .mailbox: "MailboxSummary"
        case .snapshot: "VendorSnapshot"
        case .battery: "BatteryRead"
        case .firmwareStatus: "FirmwareStatus"
        case .configurationRead: "ConfigurationRead"
        case .configurationWrite: "ConfigurationWrite"
        case .profileActivate: "ProfileActivate"
        case .vendorExchange: "VendorExchange"
        case .configurationBegin: "ConfigurationBegin"
        case .configurationEnd: "ConfigurationEnd"
        case .configurationReadBack: "ConfigurationReadBack"
        case .firmwareFlash: "FirmwareFlash"
        case .firmwareParse: "FirmwareParse"
        case .firmwareMD5: "FirmwareMD5"
        case .firmwareExtract: "FirmwareExtract"
        case .firmwareCRC: "FirmwareCRC"
        case .otaReports: "OTAReports"
        case .otaStart: "OTAStart"
        case .otaTransfer: "OTATransfer"
        case .otaResult: "OTAResult"
        case .otaACK: "OTAACK"
        case .otaProgress: "OTAProgress"
        case .reconnectionVerify: "ReconnectionVerify"
        case .reconnectionWait: "ReconnectionWait"
        case .catalogFetch: "CatalogFetch"
        case .catalogDecode: "CatalogDecode"
        case .firmwareDownload: "FirmwareDownload"
        case .cacheRead: "CacheRead"
        case .cacheWrite: "CacheWrite"
        case .presetIO: "PresetIO"
        case .keyCapture: "KeyCapture"
        case .keyDecode: "KeyDecode"
        case .keyDispatch: "KeyDispatch"
        case .keyPipeline: "KeyPipeline"
        case .keyStream: "KeyStreamSummary"
        case .resultApplied: "ResultApplied"
        case .resultIgnored: "ResultIgnored"
        case .refresh: "Refresh"
        }
    }

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
