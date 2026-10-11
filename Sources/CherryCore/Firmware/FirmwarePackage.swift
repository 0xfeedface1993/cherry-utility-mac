import Foundation

/// One entry of Cherry's firmware catalog (`goods_drive/getDriveList`).
public struct FirmwareRelease: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let deviceIndex: Int
    public let versionCode: String
    public let versionName: String
    public let downloadURL: URL
    /// Uppercase hex MD5 of the updater file.
    public let md5: String
    public let isForced: Bool

    public init(
        name: String, deviceIndex: Int, versionCode: String, versionName: String, downloadURL: URL, md5: String,
        isForced: Bool
    ) {
        self.name = name
        self.deviceIndex = deviceIndex
        self.versionCode = versionCode
        self.versionName = versionName
        self.downloadURL = downloadURL
        self.md5 = md5.uppercased()
        self.isForced = isForced
    }

    public var version: FirmwareVersion? { FirmwareVersion(versionCode: versionCode) }
}

/// A verified, parsed updater ready to flash.
public struct FirmwarePackage: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case catalog(FirmwareRelease)
        case localFile(URL)
    }

    public let id: UUID
    public let source: Source
    public let fileMD5: String
    public let image: UpdaterImage

    public init(id: UUID = UUID(), source: Source, fileMD5: String, image: UpdaterImage) {
        self.id = id
        self.source = source
        self.fileMD5 = fileMD5
        self.image = image
    }

    public var displayName: String {
        switch source {
        case .catalog(let r): r.name
        case .localFile(let url): url.lastPathComponent
        }
    }

    /// The firmware image is large; identity is enough for state diffing.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// 升级包不能刷入当前设备的原因；界面文案在 CherryFeatures。
public enum FirmwareIncompatibility: Hashable, Sendable {
    /// 升级包的目标 VID/PID 与设备不同。
    case targetMismatch(packageVendorID: UInt16, packageProductID: UInt16, deviceVendorID: UInt16, deviceProductID: UInt16)
    /// 设备没有暴露 OTA 接口（通常处于无线模式）。
    case missingOTAInterface(usagePage: UInt16)
    /// 通道的输出报告装不下一个 OTA 报文。
    case reportTooShort(length: Int, required: Int)
}

public enum FlashProgress: Equatable, Sendable {
    case started(totalReports: Int)
    case transferred(reports: Int, totalReports: Int, percent: Int)
    case verifying
}

public enum FlashOutcome: Equatable, Sendable {
    /// Device answered the OTA result report with status 0.
    case confirmed
    /// No result report, but the device dropped off the bus right after the transfer (reboot into new image).
    case deviceRebooted
    /// Neither a result nor a reboot was observed within the grace period.
    case unconfirmed
}
