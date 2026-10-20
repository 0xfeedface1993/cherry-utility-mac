import Foundation

/// Reply of vendor command 0x1A (6 bytes), as consumed by CHERRY Utility's power widget.
public struct BatteryStatus: Equatable, Sendable {
    public enum Charging: Equatable, Sendable {
        case notCharging
        case charging
        case other(UInt8)
    }

    public let percent: Int
    public let charging: Charging
    public let raw: [UInt8]

    public init(raw: [UInt8]) throws {
        guard raw.count >= 2 else { throw CherryError.malformedReply("battery reply too short (\(raw.count))") }
        percent = Int(min(raw[0], 100))
        switch raw[1] {
        case 0: charging = .notCharging
        case 1, 2: charging = .charging
        default: charging = .other(raw[1])
        }
        self.raw = raw
    }
}

/// Reply of vendor command 0x1D (`HidReadDeviceInfo(Data, 56)`).
public struct DeviceStatusBlock: Equatable, Sendable {
    public enum ConnectionMode: Equatable, Sendable {
        case wired
        case wireless(UInt16)
        case unknown(UInt16)
    }

    public let vendorID: UInt16
    public let productID: UInt16
    public let mode: ConnectionMode
    public let raw: [UInt8]

    public static let magic: UInt16 = 0x55AA

    public init(raw: [UInt8]) throws {
        guard raw.count >= 12 else { throw CherryError.malformedReply("status block too short (\(raw.count))") }
        let magic = UInt16(raw[0]) | UInt16(raw[1]) << 8
        guard magic == Self.magic else {
            throw CherryError.malformedReply(String(format: "status block magic 0x%04X != 0x55AA", magic))
        }
        vendorID = UInt16(raw[4]) | UInt16(raw[5]) << 8
        productID = UInt16(raw[6]) | UInt16(raw[7]) << 8
        // CHERRY Utility branches on this word: 1 → wired UI, 2 / 7 → wireless UI.
        let m = UInt16(raw[10]) | UInt16(raw[11]) << 8
        switch m {
        case 1: mode = .wired
        case 2, 7: mode = .wireless(m)
        default: mode = .unknown(m)
        }
        self.raw = raw
    }
}

/// One 64-byte profile block of the configuration space (vendor commands 0x05 / 0x06; block `n` lives at
/// offset `n * 64`, and byte 0 of the space doubles as the active-profile number).
///
/// Layout, from CHERRY Utility's `sub_4fd620` (decode), `sub_53bfb0` / `sub_4ed810` (lighting write) and the
/// basic-settings writer at `0x500f2a`:
/// - `[1]` effect (raw value of the model's effect table; bits 6–7 belong to another setting on the PIXIU 99, so only
///   the low 6 bits are read and written), `[2]` brightness 0…4, `[3]` speed stored as `4 - speed`,
///   `[4]` effect direction/parameter, `[5]` random colour (0 = fixed, non-zero = random), `[6…8]` RGB
/// - `[0x16]` key-lock bits, `[0x19…0x21]` three RGB triplets (indicator colours on models that have them)
/// - `[0x22…0x23]` first-stage sleep in seconds, `[0x24…0x25]` deep sleep in minutes (0 = never)
/// - `[0x35]` / `[0x36]` wired / wireless polling-rate index
public struct ProfileConfig: Equatable, Sendable {
    public typealias RGB = LEDColor

    public enum KeyLock: Int, CaseIterable, Sendable, CustomStringConvertible {
        case win = 0, altTab = 1, altF4 = 2, ctrlEsc = 4, altEsc = 7

        public var description: String {
            switch self {
            case .win: "WIN"
            case .altTab: "ALT+TAB"
            case .altF4: "ALT+F4"
            case .ctrlEsc: "CTRL+ESC"
            case .altEsc: "ALT+ESC"
            }
        }
    }

    public static let blockSize = 64
    public static let pollingRates = [125, 250, 500, 1000, 2000, 4000, 8000]
    /// Writes never touch bytes past this offset (the driver's basic-settings writer stops here too).
    public static let writableLength = 0x38
    /// Every effect value of every driver table is below 0x40; the PIXIU 99 driver ORs another field into bits 6–7.
    public static let effectMask: UInt8 = 0x3F

    public let profile: Int
    public let raw: [UInt8]

