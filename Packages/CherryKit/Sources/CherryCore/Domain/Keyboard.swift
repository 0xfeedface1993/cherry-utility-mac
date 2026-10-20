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

/// A CHERRY keyboard (or its 2.4 GHz receiver) as the official CHERRY Utility 2.3.28.7 knows it.
///
/// Every keyboard uses the same private configuration protocol (UsagePage 0xFF1C, report #4); models differ in
/// which profile bytes the driver writes, their lighting-effect table and how their firmware is updated.
/// The catalog lives in `KeyboardModel+Catalog.swift`; see `Docs/records/多型号兼容.md` for the evidence.
public struct KeyboardModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyboard
        /// 2.4 GHz receiver: the driver configures the paired keyboard through it with the same protocol.
        case receiver
    }

    public enum Lighting: Equatable, Sendable {
        /// No backlight (NBL): the driver never writes the lighting bytes.
        case none
        /// Single-colour backlight (BL): effect, brightness and speed only.
        case singleColor
        case rgb
    }

    /// How the official per-model updater delivers firmware; only `.telinkUSBOTA` can be flashed by this app.
    public enum FirmwareFamily: Equatable, Sendable {
        /// .NET Telink USB_OTA updater (`code_2M` + `param_128K`), flashed over the OTA interface.
        case telinkUSBOTA
        /// EVision Sonix SN32F2xx ISP updater (firmware `.hex` inside an RCDATA zip).
        case sonixISP
        /// Native updater with `DOWNLOAD` resources (Cortex-M keyboards, nRF5 receivers).
        case downloadResource
        /// Native x64 updater with a `FIRE_WARE2` container.
        case fireWare2
        /// Native EVision updater carrying a Telink TLSR8 image.
        case evisionTelink
        /// Nordic DFU updater.
        case nordicDFU
        /// Cherry's catalog has no updater for this product ID.
        case unpublished
    }

    public enum Verification: Equatable, Sendable {
        /// Protocol, profile writes and firmware flashing confirmed on a real keyboard.
        case hardware
        /// Derived from the official driver and updater only.
        case driver
    }

    public struct OTAInterface: Equatable, Sendable {
        public let usagePage: UInt16
        public let reportID: UInt8

        public init(usagePage: UInt16, reportID: UInt8) {
            self.usagePage = usagePage
            self.reportID = reportID
        }

        public static let telink = OTAInterface(usagePage: 0xFFEF, reportID: 5)
    }

    public let name: String
    public let vendorID: UInt16
    public let productID: UInt16
    /// The driver's DeviceIndex: row of `default_light.json` / `DefaultData*.json` (not the catalog's DeviceIndex).
    public let deviceIndex: Int
    public let kind: Kind
    /// Wireless keyboards (and their receivers) report battery (0x1A) and connection status (0x1D).
    public let isWireless: Bool
    /// Prefix of the matching entries in Cherry's firmware catalog (`Desc`); nil when the catalog has none.
    public let catalogName: String?
    /// Private configuration channel used by CHERRY Utility (battery, status, profiles).
    public let vendorUsagePage: UInt16
    public let vendorReportID: UInt8
    /// Telink USB OTA channel used by the per-model updater; nil when firmware cannot be flashed by this app.
    public let ota: OTAInterface?
    public let firmwareFamily: FirmwareFamily
    public let layout: KeyboardLayout
    /// Onboard profiles (blocks 0…n-1 of the configuration space).
    public let profileCount: Int
    public let lighting: Lighting
    /// Effects the official UI offers for this model, in its display order.
    public let lightingEffects: [LightingEffect]
    /// The driver writes the two sleep timers (profile bytes 0x22…0x25) for this product ID.
    public let hasSleepSettings: Bool
    public let verification: Verification

    public init(
        name: String, vendorID: UInt16 = cherryVendorID, productID: UInt16, deviceIndex: Int, kind: Kind = .keyboard,
        isWireless: Bool, catalogName: String?, vendorUsagePage: UInt16 = 0xFF1C, vendorReportID: UInt8 = 4,
        ota: OTAInterface? = nil, firmwareFamily: FirmwareFamily, layout: KeyboardLayout, profileCount: Int = 3,
        lighting: Lighting, lightingEffects: [LightingEffect], hasSleepSettings: Bool, verification: Verification = .driver
    ) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.deviceIndex = deviceIndex
        self.kind = kind
        self.isWireless = isWireless
        self.catalogName = catalogName
        self.vendorUsagePage = vendorUsagePage
        self.vendorReportID = vendorReportID
        self.ota = ota
        self.firmwareFamily = firmwareFamily
        self.layout = layout
        self.profileCount = profileCount
        self.lighting = lighting
        self.lightingEffects = lighting == .none ? [] : lightingEffects
        self.hasSleepSettings = hasSleepSettings
        self.verification = verification
    }

    public static let cherryVendorID: UInt16 = 0x046A

    public static func matching(vendorID: UInt16, productID: UInt16) -> KeyboardModel? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    public func effect(_ rawValue: UInt8) -> LightingEffect? {
        lightingEffects.first { $0.rawValue == rawValue }
    }

    /// Profile fields this app may change, limited to the bytes the official driver writes for this product ID.
    public var editableFields: Set<ProfileField> {
        var fields: Set<ProfileField>
        switch lighting {
        case .none: fields = []
        case .singleColor: fields = [.effect, .brightness, .speed]
        case .rgb: fields = [.effect, .brightness, .speed, .randomColor, .color]
        }
        if hasSleepSettings { fields.formUnion([.sleepSeconds, .deepSleepMinutes]) }
        return fields
    }

    /// The fields of `settings` (e.g. a preset) this model can take: the editable ones, and the effect only when it is
    /// in this model's table.
    public func applicableFields(of settings: ProfileSettings) -> Set<ProfileField> {
        var fields = editableFields
        if effect(settings.effect) == nil { fields.remove(.effect) }
        return fields
    }

    /// `base` with the applicable fields of `settings` copied over.
    public func applying(_ settings: ProfileSettings, onto base: ProfileSettings) -> ProfileSettings {
        var result = base
        for field in applicableFields(of: settings) { field.copy(from: settings, into: &result) }
        return result
    }

    public var hasLighting: Bool { lighting != .none }
    public var hasColor: Bool { lighting == .rgb }
    /// Battery (0x1A) and the status block (0x1D) are only read from wireless products.
    public var hasBattery: Bool { isWireless }
    public var canFlashFirmware: Bool { ota != nil && firmwareFamily == .telinkUSBOTA }
}

