import Foundation

/// What a keyboard runs, judged from the image CRC it reports over the OTA channel.
public enum InstalledFirmware: Hashable, Sendable {
    /// The stock image of a known definition.
    case stock(definitionID: String)
    /// The image a saved variant builds today.
    case variant(id: UUID, definitionID: String)
    /// An image this app flashed earlier whose variant has since been changed or deleted.
    case earlierBuild(FirmwareFlashRecord)
    /// Not an image the app knows (another tool's patch, a newer official release…).
    case unknown(crc: UInt32)

    /// Stock images win over variants (a variant with only stock choices builds the stock image); among variants the
    /// one flashed most recently wins, then the most recently edited; flash records are the fallback.
    public static func identify(
        crc: UInt32,
        definitions: [FirmwareDefinition],
        variants: [FirmwareVariant],
        records: [FirmwareFlashRecord]
    ) -> InstalledFirmware {
        if let definition = definitions.first(where: { $0.firmware.crc == crc }) {
            return .stock(definitionID: definition.id)
        }
        let newestFlash = records.filter { $0.crc == crc }.max { $0.date < $1.date }
        let candidates = variants.filter { $0.builtCRC == crc }
        if let flashed = newestFlash?.variantID, let variant = candidates.first(where: { $0.id == flashed }) {
            return .variant(id: variant.id, definitionID: variant.definitionID)
        }
        if let variant = candidates.max(by: { $0.updatedAt < $1.updatedAt }) {
            return .variant(id: variant.id, definitionID: variant.definitionID)
        }
        if let newestFlash { return .earlierBuild(newestFlash) }
        return .unknown(crc: crc)
    }
}
