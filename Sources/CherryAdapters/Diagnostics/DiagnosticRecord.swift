import CherryCore
import Foundation

/// journal 的规范记录也是系统日志安全补充的唯一可解析格式。
public struct DiagnosticRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let sequence: UInt64
    public let wallTimeUTC: Date
    public let event: DiagnosticEvent
    enum CodingKeys: String, CodingKey { case schemaVersion, runID = "runId", sequence, wallTimeUTC = "wallTimeUtc", event }
    public var recordID: String { "\(runID.uuidString):\(sequence)" }

    public init(runID: UUID, sequence: UInt64, wallTimeUTC: Date = Date(), event: DiagnosticEvent) {
        schemaVersion = 1; self.runID = runID; self.sequence = sequence; self.wallTimeUTC = wallTimeUTC; self.event = event
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
