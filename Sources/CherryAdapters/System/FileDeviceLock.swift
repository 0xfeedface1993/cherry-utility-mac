import CherryCore
import Darwin
import Foundation
import Synchronization

/// Per-keyboard lease shared by the app and `cherry` processes: `flock` on `<directory>/<VID>-<PID>-<location>.lock`.
///
/// - Within the process leases are counted per keyboard: the first one opens the file and locks it, the last one closes
///   it (closing releases the lock). A second descriptor on the same file in the same process would block on our own
///   lock, so the process holds exactly one. The kernel releases the lock when the process dies.
/// - A firmware update writes `firmwareUpdate` into the file for as long as it holds its lease; a process that finds the
///   file locked reads it and gives up at once instead of waiting through the flash.
/// - Waiting uses `LOCK_NB` and an async back-off, so it can be cancelled and never blocks a cooperative thread. The
///   table is a `Mutex`; only non-blocking calls (`flock(LOCK_NB)`, counting) happen inside it.
public final class FileDeviceLock: DeviceLockPort {
    private struct Held {
        var descriptor: Int32
        var count: Int
        var updates: Int
    }

    private static let updateMarker = "firmwareUpdate"
    private let directory: URL
    private let waitLimit: Duration
    private let held = Mutex<[KeyboardID: Held]>([:])

    public init(directory: URL, waitLimit: Duration = .seconds(20)) {
        self.directory = directory
        self.waitLimit = waitLimit
    }

    public func acquire(_ keyboard: KeyboardID, purpose: DeviceLockPurpose) async throws -> any DeviceLease {
        let path = file(for: keyboard).path
        let deadline = ContinuousClock.now + waitLimit
        var delay = Duration.milliseconds(20)
        while true {
            try Task.checkCancellation()
            switch try attempt(keyboard, path: path, purpose: purpose) {
            case .acquired:
                return Lease { [weak self] in self?.release(keyboard, purpose: purpose) }
            case .heldByAnotherProcess:
                if Self.marker(at: path) == Self.updateMarker { throw CherryError.deviceBusy(.updatingFirmware) }
                guard ContinuousClock.now < deadline else { throw CherryError.deviceBusy(.inUse) }
                try await Task.sleep(for: delay)
                delay = min(delay * 3 / 2, .milliseconds(250))
            }
        }
    }

    private enum Attempt { case acquired, heldByAnotherProcess }

    private func attempt(_ keyboard: KeyboardID, path: String, purpose: DeviceLockPurpose) throws -> Attempt {
        // Fast path: this process already holds the keyboard.
        let joined = held.withLock { table -> Bool in
            guard var entry = table[keyboard] else { return false }
            entry.count += 1
            if purpose == .firmwareUpdate { entry.updates += 1 }
            table[keyboard] = entry
            return true
        }
        if joined {
            if purpose == .firmwareUpdate { writeMarker(Self.updateMarker, for: keyboard) }
            return .acquired
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CherryError.storage("无法打开设备锁 \(path)：\(String(cString: strerror(errno)))") }
        let result = held.withLock { table -> (Attempt, close: Bool) in
            if var entry = table[keyboard] {
                // Another task of this process won the race while the file was being opened.
                entry.count += 1
                if purpose == .firmwareUpdate { entry.updates += 1 }
                table[keyboard] = entry
                return (.acquired, close: true)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return (.heldByAnotherProcess, close: true) }
            table[keyboard] = Held(descriptor: descriptor, count: 1, updates: purpose == .firmwareUpdate ? 1 : 0)
            return (.acquired, close: false)
        }
        if result.close { close(descriptor) }
        if result.0 == .acquired, !result.close {
            // A process that died during a flash leaves its marker behind; the new owner rewrites it.
            writeMarker(purpose == .firmwareUpdate ? Self.updateMarker : "", for: keyboard)
        } else if result.0 == .acquired, purpose == .firmwareUpdate {
            writeMarker(Self.updateMarker, for: keyboard)
        }
        return result.0
    }

    private func release(_ keyboard: KeyboardID, purpose: DeviceLockPurpose) {
        let (closing, clearMarker) = held.withLock { table -> (Int32?, Bool) in
            guard var entry = table[keyboard] else { return (nil, false) }
            entry.count -= 1
            if purpose == .firmwareUpdate { entry.updates -= 1 }
            if entry.count <= 0 {
                table.removeValue(forKey: keyboard)
                return (entry.descriptor, entry.updates <= 0)
            }
            table[keyboard] = entry
            return (nil, purpose == .firmwareUpdate && entry.updates <= 0)
        }
        if clearMarker, let closing { Self.write("", to: closing) }
        else if clearMarker { writeMarker("", for: keyboard) }
        if let closing { close(closing) }
    }

    private func file(for keyboard: KeyboardID) -> URL {
        let name = String(format: "%04X-%04X-%08X.lock", keyboard.vendorID, keyboard.productID, keyboard.locationID)
        return directory.appending(path: name)
    }

    private static func marker(at path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites the marker in place through the descriptor this process holds. Replacing the file (an atomic write)
    /// would give the path a new inode and silently split the lock. The caller holds a lease, so the descriptor stays open.
    private func writeMarker(_ text: String, for keyboard: KeyboardID) {
        guard let descriptor = held.withLock({ $0[keyboard]?.descriptor }) else { return }
        Self.write(text, to: descriptor)
    }

    /// The marker is advisory, so a failed write only costs the faster refusal.
    private static func write(_ text: String, to descriptor: Int32) {
        _ = ftruncate(descriptor, 0)
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    private final class Lease: DeviceLease {
        private let releaser: Mutex<(@Sendable () -> Void)?>

        init(_ release: @escaping @Sendable () -> Void) {
            releaser = Mutex(release)
        }

        deinit { release() }

        func release() {
            let release = releaser.withLock { body -> (@Sendable () -> Void)? in
                defer { body = nil }
                return body
            }
            release?()
        }
    }
}
