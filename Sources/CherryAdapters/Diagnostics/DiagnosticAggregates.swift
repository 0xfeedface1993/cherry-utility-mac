import CherryCore
import Foundation
import Synchronization

/// 固定桶和有界键，不保存逐样本值或按键内容。无数据时不会创建 timer。
final class DiagnosticAggregates: Sendable {
    static let bounds: [UInt64] = [10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000, 50_000_000, 100_000_000, 1_000_000_000]
    struct Key: Hashable { var operation: DiagnosticOperation; var origin: DiagnosticOrigin; var outcome: DiagnosticOutcome? }
    struct Bucket {
        var count: UInt64 = 0, sum: UInt64 = 0, min: UInt64 = .max, max: UInt64 = 0
        var dropped: UInt64 = 0, peak: UInt64 = 0
        var buckets = [UInt64](repeating: 0, count: bounds.count + 1)
        var start: UInt64
        var context: TraceContext?
    }
    private let state = Mutex<[Key: Bucket]>([:])

    func add(_ operation: DiagnosticOperation, duration: UInt64 = 0, dropped: UInt64 = 0, peak: UInt64 = 0,
             context: TraceContext?, origin: DiagnosticOrigin = .background, outcome: DiagnosticOutcome? = nil, now: UInt64) -> DiagnosticEvent? {
        let key = Key(operation: operation, origin: context?.origin ?? origin, outcome: outcome)
        let flushed: Bucket? = state.withLock { values in
            if values[key] == nil && values.count >= 128 { return nil }
            // 取走桶再更新，避免每个样本复制共享的 histogram 数组。
            var bucket = values.removeValue(forKey: key) ?? Bucket(start: now, context: context)
            bucket.count &+= 1; bucket.sum &+= duration
            bucket.min = Swift.min(bucket.min, duration); bucket.max = Swift.max(bucket.max, duration)
            bucket.dropped &+= dropped; bucket.peak = Swift.max(bucket.peak, peak)
            let index = Self.bounds.firstIndex { duration <= $0 } ?? Self.bounds.count
            bucket.buckets[index] &+= 1
            if now >= bucket.start && now - bucket.start >= 1_000_000_000 { return bucket }
            values[key] = bucket
            return nil
        }
        return flushed.map { event(key, $0, now: now) }
    }

    func flush(now: UInt64) -> [DiagnosticEvent] {
        let values = state.withLock { values in let copy = values; values.removeAll(keepingCapacity: true); return copy }
        return values.map { event($0.key, $0.value, now: now) }
    }

    private func event(_ key: Key, _ value: Bucket, now: UInt64) -> DiagnosticEvent {
        var metrics = DiagnosticMetrics(count: value.count, dropped: value.dropped, peak: value.peak)
        metrics.minNs = value.min; metrics.maxNs = value.max; metrics.sumNs = value.sum; metrics.buckets = value.buckets
        metrics.windowNs = now >= value.start ? now - value.start : 0
        return .init(operation: key.operation, phase: .summary, context: value.context ?? TraceContext(origin: key.origin),
                     outcome: key.outcome, metrics: metrics, elapsedNs: now)
    }
}