    public init(profile: Int, raw b: [UInt8]) throws {
        guard b.count >= Self.blockSize else { throw CherryError.malformedReply("profile block too short (\(b.count))") }
        self.profile = profile
        raw = Array(b.prefix(Self.blockSize))
    }

    public var lightingEffect: UInt8 { raw[1] & Self.effectMask }
    /// 0…4, the 5-step backlight slider.
    public var brightness: Int { Int(raw[2]) }
    /// 0…4; stored on the device as `4 - speed`.
    public var speed: Int { 4 - Int(min(raw[3], 4)) }
    public var direction: UInt8 { raw[4] }
    public var randomColor: Bool { raw[5] != 0 }
    public var color: LEDColor { LEDColor(r: raw[6], g: raw[7], b: raw[8]) }
    /// Kept for existing callers; same as `indicatorColors`.
    public var colors: [LEDColor] { indicatorColors }
    public var indicatorColors: [LEDColor] { [0x19, 0x1C, 0x1F].map { LEDColor(r: raw[$0], g: raw[$0 + 1], b: raw[$0 + 2]) } }
    public var keyLocks: [KeyLock] { KeyLock.allCases.filter { raw[0x16] & (1 << $0.rawValue) != 0 } }
    /// First-stage sleep, seconds (UI range 30…300, 0 = never).
    public var sleepSeconds: Int { Int(raw[0x22]) | Int(raw[0x23]) << 8 }
    /// Second-stage (deep) sleep, minutes (UI range 15…300, 0 = never).
    public var deepSleepMinutes: Int { Int(raw[0x24]) | Int(raw[0x25]) << 8 }
    public var wiredPollingIndex: Int { Int(raw[0x35]) }
    public var wirelessPollingIndex: Int { Int(raw[0x36]) }

    public var settings: ProfileSettings {
        ProfileSettings(
            effect: lightingEffect, brightness: min(brightness, 4), speed: speed, randomColor: randomColor, color: color,
            sleepSeconds: sleepSeconds, deepSleepMinutes: deepSleepMinutes
        )
    }

    /// The block with the patch's fields encoded over the current bytes. Only the bytes of the patched fields
    /// change, so anything this app does not model (direction, key locks, polling, indicator colours…) is kept.
    public func applying(_ patch: ProfilePatch) -> [UInt8] {
        guard let values = patch.values?.normalized else { return raw }
        var b = raw
        for field in patch.fields {
            switch field {
            case .effect: b[1] = raw[1] & ~Self.effectMask | values.effect & Self.effectMask
            case .brightness: b[2] = UInt8(values.brightness)
            case .speed: b[3] = UInt8(4 - values.speed)
            // Keep the device's own non-zero marker (0xFF on stock firmware) when the flag stays on.
            case .randomColor: b[5] = values.randomColor ? (raw[5] != 0 ? raw[5] : 0xFF) : 0
            case .color: b.replaceSubrange(6...8, with: [values.color.r, values.color.g, values.color.b])
            case .sleepSeconds: b.replaceSubrange(0x22...0x23, with: [UInt8(values.sleepSeconds & 0xFF), UInt8(values.sleepSeconds >> 8 & 0xFF)])
            case .deepSleepMinutes:
                b.replaceSubrange(0x24...0x25, with: [UInt8(values.deepSleepMinutes & 0xFF), UInt8(values.deepSleepMinutes >> 8 & 0xFF)])
            }
        }
        return b
    }

    /// Runs of differing bytes, merged across gaps of at most `maxGap` unchanged bytes, so a write never spans the
    /// unrelated bytes between two settings (e.g. lighting at 1…8 and sleep at 0x22…0x25).
    public func changedRanges(to other: [UInt8], maxGap: Int = 2) -> [Range<Int>] {
        let n = min(raw.count, other.count, Self.writableLength)
        var ranges: [Range<Int>] = []
        for i in 0..<n where raw[i] != other[i] {
            if let last = ranges.last, i - last.upperBound <= maxGap {
                ranges[ranges.count - 1] = last.lowerBound..<i + 1
            } else {
                ranges.append(i..<i + 1)
            }
        }
        return ranges
    }

    public static func pollingRate(index: Int) -> Int? {
        pollingRates.indices.contains(index) ? pollingRates[index] : nil
    }
}

