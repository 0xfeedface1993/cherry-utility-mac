import Foundation

// Driven ports of the custom-firmware use cases.

/// Raw firmware definition files; decoding and validation stay in the core (`FirmwareDefinition.decode`).
public protocol FirmwareDefinitionSource: Sendable {
    func documents() async throws -> [FirmwareDefinitionDocument]
}

public struct FirmwareDefinitionDocument: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// Shipped with the app.
        case bundled
        /// Added by the user (e.g. a definition for another firmware version).
        case user
    }

    public let origin: Origin
    /// File name, for error reports.
    public let name: String
    public let data: Data

    public init(origin: Origin, name: String, data: Data) {
        self.origin = origin
        self.name = name
        self.data = data
    }
}

/// Local library of saved variants.
public protocol FirmwareVariantStore: Sendable {
    func variants() async throws -> [FirmwareVariant]
    func save(_ variant: FirmwareVariant) async throws
    func delete(id: UUID) async throws
}

/// Append-only history of verified flashes.
public protocol FirmwareFlashLog: Sendable {
    /// Newest first.
    func records() async throws -> [FirmwareFlashRecord]
    func append(_ record: FirmwareFlashRecord) async throws
}
