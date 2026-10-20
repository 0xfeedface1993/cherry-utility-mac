import Foundation

/// 注入的小型同步端口。关闭时不会生成 UUID、payload 或后台任务。
public struct Diagnostics: Sendable {
    public var isEnabled: @Sendable () -> Bool
    public var now: @Sendable () -> UInt64
    private let beginImpl: @Sendable (DiagnosticOperation, TraceContext?, DiagnosticOrigin, DiagnosticMetrics) -> DiagnosticSpan
    private let emitImpl: @Sendable (DiagnosticOperation, TraceContext?, DiagnosticOrigin, DiagnosticOutcome?, DiagnosticMetrics) -> Void

    public init(isEnabled: @escaping @Sendable () -> Bool = { true }, now: @escaping @Sendable () -> UInt64,
                begin: @escaping @Sendable (DiagnosticOperation, TraceContext?, DiagnosticOrigin, DiagnosticMetrics) -> DiagnosticSpan,
                emit: @escaping @Sendable (DiagnosticOperation, TraceContext?, DiagnosticOrigin, DiagnosticOutcome?, DiagnosticMetrics) -> Void) {
        self.isEnabled = isEnabled; self.now = now; beginImpl = begin; emitImpl = emit
    }

    public static let noop = Diagnostics(isEnabled: { false }, now: { 0 }, begin: { _, _, _, _ in .disabled }, emit: { _, _, _, _, _ in })

    public func begin(_ operation: DiagnosticOperation, context: TraceContext? = TraceContext.current,
                      origin: DiagnosticOrigin = DiagnosticOrigin.current ?? .background, metrics: DiagnosticMetrics = .init()) -> DiagnosticSpan {
        guard isEnabled() else { return .disabled }
        return beginImpl(operation, context, origin, metrics)
    }

    public func emit(_ operation: DiagnosticOperation, context: TraceContext? = TraceContext.current,
                     origin: DiagnosticOrigin = DiagnosticOrigin.current ?? .background, outcome: DiagnosticOutcome? = nil, metrics: DiagnosticMetrics = .init()) {
        guard isEnabled() else { return }
        emitImpl(operation, context, origin, outcome, metrics)
    }

    public func measure<T>(_ operation: DiagnosticOperation, origin: DiagnosticOrigin = DiagnosticOrigin.current ?? .background,
                           metrics: DiagnosticMetrics = .init(), _ body: () throws -> T) rethrows -> T {
        guard isEnabled() else { return try body() }
        let span = begin(operation, origin: origin, metrics: metrics)
        do {
            let value = try TraceContext.$current.withValue(span.context, operation: { try body() })
            span.finish()
            return value
        } catch { span.finish(error: error); throw error }
    }

    public func measure<T: Sendable>(_ operation: DiagnosticOperation, origin: DiagnosticOrigin = DiagnosticOrigin.current ?? .background,
                                    metrics: DiagnosticMetrics = .init(), _ body: @Sendable () async throws -> T) async rethrows -> T {
        try await measure(operation, origin: origin, metrics: metrics, outcome: { _ in .success }, body)
    }

    /// 正常返回也可能是不同业务终态（timeout、noChange、unconfirmed…）；由 `outcome` 从返回值推导，抛错仍按错误分类。
    public func measure<T: Sendable>(_ operation: DiagnosticOperation, origin: DiagnosticOrigin = DiagnosticOrigin.current ?? .background,
                                    metrics: DiagnosticMetrics = .init(), outcome: @Sendable (T) -> DiagnosticOutcome,
                                    _ body: @Sendable () async throws -> T) async rethrows -> T {
        guard isEnabled() else { return try await body() }
        let span = begin(operation, origin: origin, metrics: metrics)
        do {
            let value = try await TraceContext.$current.withValue(span.context, operation: { try await body() })
            span.finish(outcome(value))
            return value
        } catch { span.finish(error: error); throw error }
    }

    /// 测试与适配器共用的生命周期实现；sink 不得在调用线程执行阻塞 I/O。
    public static func recording(clock: DiagnosticClock = .continuous(), sink: @escaping @Sendable (DiagnosticEvent) -> Void) -> Self {
        Self(now: clock.now, begin: { operation, parent, origin, metrics in
            let context = TraceContext(parent: parent, origin: origin)
            let start = clock.now()
            sink(.init(operation: operation, phase: .began, context: context, metrics: metrics, elapsedNs: start))
            return DiagnosticSpan(context: context) { outcome, failure, final in
                let now = clock.now()
                var combined = final
                combined.durationNs = now >= start ? now - start : 0
                sink(.init(operation: operation, phase: .finished, context: context, outcome: outcome,
                           failure: failure, metrics: combined, elapsedNs: now))
            }
        }, emit: { operation, context, origin, outcome, metrics in
            sink(.init(operation: operation, phase: .summary, context: context ?? TraceContext(origin: origin),
                       outcome: outcome, metrics: metrics, elapsedNs: clock.now()))
        })
    }
}
