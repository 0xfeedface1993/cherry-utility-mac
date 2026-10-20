import Foundation

public enum ControlCodingError: Error, Equatable, Sendable {
    case lineTooLong
    case malformed
}

/// 一条消息编码为一行 JSON（以 `\n` 结尾）。JSON 字符串里的换行总会被转义，所以按行切分是安全的。
public enum ControlCoding {
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: line)
        } catch {
            throw ControlCodingError.malformed
        }
    }

    /// 请求整体解不出来时，尽量取出 `id`，以便回一个对应的错误。
    public static func requestID(in line: Data) -> Int? {
        struct Envelope: Decodable { let id: Int }
        return try? JSONDecoder().decode(Envelope.self, from: line).id
    }
}

/// 把读到的字节切成行；单行超过上限时报错，调用方应断开连接。
public struct LineBuffer: Sendable {
    private var pending = Data()
    private let limit: Int

    public init(limit: Int = ControlProtocol.maxLineLength) {
        self.limit = limit
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        guard pending.count <= limit, lines.allSatisfy({ $0.count <= limit }) else { throw ControlCodingError.lineTooLong }
        return lines
    }
}
