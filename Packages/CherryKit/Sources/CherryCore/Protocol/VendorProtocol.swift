import Foundation

/// CHERRY Utility's private configuration protocol (UsagePage 0xFF1C, 64-byte report #4).
///
/// Request:  `[rid][sum lo][sum hi][cmd][len][off lo][off hi][b7] payload…`  with sum = Σ bytes 3…63
/// Response: echoes bytes 3…7, byte 7 is the status (0xFF / 0xFE = error), payload starts at byte 8.
///
/// Writes follow the driver's `sub_4dd640`: payload in bytes 8…, byte 7 = 0x55, bracketed by
/// `beginConfig` / `endConfig` (`sub_4d9eb0` / `sub_4da0e0`). Verified on a PIXIU 75 (firmware 0117).
public enum VendorCommand: UInt8, Sendable, CaseIterable {
    case beginConfig = 0x01
    case endConfig = 0x02
    /// Configuration space: byte 0 = active profile, profile n at offset n·64.
    case readConfig = 0x05
    case writeConfig = 0x06
    /// Key map table (3 bytes per key).
    case readKeymap = 0x07
    case readBattery = 0x1A
    case readDeviceStatus = 0x1D
}

public enum VendorPacket {
    public static let reportLength = 64
    public static let headerLength = 8
    public static let maxChunk = reportLength - headerLength
    /// Byte 7 of a write request (the driver's non-dongle variant).
    public static let writeMarker: UInt8 = 0x55

    public static func request(_ command: VendorCommand, length: Int, offset: Int, reportID: UInt8) -> [UInt8] {
        precondition((1...maxChunk).contains(length) && (0...0xFFFF).contains(offset))
        return frame(command, length: length, offset: offset, marker: 0, payload: [], reportID: reportID)
    }

    /// `writeConfig` request carrying `payload` (1…56 bytes) for `offset`.
    public static func write(payload: [UInt8], offset: Int, reportID: UInt8) -> [UInt8] {
        precondition((1...maxChunk).contains(payload.count) && (0...0xFFFF).contains(offset))
        return frame(.writeConfig, length: payload.count, offset: offset, marker: writeMarker, payload: payload, reportID: reportID)
    }

    /// Payload-less command such as `beginConfig` / `endConfig`.
    public static func control(_ command: VendorCommand, reportID: UInt8) -> [UInt8] {
        frame(command, length: 0, offset: 0, marker: 0, payload: [], reportID: reportID)
    }

    private static func frame(
        _ command: VendorCommand, length: Int, offset: Int, marker: UInt8, payload: [UInt8], reportID: UInt8
    ) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: reportLength)
        p[0] = reportID
        p[3] = command.rawValue
        p[4] = UInt8(length)
        p[5] = UInt8(offset & 0xFF)
        p[6] = UInt8(offset >> 8)
        p[7] = marker
        p.replaceSubrange(headerLength..<headerLength + payload.count, with: payload)
        let sum = Checksums.vendorSum(p[3...])
        p[1] = UInt8(sum & 0xFF)
        p[2] = UInt8(sum >> 8)
        return p
    }

    /// True if `reply` answers `request` (same report ID and echoed command/length/offset).
    public static func matches(_ reply: [UInt8], request: [UInt8]) -> Bool {
        reply.count >= headerLength && reply[0] == request[0] && Array(reply[3...6]) == Array(request[3...6])
    }

    /// Throws if the device flagged `reply` as an error.
    public static func checkStatus(of reply: [UInt8], for request: [UInt8]) throws {
        guard matches(reply, request: request) else { throw CherryError.malformedReply("回复与请求不匹配") }
        let status = reply[7]
        guard status != 0xFF && status != 0xFE else {
            throw CherryError.deviceRejected(command: request[3], status: status)
        }
    }

    public static func payload(of reply: [UInt8], for request: [UInt8]) throws -> [UInt8] {
        try checkStatus(of: reply, for: request)
        let length = Int(request[4])
        guard reply.count >= headerLength + length else { throw CherryError.malformedReply("回复长度不足") }
        return Array(reply[headerLength..<headerLength + length])
    }
}
