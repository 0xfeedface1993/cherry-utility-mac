import CherryCore

/// Logger category 与 Instruments signpost 名称属于 OSLog 适配器；Core 只定义操作词表。
extension DiagnosticOperation {
    var category: String {
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

    var signpostName: StaticString {
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
}
