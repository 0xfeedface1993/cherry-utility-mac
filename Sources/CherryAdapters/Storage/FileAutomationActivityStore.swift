import CherryCore
import Darwin
import Foundation

/// The shared activity record: `automation-activity.json` in the data directory both processes use.
///
/// Every access locks the file itself with `flock`: a record is a read-modify-write under an exclusive lock, so the app
/// and a `cherry` process recording at the same moment do not lose each other's call, and a load takes a shared lock,
/// so it never sees a half-written file. The JSON is rewritten in place (`ftruncate` + `pwrite`) instead of through a
/// temporary file, `fsync` and `rename`: those cost about 0.7 ms per automation call for a few hundred bytes of display
/// statistics (measured 2026-10-18). A crash in the middle of a write leaves an unreadable file, which loads as an empty
/// record.
public struct FileAutomationActivityStore: AutomationActivityStore {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> AutomationActivity {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return AutomationActivity() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH) == 0 else { return AutomationActivity() }
        defer { flock(descriptor, LOCK_UN) }
        return Self.decode(Self.contents(of: descriptor))
    }

    public func record(_ call: AutomationCall) throws -> AutomationActivity {
        var descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if descriptor < 0, errno == ENOENT {
            // 数据目录还不存在：只在第一次建，不在每次调用时都去 stat 一遍目录。
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw CherryError.storage("无法打开 \(file.path)：\(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        // Held only for one small read and write.
        guard flock(descriptor, LOCK_EX) == 0 else { throw CherryError.storage("无法锁定 \(file.path)") }
        defer { flock(descriptor, LOCK_UN) }
        // 文件里的日期是 ISO 8601，只到秒；先截掉小数，返回的记录才与写进文件、其他进程读到的完全相同。
        var call = call
        call.date = Date(timeIntervalSince1970: call.date.timeIntervalSince1970.rounded(.down))
        let next = Self.decode(Self.contents(of: descriptor)).recording(call)
        let data: Data
        do {
            data = try Self.encoder.encode(next)
        } catch {
            throw CherryError.storage("无法编码调用记录：\(error.localizedDescription)")
        }
        guard ftruncate(descriptor, 0) == 0, Self.write(data, to: descriptor) else {
            throw CherryError.storage("无法写入 \(file.path)：\(String(cString: strerror(errno)))")
        }
        return next
    }

    private static func contents(of descriptor: Int32) -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return Data() }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        return count > 0 ? data.prefix(count) : Data()
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = pwrite(descriptor, buffer.baseAddress! + offset, buffer.count - offset, off_t(offset))
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func decode(_ data: Data) -> AutomationActivity {
        guard !data.isEmpty else { return AutomationActivity() }
        return (try? decoder.decode(AutomationActivity.self, from: data)) ?? AutomationActivity()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
