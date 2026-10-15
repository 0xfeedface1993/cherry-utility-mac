import CherryCore
import CryptoKit
import Foundation

/// Writes .NET `.resources` streams (version 2, `byte[]` entries only) – the inverse of `DotNetResources`.
enum DotNetResourcesWriter {
    static func stream(byteArrays: [(name: String, bytes: [UInt8])]) -> [UInt8] {
        func i32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: Int32(v).littleEndian, Array.init) }
        func encodedInt(_ v: Int) -> [UInt8] {
            var v = UInt32(v), out: [UInt8] = []
            while v >= 0x80 {
                out.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            return out + [UInt8(v)]
        }

        let readerTypes = Array("System.Resources.ResourceReader".utf8)
        var s: [UInt8] = [0xCE, 0xCA, 0xEF, 0xBE] + i32(1) + i32(readerTypes.count) + readerTypes
        s += i32(2) + i32(byteArrays.count) + i32(0) // version, count, no custom types
        while s.count % 8 != 0 { s.append(0x50) } // "PAD"
        s += [UInt8](repeating: 0, count: byteArrays.count * 4) // name hashes (unused by the reader)

        var names: [UInt8] = [], data: [UInt8] = []
        var namePositions: [Int] = []
        for entry in byteArrays {
            namePositions.append(names.count)
            let utf16 = entry.name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            names += encodedInt(utf16.count) + utf16 + i32(data.count)
            data += encodedInt(0x20) + i32(entry.bytes.count) + entry.bytes
        }
        for position in namePositions { s += i32(position) }
        let dataSectionOffset = s.count + 4 + names.count
        return s + i32(dataSectionOffset) + names + data
    }
}

/// A fake per-model updater "exe": a PE stub followed by the `code_2M` / `param_128K` resources the real Telink
/// updaters carry. Its firmware is a valid Telink-style image that records `version` at offset 0x26, so the
/// simulated keyboard can report the new version after an OTA.
public enum SyntheticUpdater {
    public static let versionOffset = 0x26

    public static func firmware(version: UInt16, size: Int = 6000) -> [UInt8] {
        var fw = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ Int(version)) }
        fw.replaceSubrange(0x18..<0x1C, with: withUnsafeBytes(of: UInt32(size).littleEndian, Array.init))
        fw.replaceSubrange(0x20..<0x24, with: Array("KNLT".utf8))
        fw.replaceSubrange(versionOffset..<versionOffset + 2, with: [UInt8(version & 0xFF), UInt8(version >> 8)])
        let crc = Checksums.telinkCRC32(fw.dropLast(4))
        fw.replaceSubrange(size - 4..<size, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        return fw
    }

    /// A .NET USB_OTA updater for `model` (models without an OTA interface get the Telink one, which they reject).
    public static func updaterExe(for model: KeyboardModel, version: UInt16) -> Data {
        let ota = model.ota ?? .telink
        var param = [UInt8](repeating: 0xFF, count: 128)
        let ids = String(format: "%04X%04X%02d", model.vendorID, model.productID, ota.reportID)
        param.replaceSubrange(64..<64 + ids.utf8.count, with: Array(ids.utf8))
        let page = String(format: "%04X", ota.usagePage)
        param.replaceSubrange(80..<80 + page.utf8.count, with: Array(page.utf8))

        let image = firmware(version: version)
        var code = [UInt8](repeating: 0x00, count: 256)
        let n = UInt32(image.count)
        code.replaceSubrange(48..<52, with: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        code += image + [UInt8](repeating: 0xFF, count: 16)

        let stub = Array("MZ".utf8) + [UInt8](repeating: 0, count: 126)
        return Data(stub + DotNetResourcesWriter.stream(byteArrays: [("param_128K", param), ("code_2M", code)]))
    }

    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
