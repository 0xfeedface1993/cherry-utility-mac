import Darwin
import Foundation

/// The simulated keyboard's configuration space in a file, for simulations spread over several processes. Every access
/// holds an exclusive `flock` on `<file>.lock`; the bytes are replaced atomically.
enum SharedConfiguration {
    static func withLock<T>(_ file: URL, _ body: () -> T) -> T {
        let descriptor = open(file.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    static func load(_ file: URL) -> [UInt8]? {
        (try? Data(contentsOf: file)).map(Array.init)
    }

    static func store(_ bytes: [UInt8], _ file: URL) {
        try? Data(bytes).write(to: file, options: .atomic)
    }
}
