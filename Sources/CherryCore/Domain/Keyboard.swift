import Foundation

/// Stable identity of a physical keyboard: the same USB port keeps the same location ID across
/// re-enumeration (e.g. the reboot at the end of an OTA), so the selection survives it.
public struct KeyboardID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let vendorID: UInt16
    public let productID: UInt16
    public let locationID: UInt32

    public init(vendorID: UInt16, productID: UInt16, locationID: UInt32) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }

    public var description: String {
        String(format: "%04X:%04X@%08X", vendorID, productID, locationID)
    }
}

public struct HIDUsage: Hashable, Sendable, Codable, CustomStringConvertible {
    public let page: UInt16
    public let usage: UInt16

    public init(page: UInt16, usage: UInt16) {
        self.page = page
        self.usage = usage
    }

    public static func keyboard(_ usage: UInt16) -> HIDUsage { HIDUsage(page: 0x07, usage: usage) }
    public static func consumer(_ usage: UInt16) -> HIDUsage { HIDUsage(page: 0x0C, usage: usage) }

    public var description: String { String(format: "0x%04X/0x%02X", page, usage) }
}

/// One top-level collection of an interface, with report sizes in bytes (report ID byte included).
public struct HIDCollectionSummary: Equatable, Sendable {
    public let usage: HIDUsage
    public let inputReports: [UInt8: Int]
    public let outputReports: [UInt8: Int]
    public let featureReports: [UInt8: Int]

    public init(usage: HIDUsage, inputReports: [UInt8: Int], outputReports: [UInt8: Int], featureReports: [UInt8: Int]) {
        self.usage = usage
        self.inputReports = inputReports
        self.outputReports = outputReports
        self.featureReports = featureReports
    }
}

/// One IOHIDDevice (≈ one USB HID interface) of a keyboard.
public struct HIDInterfaceSummary: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let usages: [HIDUsage]
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let maxFeatureReportSize: Int
    public let collections: [HIDCollectionSummary]

    public init(
        id: UInt64, usages: [HIDUsage], maxInputReportSize: Int, maxOutputReportSize: Int,
        maxFeatureReportSize: Int, collections: [HIDCollectionSummary]
    ) {
        self.id = id
        self.usages = usages
        self.maxInputReportSize = maxInputReportSize
        self.maxOutputReportSize = maxOutputReportSize
        self.maxFeatureReportSize = maxFeatureReportSize
        self.collections = collections
    }

    public func has(usagePage: UInt16) -> Bool {
        usages.contains { $0.page == usagePage } || collections.contains { $0.usage.page == usagePage }
    }
}

public struct KeyboardSummary: Equatable, Sendable, Identifiable {
    public let id: KeyboardID
    public let product: String
    public let manufacturer: String
    public let serialNumber: String?
    public let transport: String
    /// USB bcdDevice; Cherry keyboards report their firmware version code here (e.g. 0x0117).
    public let releaseNumber: UInt16
    public let interfaces: [HIDInterfaceSummary]

    public init(
        id: KeyboardID, product: String, manufacturer: String, serialNumber: String?, transport: String,
        releaseNumber: UInt16, interfaces: [HIDInterfaceSummary]
    ) {
        self.id = id
        self.product = product
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
        self.transport = transport
        self.releaseNumber = releaseNumber
        self.interfaces = interfaces
    }

    public var model: KeyboardModel? { KeyboardModel.matching(vendorID: id.vendorID, productID: id.productID) }
    public var firmwareVersion: FirmwareVersion { FirmwareVersion(code: releaseNumber) }

    public var canConfigure: Bool {
        model.map { hasInterface(usagePage: $0.vendorUsagePage) } ?? false
    }
    public var configurationInterfaceIDs: [UInt64] {
        guard let model else { return [] }
        return interfaces.filter { $0.has(usagePage: model.vendorUsagePage) }.map(\.id).sorted()
    }

