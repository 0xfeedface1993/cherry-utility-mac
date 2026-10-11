import Foundation
import Synchronization

/// FIFO async gate: at most one holder per key, later callers wait in arrival order.
///
/// Execution model: `Mutex` (not an actor) because a waiter's cancellation handler is synchronous and must remove
/// the waiter atomically with respect to a concurrent hand-off. Critical sections only mutate the tables; every
/// continuation is resumed after the lock is released.
public final class ChannelGate<Key: Hashable & Sendable>: Sendable {
    private typealias Waiter = (id: UInt64, continuation: CheckedContinuation<Void, any Error>)

    private struct State {
        var held: Set<Key> = []
        var waiters: [Key: [Waiter]] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func acquire(_ key: Key) async throws {
        try Task.checkCancellation()
        let id = state.withLock { s -> UInt64 in
            s.nextID &+= 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if s.held.insert(key).inserted { return .success(()) }
                    s.waiters[key, default: []].append((id, continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, any Error>? = state.withLock { s in
                guard let index = s.waiters[key]?.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters[key]?.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Hands the key to the next waiter, or frees it.
    public func release(_ key: Key) {
        let next: CheckedContinuation<Void, any Error>? = state.withLock { s in
            if var queue = s.waiters[key], !queue.isEmpty {
                let waiter = queue.removeFirst()
                s.waiters[key] = queue.isEmpty ? nil : queue
                return waiter.continuation // ownership passes on; the key stays held
            }
            s.held.remove(key)
            return nil
        }
        next?.resume()
    }

    public func isHeld(_ key: Key) -> Bool { state.withLock { $0.held.contains(key) } }
}

/// Decorator that gives callers exclusive, queued access to one interface of one keyboard: a second user
/// (menu-bar poll, settings screen, firmware check…) waits for the first channel to be closed instead of failing.
public struct ExclusiveChannelProvider: ReportChannelProvider {
    public struct Key: Hashable, Sendable {
        let keyboard: KeyboardID
        let usagePage: UInt16
    }

    private let base: any ReportChannelProvider
    private let gate: ChannelGate<Key>

    public init(base: any ReportChannelProvider, gate: ChannelGate<Key> = ChannelGate()) {
        self.base = base
        self.gate = gate
    }

    public func openChannel(keyboard: KeyboardID, usagePage: UInt16, reportID: UInt8) async throws -> any HIDReportChannel {
        let key = Key(keyboard: keyboard, usagePage: usagePage)
        try await gate.acquire(key)
        do {
            let channel = try await base.openChannel(keyboard: keyboard, usagePage: usagePage, reportID: reportID)
            return GatedChannel(base: channel) { [gate] in gate.release(key) }
        } catch {
            gate.release(key)
            throw error
        }
    }
}

/// Releases its gate exactly once: on `close()`, or when dropped without being closed.
final class GatedChannel: HIDReportChannel {
    private let base: any HIDReportChannel
    private let releaser: Mutex<(@Sendable () -> Void)?>

    init(base: any HIDReportChannel, release: @escaping @Sendable () -> Void) {
        self.base = base
        self.releaser = Mutex(release)
    }

    deinit { releaseOnce() }

    var outputReportLength: Int { base.outputReportLength }
    var inputReportIDs: Set<UInt8> { base.inputReportIDs }

    func send(_ report: [UInt8]) async throws { try await base.send(report) }
    func receive(timeout: Duration) async throws -> [UInt8]? { try await base.receive(timeout: timeout) }
    func discardPending() async { await base.discardPending() }

    func close() async {
        await base.close()
        releaseOnce()
    }

    private func releaseOnce() {
        let release = releaser.withLock { r -> (@Sendable () -> Void)? in
            defer { r = nil }
            return r
        }
        release?()
    }
}
