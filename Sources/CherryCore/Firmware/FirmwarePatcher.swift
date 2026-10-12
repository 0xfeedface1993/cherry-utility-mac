import Foundation

/// A patched image built from a definition's stock image and a set of selections.
public struct CustomFirmwareBuild: Sendable {
    public let definitionID: String
    /// Normalized: non-stock choices only.
    public let selections: [String: String]
    /// Edits that change bytes, in offset order.
    public let edits: [ByteEdit]
    public let image: UpdaterImage

    public var crc: UInt32 { image.embeddedCRC }
    public var changedByteCount: Int { edits.reduce(0) { $0 + $1.changedByteCount } }
    /// No option changes the image: the build is the stock image.
    public var isStock: Bool { edits.isEmpty }
}

/// Applies a definition's byte edits to its stock image.
public enum FirmwarePatcher {
    /// Every byte range the definition knows (all values, stock included) that does not hold the expected bytes in
    /// `stock`. Non-empty means the definition was written for another image.
    public static func mismatches(of definition: FirmwareDefinition, in stock: UpdaterImage) -> [DefinitionIssue] {
        var issues: [DefinitionIssue] = []
        for option in definition.options {
            for edit in option.values.flatMap(\.edits) {
                guard edit.range.upperBound <= stock.firmware.count, Array(stock.firmware[edit.range]) == edit.original else {
                    let issue = DefinitionIssue.originalMismatch(option: option.id, offset: edit.offset)
                    if !issues.contains(issue) { issues.append(issue) }
                    continue
                }
            }
        }
        return issues
    }

    public static func build(_ selections: [String: String], definition: FirmwareDefinition, stock: UpdaterImage) throws -> CustomFirmwareBuild {
        guard definition.firmware.matches(stock) else {
            throw CustomFirmwareError.stockMismatch(expectedCRC: definition.firmware.crc, actualCRC: stock.embeddedCRC)
        }
        try stock.validate()
        let resolved = definition.resolve(selections)
        guard resolved.unknown.isEmpty else { throw CustomFirmwareError.unknownSelections(resolved.unknown) }

        var firmware = stock.firmware
        for (option, value) in resolved.changes {
            for edit in value.edits where Array(firmware[edit.range]) != edit.original {
                throw CustomFirmwareError.invalidDefinition(source: definition.id, issues: [.originalMismatch(option: option.id, offset: edit.offset)])
            }
            for edit in value.edits { firmware.replaceSubrange(edit.range, with: edit.replacement) }
        }
        let crc = Checksums.telinkCRC32(firmware.dropLast(4))
        firmware.replaceSubrange(firmware.count - 4 ..< firmware.count, with: withUnsafeBytes(of: crc.littleEndian, Array.init))

        let image = stock.replacingFirmware(firmware)
        try image.validate()
        return CustomFirmwareBuild(
            definitionID: definition.id, selections: definition.normalized(selections), edits: resolved.edits, image: image
        )
    }
}

extension UpdaterImage {
    /// Same OTA target, different firmware bytes. `firmware` must end with its own CRC trailer.
    public func replacingFirmware(_ firmware: [UInt8]) -> UpdaterImage {
        UpdaterImage(vendorID: vendorID, productID: productID, reportID: reportID, usagePage: usagePage, firmware: firmware)
    }

    init(vendorID: UInt16, productID: UInt16, reportID: UInt8, usagePage: UInt16, firmware: [UInt8]) {
        self.vendorID = vendorID
        self.productID = productID
        self.reportID = reportID
        self.usagePage = usagePage
        self.firmware = firmware
        let n = firmware.count
        embeddedCRC = n < 4 ? 0 : UInt32(firmware[n - 4]) | UInt32(firmware[n - 3]) << 8 | UInt32(firmware[n - 2]) << 16 | UInt32(firmware[n - 1]) << 24
    }
}
