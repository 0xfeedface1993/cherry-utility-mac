import CherryCore
import Foundation

/// 发现时缓存的单接口快照，移除只使用对象 token，不读取已失效的 registry 属性。
struct HIDDiscoveryInventory<Token: Hashable> {
    private var entries: [Token: KeyboardSummary] = [:]

    mutating func insert(_ summary: KeyboardSummary, token: Token) { entries[token] = summary }
    mutating func remove(token: Token) -> KeyboardSummary? { entries.removeValue(forKey: token) }

    var summaries: [KeyboardSummary] {
        Dictionary(grouping: entries.values, by: \.id).map { id, interfaces in
            let sorted = interfaces.sorted { ($0.interfaces.first?.id ?? 0) < ($1.interfaces.first?.id ?? 0) }
            let metadata = sorted.first(where: { !$0.transport.isEmpty && $0.transport != "?" }) ?? sorted[0]
            return KeyboardSummary(
                id: id, product: metadata.product, manufacturer: metadata.manufacturer,
                serialNumber: metadata.serialNumber, transport: metadata.transport == "?" ? "" : metadata.transport,
                releaseNumber: metadata.releaseNumber, interfaces: sorted.flatMap(\.interfaces)
            )
        }.sorted { $0.id.description < $1.id.description }
    }
}
