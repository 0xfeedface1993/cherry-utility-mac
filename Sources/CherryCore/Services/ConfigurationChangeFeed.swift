import Foundation
import Synchronization

/// 把自动化入口写入后读回的配置广播给所有订阅者（App 的菜单栏与主窗口；之后的 CLI `watch`）。
/// 每个订阅者只缓冲最新的若干条，慢订阅者不会拖住写入方。
public final class ConfigurationChangeFeed: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<ExternalConfigurationChange>.Continuation]>([:])

    public init() {}

    public func changes() -> AsyncStream<ExternalConfigurationChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: ExternalConfigurationChange.self, bufferingPolicy: .bufferingNewest(8))
        let token = UUID()
        subscribers.withLock { $0[token] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.subscribers.withLock { $0.removeValue(forKey: token) }
        }
        return stream
    }

    public func publish(_ change: ExternalConfigurationChange) {
        let targets = subscribers.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(change) }
    }
}
