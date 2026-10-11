import CherryCore
import Foundation

/// 目录缓存装饰器。每个消费者独立取消，最后一个消费者离开才取消底层请求。
public actor CachedFirmwareCatalog: FirmwareCatalogPort {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<[FirmwareRelease], any Error>]
    }
    private let base: any FirmwareCatalogPort
    private let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cached: (releases: [FirmwareRelease], expires: ContinuousClock.Instant)?
    private var flight: Flight?

    public init(base: any FirmwareCatalogPort, ttl: Duration = .seconds(300),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.base = base; self.ttl = ttl; self.now = now
    }

    public func releases() async throws -> [FirmwareRelease] {
        try Task.checkCancellation()
        if let cached, now() < cached.expires { return cached.releases }
        let waiter = UUID()
        let releases: [FirmwareRelease] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if flight != nil {
                    flight?.waiters[waiter] = continuation
                } else {
                    let id = UUID(), base = base
                    let task = Task {
                        let result: Result<[FirmwareRelease], any Error>
                        do { let releases = try await base.releases(); try Task.checkCancellation(); result = .success(releases) }
                        catch { result = .failure(error) }
                        self.complete(id, result)
                    }
                    flight = Flight(id: id, task: task, waiters: [waiter: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(waiter) }
        }
        try Task.checkCancellation()
        return releases
    }

    private func cancel(_ waiter: UUID) {
        guard let continuation = flight?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flight?.waiters.isEmpty == true { flight?.task.cancel(); flight = nil }
    }

    private func complete(_ id: UUID, _ result: Result<[FirmwareRelease], any Error>) {
        guard let active = flight, active.id == id else { return }
        flight = nil
        if case .success(let releases) = result { cached = (releases, now().advanced(by: ttl)) }
        for continuation in active.waiters.values { continuation.resume(with: result) }
    }
}