/// All onboard profiles plus the active-profile selector. Always contains the active profile's block.
public struct KeyboardConfiguration: Equatable, Sendable {
    public let activeProfile: Int
    /// Sorted by profile number.
    public let profiles: [ProfileConfig]

    public init(activeProfile: Int, profiles: [ProfileConfig]) throws {
        guard profiles.contains(where: { $0.profile == activeProfile }) else {
            throw CherryError.malformedReply("配置空间缺少当前配置档 \(activeProfile) 的数据")
        }
        self.activeProfile = activeProfile
        self.profiles = profiles.sorted { $0.profile < $1.profile }
    }

    public var active: ProfileConfig { profiles.first { $0.profile == activeProfile }! }

    public func profile(_ n: Int) -> ProfileConfig? { profiles.first { $0.profile == n } }

    public func replacing(_ config: ProfileConfig) -> KeyboardConfiguration {
        var list = profiles.filter { $0.profile != config.profile }
        list.append(config)
        // The active block is never dropped, so this cannot fail.
        return try! KeyboardConfiguration(activeProfile: activeProfile, profiles: list)
    }
}

public struct VendorSnapshot: Equatable, Sendable {
    /// nil for wired-only models, which are not asked for battery (0x1A) or status (0x1D).
    public let battery: BatteryStatus?
    public let status: DeviceStatusBlock?
    public let configuration: KeyboardConfiguration

    public init(battery: BatteryStatus?, status: DeviceStatusBlock?, configuration: KeyboardConfiguration) {
        self.battery = battery
        self.status = status
        self.configuration = configuration
    }

    /// Snapshot holding only the active profile.
    public init(battery: BatteryStatus?, status: DeviceStatusBlock?, profile: ProfileConfig) {
        self.init(battery: battery, status: status, configuration: try! KeyboardConfiguration(activeProfile: profile.profile, profiles: [profile]))
    }

    public var profile: ProfileConfig { configuration.active }

    public func with(battery: BatteryStatus) -> VendorSnapshot {
        VendorSnapshot(battery: battery, status: status, configuration: configuration)
    }

    public func with(configuration: KeyboardConfiguration) -> VendorSnapshot {
        VendorSnapshot(battery: battery, status: status, configuration: configuration)
    }
}

/// Firmware identity read back over the OTA channel (Telink "get version" command).
public struct DeviceFirmwareStatus: Equatable, Sendable {
    public let version: UInt32
    public let crc: UInt32

    public init(version: UInt32, crc: UInt32) {
        self.version = version
        self.crc = crc
    }
}

public struct KeyEvent: Equatable, Sendable {
    public let usage: HIDUsage
    public let isDown: Bool
    /// Nanoseconds, monotonic.
    public let timestamp: UInt64

    public init(usage: HIDUsage, isDown: Bool, timestamp: UInt64) {
        self.usage = usage
        self.isDown = isDown
        self.timestamp = timestamp
    }
}

public enum InputMonitoringStatus: Equatable, Sendable {
    case granted
    case denied
    case undetermined
}

/// 类型化错误；字符串关联值只是技术细节。界面文案在 CherryPresentation 的 ErrorPresentation。
public enum CherryError: Error, Equatable, Sendable {
    case deviceNotFound(KeyboardID)
    case interfaceNotFound(usagePage: UInt16)
    case accessDenied
    case openFailed(Int32)
    case ioFailed(String)
    case disconnected
    case timeout(String)
    case malformedReply(String)
    case deviceRejected(command: UInt8, status: UInt8)
    case unsupportedModel
    case firmwareFormat(String)
    case checksumMismatch(String)
    case incompatibleFirmware([FirmwareIncompatibility])
    case otaFailed(status: UInt8)
    case network(String)
    case presetFormat(String)
    case unsupportedSetting(String)
    case writeNotApplied(String)
    case storage(String)
    /// 另一个进程（App 或命令行）正在使用这把键盘，等待超时；或者它正在刷写固件。
    case deviceBusy(DeviceBusyReason)
}

public enum DeviceBusyReason: Equatable, Sendable {
    /// 另一个进程正在刷写这把键盘的固件；刷写期间不等待，直接拒绝。
    case updatingFirmware
    /// 另一个进程的会话一直没有结束。
    case inUse
}
