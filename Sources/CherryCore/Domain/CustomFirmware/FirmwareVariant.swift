import Foundation

/// A saved set of choices for one firmware definition ("方案"). Several variants can exist for the same stock image.
public struct FirmwareVariant: Hashable, Sendable, Codable, Identifiable {
    public static let fileExtension = "cherryfirmware"

    public var id: UUID
    public var name: String
    public var definitionID: String
    /// Option ID → value ID, non-stock choices only.
    public var selections: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    /// CRC of the image last built from exactly these selections; nil until built. Used to recognise the variant on a
    /// keyboard without rebuilding.
    public var builtCRC: UInt32?

    public init(
        id: UUID = UUID(), name: String, definitionID: String, selections: [String: String] = [:], createdAt: Date,
        updatedAt: Date? = nil, builtCRC: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.definitionID = definitionID
        self.selections = selections
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.builtCRC = builtCRC
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FirmwareVariant {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FirmwareVariant.self, from: data)
        } catch {
            throw CustomFirmwareError.invalidVariant(String(describing: error))
        }
    }
}

/// One successful, verified flash: which image went onto which keyboard. Lets the app recognise a variant's image
/// on the keyboard even after the variant was edited or deleted.
public struct FirmwareFlashRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var keyboard: KeyboardID
    public var definitionID: String
    public var crc: UInt32
    /// nil when the stock image was restored.
    public var variantID: UUID?
    /// Name and selections at the time of the flash.
    public var variantName: String?
    public var selections: [String: String]

    public init(
        id: UUID = UUID(), date: Date, keyboard: KeyboardID, definitionID: String, crc: UInt32, variantID: UUID?,
        variantName: String?, selections: [String: String]
    ) {
        self.id = id
        self.date = date
        self.keyboard = keyboard
        self.definitionID = definitionID
        self.crc = crc
        self.variantID = variantID
        self.variantName = variantName
        self.selections = selections
    }
}

/// The choice of each option for a set of selections.
public struct ResolvedSelections: Sendable {
    public let choices: [(option: CustomizationOption, value: OptionValue)]
    /// "option" or "option=value" entries the definition does not know.
    public let unknown: [String]

    /// Choices that change the image.
    public var changes: [(option: CustomizationOption, value: OptionValue)] { choices.filter { !$0.value.isStock } }
    public var edits: [ByteEdit] { changes.flatMap(\.value.edits).filter { $0.original != $0.replacement }.sorted { $0.offset < $1.offset } }
    public var changedByteCount: Int { edits.reduce(0) { $0 + $1.changedByteCount } }
}

extension FirmwareDefinition {
    public func resolve(_ selections: [String: String]) -> ResolvedSelections {
        var unknown: [String] = []
        for (optionID, valueID) in selections.sorted(by: { $0.key < $1.key }) {
            guard let option = option(optionID) else {
                unknown.append(optionID)
                continue
            }
            if option.value(valueID) == nil { unknown.append("\(optionID)=\(valueID)") }
        }
        let choices = options.map { option in
            (option, selections[option.id].flatMap(option.value) ?? option.stockValue)
        }
        return ResolvedSelections(choices: choices, unknown: unknown)
    }

    /// Drops stock choices; unknown entries are dropped only when asked (they are reported otherwise).
    public func normalized(_ selections: [String: String], droppingUnknown: Bool = false) -> [String: String] {
        selections.filter { optionID, valueID in
            guard let value = option(optionID)?.value(valueID) else { return !droppingUnknown }
            return !value.isStock
        }
    }
}