    public func hasInterface(usagePage: UInt16) -> Bool {
        interfaces.contains { $0.has(usagePage: usagePage) }
    }

    public var displayName: String {
        let name = model?.name ?? product
        return manufacturer.isEmpty || name.localizedCaseInsensitiveContains(manufacturer) ? name : "\(manufacturer) \(name)"
    }
}

/// Models whose protocols have been reverse-engineered and verified on hardware.
public struct KeyboardModel: Equatable, Sendable {
    public let name: String
    public let vendorID: UInt16
    public let productID: UInt16
    /// Prefix of the matching entries in Cherry's firmware catalog (`Desc`).
    public let catalogName: String
    /// Private configuration channel used by CHERRY Utility (battery, status, profiles).
    public let vendorUsagePage: UInt16
    public let vendorReportID: UInt8
    /// Telink USB OTA channel used by the per-model updater.
    public let otaUsagePage: UInt16
    public let otaReportID: UInt8
    public let layout: KeyboardLayout
    /// Onboard profiles (blocks 0…n-1 of the configuration space).
    public let profileCount: Int
    /// Effects the official UI offers for this model, in its display order.
    public let lightingEffects: [LightingEffect]

    public static let pixiu75 = KeyboardModel(
        name: "MX PIXIU 75",
        vendorID: 0x046A,
        productID: 0x01E2,
        catalogName: "MX_PIXIU75_WIRELESS",
        vendorUsagePage: 0xFF1C,
        vendorReportID: 4,
        otaUsagePage: 0xFFEF,
        otaReportID: 5,
        layout: .pixiu75,
        profileCount: 3,
        lightingEffects: LightingEffect.pixiu75
    )

    public static let all: [KeyboardModel] = [.pixiu75]
    public static let cherryVendorID: UInt16 = 0x046A

    public static func matching(vendorID: UInt16, productID: UInt16) -> KeyboardModel? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    public func effect(_ rawValue: UInt8) -> LightingEffect? {
        lightingEffects.first { $0.rawValue == rawValue }
    }
}

extension LightingEffect {
    /// CHERRY Utility `DefaultData/default_light.json`, table 51 (= the model's DeviceIndex 0x33), visible entries only;
    /// names from the driver's `lan_cn.xml` / `lan_en.xml`.
    public static let pixiu75: [LightingEffect] = [
        LightingEffect(rawValue: 0, name: "波纹", englishName: "Wave"),
        LightingEffect(rawValue: 1, name: "光谱", englishName: "Spectrum"),
        LightingEffect(rawValue: 2, name: "呼吸", englishName: "Breathing"),
        LightingEffect(rawValue: 10, name: "霓虹", englishName: "Rolling"),
        LightingEffect(rawValue: 12, name: "曲线", englishName: "Curve"),
        LightingEffect(rawValue: 15, name: "折返", englishName: "Scan"),
        LightingEffect(rawValue: 18, name: "放射", englishName: "Radiation"),
        LightingEffect(rawValue: 19, name: "扩散", englishName: "Ripples"),
        LightingEffect(rawValue: 21, name: "单点亮", englishName: "Single Key"),
        LightingEffect(rawValue: 3, name: "常亮", englishName: "Static"),
        LightingEffect(rawValue: 8, name: "自定义", englishName: "Custom"),
    ]
}

/// Firmware version as Cherry encodes it: the hex digits of the code are the dotted version
/// (bcdDevice 0x0117 ⇔ catalog VersionCode "0117" ⇔ VersionName "0.1.1.7").
public struct FirmwareVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let code: UInt16

    public init(code: UInt16) { self.code = code }

    /// Parses a catalog `VersionCode` the way CHERRY Utility does (`wcstol(…, 16)`).
    public init?(versionCode: String) {
        guard let v = UInt16(versionCode.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
        code = v
    }

    public var description: String {
        String(format: "%04X", code).map(String.init).joined(separator: ".")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.code < rhs.code }
}
