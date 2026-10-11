import CherryCore
import Foundation
import Synchronization

/// Hand-off of input reports from the HID thread (synchronous producer) to one async consumer.
///
/// Execution model: `Mutex`-protected state, because the producer is a synchronous IOKit callback.
/// Critical sections only copy state; continuations are resumed after the lock is released.
/// Back-pressure: the device sends at most one report per request in both protocols; the buffer is
/// bounded (`capacity`, oldest dropped) to cap memory if nobody is reading.
final class ReportMailbox: Sendable {
    typealias Waiter = CheckedContinuation<[UInt8]?, any Error>

    private struct State {
        var buffer: [[UInt8]] = []
        var waiter: (id: UInt64, continuation: Waiter)?
        var closed = false
        var nextWaiterID: UInt64 = 0
    }

    static let capacity = 256
    private let state = Mutex(State())

    /// Producer side, called on the HID thread.
    func push(_ report: [UInt8]) {
        let waiter: Waiter? = state.withLock { s in
            guard !s.closed else { return nil }
            if let w = s.waiter {
                s.waiter = nil
                return w.continuation
            }
            s.buffer.append(report)
            if s.buffer.count > Self.capacity { s.buffer.removeFirst() }
            return nil
        }
        waiter?.resume(returning: report)
    }

    func close() {
        let waiter: Waiter? = state.withLock { s in
            s.closed = true
            s.buffer.removeAll()
            defer { s.waiter = nil }
            return s.waiter?.continuation
        }
        waiter?.resume(throwing: CherryError.disconnected)
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    func drain() {
        state.withLock { $0.buffer.removeAll() }
    }

    /// Next report, nil on timeout, `CherryError.disconnected` once closed.
    func next(timeout: Duration) async throws -> [UInt8]? {
        try await withThrowingTaskGroup(of: [UInt8]?.self) { group in
            group.addTask { try await self.waitNext() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            // The timeout won; a report that raced it may still have reached the waiter – keep it.
            while let late = try? await group.next() {
                if let late { return late }
            }
            return nil
        }
    }

    private func waitNext() async throws -> [UInt8]? {
        let id = state.withLock { s -> UInt64 in
            s.nextWaiterID &+= 1
            return s.nextWaiterID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                let immediate: Result<[UInt8]?, any Error>? = state.withLock { s in
                    if !s.buffer.isEmpty { return .success(s.buffer.removeFirst()) }
                    if s.closed { return .failure(CherryError.disconnected) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if s.waiter != nil { return .failure(CherryError.ioFailed("同一通道上存在并发读取")) }
                    s.waiter = (id, continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { s in
                guard let w = s.waiter, w.id == id else { return nil }
                s.waiter = nil
                return w.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
