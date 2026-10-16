import Foundation
import Synchronization

/// 正在刷写固件的键盘。刷写期间键盘会重启，自动化（可能在无人值守时由定时触发）不能插入配置写入。
public final class FirmwareActivity: Sendable {
    private let busy = Mutex<[KeyboardID: Int]>([:])

    public init() {}

    public func isBusy(_ keyboard: KeyboardID) -> Bool {
        busy.withLock { $0[keyboard, default: 0] > 0 }
    }

    /// Marks `keyboard` busy while `body` runs, including when it throws or is cancelled.
    public func during<T: Sendable>(_ keyboard: KeyboardID, _ body: () async throws -> T) async throws -> T {
        busy.withLock { $0[keyboard, default: 0] += 1 }
        defer {
            busy.withLock { counts in
                let remaining = counts[keyboard, default: 1] - 1
                counts[keyboard] = remaining > 0 ? remaining : nil
            }
        }
        return try await body()
    }
}
