import Foundation

/// Firmware + target parameters extracted from a Cherry per-model updater (Telink "USB_OTA" .NET exe).
///
/// Layout (from `usb_Form.load_param()` in the updater):
/// - `param_128K`: [64..67] VID, [68..71] PID (ASCII hex), [72..73] report ID (ASCII decimal),
///   [80..] UsagePage (ASCII hex, 0xFF-terminated)
/// - `code_2M`: [48..51] firmware size (big-endian), [256..] Telink image whose last 4 bytes are its CRC32
public struct UpdaterImage: Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let reportID: UInt8
    public let usagePage: UInt16
    public let firmware: [UInt8]
    public let embeddedCRC: UInt32

    public static let maxFirmwareSize = 2 * 1024 * 1024

    public init(updaterExe data: Data) throws {
        let res = DotNetResources.byteArrays(in: data)
        guard let param = res["param_128K"], let code = res["code_2M"] else {
            throw CherryError.firmwareFormat("不是 Telink USB_OTA 升级程序（缺少 code_2M / param_128K 资源）")
        }
        try self.init(param: [UInt8](param), code: [UInt8](code))
    }

    public init(param p: [UInt8], code c: [UInt8]) throws {
        guard p.count >= 96, c.count > 256 else { throw CherryError.firmwareFormat("参数或固件资源过小") }

        func ascii(_ range: Range<Int>) -> String {
            String(decoding: p[range].prefix { $0 != 0xFF && $0 != 0 }, as: UTF8.self)
        }
        guard let vid = UInt16(ascii(64..<68), radix: 16),
              let pid = UInt16(ascii(68..<72), radix: 16),
              let rid = UInt8(ascii(72..<74).trimmingCharacters(in: .whitespaces)),
              let page = UInt16(ascii(80..<96), radix: 16)
        else { throw CherryError.firmwareFormat("无法解析 VID/PID/ReportID/UsagePage") }

        let size = Int(c[48]) << 24 | Int(c[49]) << 16 | Int(c[50]) << 8 | Int(c[51])
        guard size > 0x20, size < Self.maxFirmwareSize, 256 + size <= c.count else {
            throw CherryError.firmwareFormat("固件大小异常 \(size)")
        }
        let fw = Array(c[256..<256 + size])

        vendorID = vid
        productID = pid
        reportID = rid
        usagePage = page
        firmware = fw
        embeddedCRC = UInt32(fw[size - 4]) | UInt32(fw[size - 3]) << 8 | UInt32(fw[size - 2]) << 16 | UInt32(fw[size - 1]) << 24
    }

    /// Telink image size field at 0x18 (little-endian).
    public var headerSize: UInt32 {
        UInt32(firmware[0x18]) | UInt32(firmware[0x19]) << 8 | UInt32(firmware[0x1A]) << 16 | UInt32(firmware[0x1B]) << 24
    }

    public var computedCRC: UInt32 { Checksums.telinkCRC32(firmware.dropLast(4)) }

    /// Same acceptance rules as the updater (`check_bin_is_ok`), plus a full CRC and header-size check.
    public func validate() throws {
        if embeddedCRC == 0 || embeddedCRC == 0xFFFF_FFFF {
            throw CherryError.checksumMismatch("固件 CRC 为 0 或 0xFFFFFFFF")
        }
        let computed = computedCRC
        guard computed == embeddedCRC else {
            throw CherryError.checksumMismatch(String(format: "固件 CRC 0x%08X ≠ 计算值 0x%08X", embeddedCRC, computed))
        }
        guard Int(headerSize) == firmware.count else {
            throw CherryError.firmwareFormat("Telink 头部长度 \(headerSize) ≠ 镜像长度 \(firmware.count)")
        }
        guard firmware.count / 16 < 0xFFFF else { throw CherryError.firmwareFormat("固件超出 16 位包序号范围") }
    }
}

public enum Checksums {
    private static let crc32Table: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i)
        for _ in 0..<8 { r = (r & 1) != 0 ? (r >> 1) ^ 0xEDB8_8320 : r >> 1 }
        return r
    }

    /// Telink image CRC: reflected 0xEDB88320, init 0xFFFFFFFF, no final xor.
    public static func telinkCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(b)) & 0xFF)] }
        return crc
    }

    /// Per-packet OTA CRC-16: init 0xFFFF, reflected poly 0xA001, no final xor.
    public static func otaCRC16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            var v = UInt16(b)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (((crc ^ v) & 1) != 0 ? 0xA001 : 0)
                v >>= 1
            }
        }
        return crc
    }

    /// Vendor-channel checksum: 16-bit sum of bytes 3…63 of the request.
    public static func vendorSum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        UInt16(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
    }
}
