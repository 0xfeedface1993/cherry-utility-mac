import Foundation

/// A named copy of a profile's settings kept on this Mac, to be loaded into any onboard profile later.
public struct ProfilePreset: Equatable, Sendable, Codable, Identifiable {
    public static let fileExtension = "cherryprofile"

    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// USB product ID of the keyboard the preset was captured from (effect values are model specific).
    public var productID: UInt16?
    public var settings: ProfileSettings

    public init(id: UUID = UUID(), name: String, createdAt: Date, productID: UInt16?, settings: ProfileSettings) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.productID = productID
        self.settings = settings
    }

    public func isCompatible(with keyboard: KeyboardSummary) -> Bool {
        productID == nil || productID == keyboard.id.productID
    }

    /// What loading this preset into a profile of `model` writes: only the fields the model can take.
    public func patch(for model: KeyboardModel) -> ProfilePatch {
        ProfilePatch(settings, fields: model.applicableFields(of: settings))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ProfilePreset {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ProfilePreset.self, from: data)
        } catch {
            throw CherryError.presetFormat("无法解析预设文件")
        }
    }
}
