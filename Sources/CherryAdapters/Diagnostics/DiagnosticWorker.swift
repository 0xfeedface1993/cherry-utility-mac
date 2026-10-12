import CherryCore
import Foundation
import Synchronization

/// 同步系统 API 无法被 Task 强制终止：停止等待后，worker 检查令牌并拒绝晚到结果。
final class DiagnosticCancellation: Sendable {
    private let cancelled = Mutex(false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
}

enum DiagnosticWorker {
    // DispatchWorkItem 的唯一跨线程操作是其线程安全的 cancel；不修改执行闭包。
    private struct TimerToken: @unchecked Sendable { let item: DispatchWorkItem; func cancel() { item.cancel() } }
    private final class Reply<T: Sendable>: Sendable {
        struct State { var continuation: CheckedContinuation<T, any Error>?; var result: Result<T, any Error>? }
        let state = Mutex(State())
        func install(_ continuation: CheckedContinuation<T, any Error>) {
            let result = state.withLock { s -> Result<T, any Error>? in
                if let result = s.result { return result }
                s.continuation = continuation; return nil
            }
            if let result { continuation.resume(with: result) }
        }
        func finish(_ result: Result<T, any Error>) {
            let continuation = state.withLock { s -> CheckedContinuation<T, any Error>? in
                guard s.result == nil else { return nil }
                s.result = result
                defer { s.continuation = nil }
                return s.continuation
            }
            continuation?.resume(with: result)
        }
    }

    static func run<T: Sendable>(on queue: DispatchQueue, timeout: TimeInterval,
                                onFinish: @escaping @Sendable () -> Void = {},
                                _ body: @escaping @Sendable (DiagnosticCancellation) throws -> T) async throws -> T {
        let reply = Reply<T>(), cancellation = DiagnosticCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                let timer = DispatchWorkItem {
                    cancellation.cancel(); reply.finish(.failure(DiagnosticExportError.timedOut))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                let token = TimerToken(item: timer)
                queue.async {
                    let result = Result { try cancellation.check(); return try body(cancellation) }
                    // 先释放 busy 等状态再交付结果：调用方拿到结果后立即发起的下一次请求不会误报忙。
                    token.cancel(); onFinish()
                    reply.finish(result)
                }
            }
        } onCancel: {
            cancellation.cancel(); reply.finish(.failure(CancellationError()))
        }
    }
}
