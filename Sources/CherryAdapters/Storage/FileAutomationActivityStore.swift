import CherryCore
import Darwin
import Foundation

/// The shared activity record: `automation-activity.json` in the data directory both processes use. Each record is a
/// read-modify-write under an exclusive `flock` on a sibling lock file, so the app and a `cherry` process recording at the
/// same moment do not lose each other's call; the JSON itself is replaced atomically, so readers never see half a file.
public struct FileAutomationActivityStore: AutomationActivityStore {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> AutomationActivity {
        guard let data = try? Data(contentsOf: file) else { return AutomationActivity() }
        return (try? Self.decoder.decode(AutomationActivity.self, from: data)) ?? AutomationActivity()
    }

    public func record(_ call: AutomationCall) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = file.path + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CherryError.storage("无法打开 \(lockPath)：\(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        // Held only for one small read and write.
        guard flock(descriptor, LOCK_EX) == 0 else { throw CherryError.storage("无法锁定 \(lockPath)") }
        defer { flock(descriptor, LOCK_UN) }
        let next = load().recording(call)
        do {
            try Self.encoder.encode(next).write(to: file, options: .atomic)
        } catch {
            throw CherryError.storage("无法写入 \(file.path)：\(error.localizedDescription)")
        }
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
