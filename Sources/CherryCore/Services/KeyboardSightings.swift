import Foundation
import Synchronization

/// 本次 App 运行期间连接过的键盘。自动化按 ID 选键盘时，只有从没见过的 ID 才回退到唯一的同型号键盘（换了 USB 口）；
/// 见过但已拔出的 ID 报告未找到，同型号的另一把不会被误选。
public final class KeyboardSightings: Sendable {
    private let seen = Mutex<Set<KeyboardID>>([])

    public init() {}

    public func record(_ keyboards: [KeyboardSummary]) {
        let ids = keyboards.map(\.id)
        seen.withLock { $0.formUnion(ids) }
    }

    public func contains(_ id: KeyboardID) -> Bool {
        seen.withLock { $0.contains(id) }
    }
}
