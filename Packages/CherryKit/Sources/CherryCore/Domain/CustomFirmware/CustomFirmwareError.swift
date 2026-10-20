import Foundation

/// A problem in a firmware definition file. Any issue rejects the whole definition.
public enum DefinitionIssue: Hashable, Sendable {
    case malformed(String)
    case unsupportedSchema(Int)
    case invalidHex(field: String)
    case duplicateID(String)
    case unknownGroup(option: String, group: String)
    case unknownPalette(option: String, palette: String)
    case noValues(option: String)
    case lengthMismatch(option: String, value: String)
    case outOfRange(option: String, offset: Int)
    case protectedRange(option: String, offset: Int)
    case overlap(option: String, other: String, offset: Int)
    /// The stock image does not contain the bytes the definition expects.
    case originalMismatch(option: String, offset: Int)
}

/// Typed failures of the custom-firmware use cases; Features map them to user-facing text.
public enum CustomFirmwareError: Error, Hashable, Sendable {
    case invalidDefinition(source: String, issues: [DefinitionIssue])
    case definitionNotFound(String)
    case invalidVariant(String)
    /// The catalog has no updater named after the definition's stock image.
    case stockNotInCatalog(String)
    /// The supplied updater is not the definition's stock image.
    case stockMismatch(expectedCRC: UInt32, actualCRC: UInt32)
    /// Selections reference options or values the definition does not have (e.g. a newer definition file was removed).
    case unknownSelections([String])
    /// The variant belongs to another stock image.
    case variantDefinitionMismatch(variant: String, definition: String)
    /// After the flash the keyboard reports a different image.
    case verificationMismatch(expectedCRC: UInt32, actualCRC: UInt32)
}
