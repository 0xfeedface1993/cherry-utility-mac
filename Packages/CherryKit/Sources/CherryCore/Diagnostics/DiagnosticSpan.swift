import Synchronization

/// 终结回调在锁外运行；取消、close 和 deinit 竞速也只输出一次 end。
public final class DiagnosticSpan: Sendable {
    public let context: TraceContext?
    private let end: (@Sendable (DiagnosticOutcome, DiagnosticFailure?, DiagnosticMetrics) -> Void)?
    private let completed = Mutex(false)

    public init(context: TraceContext?, end: (@Sendable (DiagnosticOutcome, DiagnosticFailure?, DiagnosticMetrics) -> Void)? = nil) {
        self.context = context; self.end = end
    }

    public static let disabled = DiagnosticSpan(context: nil)

    public func finish(_ outcome: DiagnosticOutcome = .success, metrics: DiagnosticMetrics = .init(), failure: DiagnosticFailure? = nil) {
        guard let end else { return }
        let first = completed.withLock { done in
            guard !done else { return false }
            done = true
            return true
        }
        if first { end(outcome, failure, metrics) }
    }

    public func finish(error: any Error) {
        let failure = DiagnosticFailure(error)
        finish(failure.outcome, failure: failure)
    }

    deinit { finish(.abandoned) }
}
