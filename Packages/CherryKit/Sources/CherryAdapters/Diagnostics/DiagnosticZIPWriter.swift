import CherryCore
import Foundation

/// 标准 ZIP stored 格式，无外部进程；上限由导出策略给出（默认 20 MiB），远小于需要 ZIP64 的 4 GiB。
enum DiagnosticZIPWriter {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB88320) }
        return crc
    }

    static func write(_ entries: [(String, Data)], to url: URL, limit: Int, cancellation: DiagnosticCancellation) throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DiagnosticExportError.storage }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var central = Data(), offset: UInt32 = 0
        func u16(_ value: UInt16, into data: inout Data) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32, into data: inout Data) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        for (name, data) in entries {
            try cancellation.check()
            guard !name.contains("/"), data.count < limit else { throw DiagnosticExportError.tooLarge }
            let filename = Data(name.utf8), size = UInt32(data.count)
            var crc: UInt32 = 0xFFFF_FFFF
            for (index, byte) in data.enumerated() {
                if index % 65536 == 0 { try cancellation.check() }
                crc = Self.crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            crc ^= 0xFFFF_FFFF
            var header = Data()
            u32(0x04034B50, into: &header); u16(20, into: &header); u16(0, into: &header); u16(0, into: &header)
            u16(0, into: &header); u16(0x0021, into: &header); u32(crc, into: &header)
            u32(size, into: &header); u32(size, into: &header); u16(UInt16(filename.count), into: &header); u16(0, into: &header)
            header.append(filename)
            var entry = Data()
            u32(0x02014B50, into: &entry); u16(20, into: &entry); u16(20, into: &entry)
            u16(0, into: &entry); u16(0, into: &entry); u16(0, into: &entry); u16(0x0021, into: &entry)
            u32(crc, into: &entry); u32(size, into: &entry); u32(size, into: &entry)
            u16(UInt16(filename.count), into: &entry); u16(0, into: &entry); u16(0, into: &entry)
            u16(0, into: &entry); u16(0, into: &entry); u32(0, into: &entry); u32(offset, into: &entry)
            entry.append(filename); central.append(entry)
            guard Int(offset) + header.count + data.count + central.count + 22 <= limit else { throw DiagnosticExportError.tooLarge }
            try file.write(contentsOf: header)
            var position = 0
            while position < data.count {
                try cancellation.check()
                let end = min(position + 65536, data.count)
                try file.write(contentsOf: data[position..<end]); position = end
            }
            offset += UInt32(header.count + data.count)
        }
        try file.write(contentsOf: central)
        var end = Data()
        u32(0x06054B50, into: &end); u16(0, into: &end); u16(0, into: &end)
        u16(UInt16(entries.count), into: &end); u16(UInt16(entries.count), into: &end)
        u32(UInt32(central.count), into: &end); u32(offset, into: &end); u16(0, into: &end)
        try file.write(contentsOf: end)
        return Int(offset) + central.count + end.count
    }
}