/// Rows of CHERRY Utility's `DefaultData/default_light.json` (indexed by the driver's DeviceIndex), visible entries only,
/// in the official display order; names from the driver's `lan_cn.xml` / `lan_en.xml`.
extension LightingEffect {
    /// The table most models use (DeviceIndex 0, 6, 7, 51 = PIXIU 75, …).
    public static let standard: [LightingEffect] = [
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

    /// Table 51 (PIXIU 75), verified on hardware.
    public static let pixiu75 = standard

    /// Single-colour backlight boards (DeviceIndex 4, 13, 14, 19).
    public static let singleColor: [LightingEffect] = [
        LightingEffect(rawValue: 0, name: "波纹", englishName: "Wave"),
        LightingEffect(rawValue: 2, name: "呼吸", englishName: "Breathing"),
        LightingEffect(rawValue: 18, name: "放射", englishName: "Radiation"),
        LightingEffect(rawValue: 21, name: "单点亮", englishName: "Single Key"),
        LightingEffect(rawValue: 3, name: "常亮", englishName: "Static"),
        LightingEffect(rawValue: 8, name: "自定义", englishName: "Custom"),
    ]

    /// MX 8.3 / PIXIU 98 / MX 8.3 Pro (DeviceIndex 52, 54, 60): a different firmware numbering —
    /// here 8 is Breathing and 4 is Custom.
    public static let typeB: [LightingEffect] = [
        LightingEffect(rawValue: 6, name: "波纹", englishName: "Wave"),
        LightingEffect(rawValue: 7, name: "光谱", englishName: "Spectrum"),
        LightingEffect(rawValue: 8, name: "呼吸", englishName: "Breathing"),
        LightingEffect(rawValue: 9, name: "霓虹", englishName: "Rolling"),
        LightingEffect(rawValue: 5, name: "彩虹雨", englishName: "Rainbow Rain"),
        LightingEffect(rawValue: 10, name: "曲线", englishName: "Curve"),
        LightingEffect(rawValue: 11, name: "折返", englishName: "Scan"),
        LightingEffect(rawValue: 0, name: "放射", englishName: "Radiation"),
        LightingEffect(rawValue: 1, name: "扩散", englishName: "Ripples"),
        LightingEffect(rawValue: 2, name: "单点亮", englishName: "Single Key"),
        LightingEffect(rawValue: 3, name: "常亮", englishName: "Static"),
        LightingEffect(rawValue: 4, name: "自定义", englishName: "Custom"),
    ]

    /// MX 10.1 (DeviceIndex 55): type B without Rainbow Rain.
    public static let typeBWithoutRainbowRain = typeB.filter { $0.rawValue != 5 }

    /// Extra effects of special editions, appended to the standard table.
    public static let rgbStatic = LightingEffect(rawValue: 22, name: "RGB常亮", englishName: "RGB Static")
    public static let lightning = LightingEffect(rawValue: 23, name: "闪电", englishName: "Lightning")
    public static let flame = LightingEffect(rawValue: 24, name: "火焰", englishName: "Flame")
    public static let battle = LightingEffect(rawValue: 23, name: "对战", englishName: "Battle")

    /// The per-key "custom" effect uses colours stored in the keyboard, which this app does not edit.
    public var isCustom: Bool { englishName == "Custom" }
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
