import Foundation

/// Identity of one stock firmware image: the definition's edits are only valid against exactly these bytes.
public struct FirmwareFingerprint: Hashable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    /// Same encoding as bcdDevice and the catalog `VersionCode` (0x0117 ⇔ "0117").
    public let versionCode: UInt16
    /// `Desc` of the catalog entry whose updater carries this image.
    public let catalogName: String
    public let size: Int
    public let crc: UInt32

    public init(vendorID: UInt16, productID: UInt16, versionCode: UInt16, catalogName: String, size: Int, crc: UInt32) {
        self.vendorID = vendorID
        self.productID = productID
        self.versionCode = versionCode
        self.catalogName = catalogName
        self.size = size
        self.crc = crc
    }

    public var version: FirmwareVersion { FirmwareVersion(code: versionCode) }

    public func matches(_ image: UpdaterImage) -> Bool {
        image.vendorID == vendorID && image.productID == productID && image.firmware.count == size && image.embeddedCRC == crc
    }
}

/// Replaces `original` with `replacement` at `offset` of the firmware image.
public struct ByteEdit: Hashable, Sendable {
    public let offset: Int
    public let original: [UInt8]
    public let replacement: [UInt8]

    public init(offset: Int, original: [UInt8], replacement: [UInt8]) {
        self.offset = offset
        self.original = original
        self.replacement = replacement
    }

    public var range: Range<Int> { offset ..< offset + original.count }
    /// Bytes that actually differ from the stock image.
    public var changedByteCount: Int { zip(original, replacement).count { $0 != $1 } }
}

public enum OptionStability: String, Hashable, Sendable {
    /// Behaviour confirmed on hardware.
    case verified
    /// Derived from reverse engineering, not yet confirmed on hardware.
    case experimental
}

/// One choice of an option. The stock value leaves the image untouched.
public struct OptionValue: Hashable, Sendable, Identifiable {
    public let id: String
    /// Empty for a synthesized stock value that has no palette entry; the UI names it.
    public let name: String
    public let isStock: Bool
    public let edits: [ByteEdit]

    public init(id: String, name: String, isStock: Bool, edits: [ByteEdit]) {
        self.id = id
        self.name = name
        self.isStock = isStock
        self.edits = edits
    }

    public var changedByteCount: Int { edits.reduce(0) { $0 + $1.changedByteCount } }
}

public struct OptionGroup: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String?

    public init(id: String, name: String, detail: String?) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// A modifiable feature of the firmware. Exactly one value is selected; the stock value is the default.
public struct CustomizationOption: Hashable, Sendable, Identifiable {
    public let id: String
    public let groupID: String
    public let name: String
    public let detail: String?
    public let stability: OptionStability
    /// Stock value first.
    public let values: [OptionValue]
    /// An on/off switch (an explicit option with a single alternative) rather than a list of choices; slot options
    /// are always choices, however short their palette.
    public let isToggle: Bool

    public init(id: String, groupID: String, name: String, detail: String?, stability: OptionStability, values: [OptionValue], isToggle: Bool) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.detail = detail
        self.stability = stability
        self.values = values
        self.isToggle = isToggle && values.count == 2
    }

    public var stockValue: OptionValue { values.first { $0.isStock } ?? values[0] }

    public func value(_ id: String) -> OptionValue? { values.first { $0.id == id } }
}

/// What can be changed in one stock firmware image. Loaded from a definition file (see `FirmwareDefinition.decode`).
public struct FirmwareDefinition: Hashable, Sendable, Identifiable {
    public static let supportedSchema = 1
    /// Definition files are JSON with this extension.
    public static let fileExtension = "cherryfw"

    public let id: String
    public let name: String
    public let notes: String?
    public let firmware: FirmwareFingerprint
    public let groups: [OptionGroup]
    public let options: [CustomizationOption]

    public init(id: String, name: String, notes: String?, firmware: FirmwareFingerprint, groups: [OptionGroup], options: [CustomizationOption]) {
        self.id = id
        self.name = name
        self.notes = notes
        self.firmware = firmware
        self.groups = groups
        self.options = options
    }

    public func option(_ id: String) -> CustomizationOption? { options.first { $0.id == id } }

    public func options(in group: OptionGroup) -> [CustomizationOption] { options.filter { $0.groupID == group.id } }

    public func applies(to model: KeyboardModel) -> Bool {
        firmware.vendorID == model.vendorID && firmware.productID == model.productID
    }

    /// Bytes the image must keep: Telink header (jump, size, "KNLT" flag) and the CRC trailer.
    public var protectedRanges: [Range<Int>] { [0 ..< 0x30, firmware.size - 4 ..< firmware.size] }
}
