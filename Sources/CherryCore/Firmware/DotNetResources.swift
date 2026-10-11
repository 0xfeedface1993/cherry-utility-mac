import Foundation

/// Minimal reader for .NET `.resources` streams (System.Resources.ResourceReader format)
/// embedded in a managed PE. Only extracts `byte[]` entries, which is how the Cherry/Telink
/// updaters store `code_2M` (firmware) and `param_128K` (device parameters).
public enum DotNetResources {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    private static let magic: [UInt8] = [0xCE, 0xCA, 0xEF, 0xBE] // 0xBEEFCACE little-endian
    private static let typeCodeByteArray = 0x20

    /// Scans `data` for every `.resources` stream and returns all byte-array resources by name.
    public static func byteArrays(in data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var result: [String: Data] = [:]
        var i = 0
        while let start = find(magic, in: bytes, from: i) {
            if let entries = try? parseStream(bytes, at: start) {
                result.merge(entries) { a, _ in a }
            }
            i = start + 4
        }
        return result
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == needle[0], hay[i + 1] == needle[1], hay[i + 2] == needle[2], hay[i + 3] == needle[3] {
                return i
            }
            i += 1
        }
        return nil
    }

    private struct Reader {
        let b: [UInt8]
        let base: Int
        var pos: Int

        mutating func u8() throws -> UInt8 {
            guard pos >= 0, pos < b.count else { throw ParseError(description: "unexpected end of resources") }
            defer { pos += 1 }
            return b[pos]
        }

        mutating func i32() throws -> Int {
            guard pos >= 0, pos <= b.count - 4 else { throw ParseError(description: "unexpected end of resources") }
            let v = UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24
            pos += 4
            return Int(Int32(bitPattern: v))
        }

        mutating func encodedInt() throws -> Int {
            var result = 0, shift = 0
            while true {
                let byte = try u8()
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 28 { throw ParseError(description: "bad 7-bit encoded int") }
            }
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard pos >= 0, pos <= b.count, n >= 0, n <= b.count - pos else { throw ParseError(description: "unexpected end of resources") }
            defer { pos += n }
            return Array(b[pos..<pos + n])
        }
    }

    private static func parseStream(_ b: [UInt8], at start: Int) throws -> [String: Data] {
        var r = Reader(b: b, base: start, pos: start + 4)
        _ = try r.i32() // ResourceManager header version
        let skip = try r.i32()
        _ = try r.bytes(skip)
        let version = try r.i32()
        guard version == 2 else { throw ParseError(description: "unsupported .resources version \(version)") }
        let count = try r.i32()
        let typeCount = try r.i32()
        guard (0..<100_000).contains(count), (0..<10_000).contains(typeCount) else {
            throw ParseError(description: "implausible resource counts")
        }
        for _ in 0..<typeCount { _ = try r.bytes(try r.encodedInt()) }
        let align = (r.pos - start) & 7
        if align != 0 { r.pos += 8 - align }
        r.pos += count * 4 // name hashes
        var namePositions: [Int] = []
        for _ in 0..<count { namePositions.append(try r.i32()) }
        let dataSectionOffset = try r.i32()
        let nameSectionOffset = r.pos
        guard dataSectionOffset >= nameSectionOffset - start, start + dataSectionOffset <= b.count else {
            throw ParseError(description: "invalid data section offset")
        }
        let dataSectionStart = start + dataSectionOffset

        var out: [String: Data] = [:]
        for namePos in namePositions {
            guard namePos >= 0, namePos < dataSectionStart - nameSectionOffset else {
                throw ParseError(description: "invalid name offset")
            }
            var n = Reader(b: b, base: start, pos: nameSectionOffset + namePos)
            let nameBytes = try n.bytes(try n.encodedInt())
            guard let name = String(bytes: nameBytes, encoding: .utf16LittleEndian) else { continue }
            let dataPos = try n.i32()
            guard n.pos <= dataSectionStart, dataPos >= 0, dataPos < b.count - dataSectionStart else {
                throw ParseError(description: "invalid resource data offset")
            }
            var d = Reader(b: b, base: start, pos: dataSectionStart + dataPos)
            guard try d.encodedInt() == typeCodeByteArray else { continue }
            let len = try d.i32()
            out[name] = Data(try d.bytes(len))
        }
        return out
    }
}
