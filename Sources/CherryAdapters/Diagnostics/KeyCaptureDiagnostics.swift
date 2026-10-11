import CherryCore
import Foundation

/// IOKit 与模拟键盘共用的按键采集观测：每次订阅是一个设备会话，事件 stamp 和统计都挂在同一个 capture span 下。
struct KeyCaptureDiagnostics: Sendable {
    let diagnostics: Diagnostics
    let capture: DiagnosticSpan

    init(_ diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
        // 在订阅方的任务上创建：origin 来自发起采集的驱动侧。
        let session = diagnostics.isEnabled() ? TraceContext(parent: TraceContext.current, deviceSessionID: UUID()) : nil
        capture = diagnostics.begin(.keyCapture, context: session)
    }

    /// 适配器收到报文时打点；观测关闭时为 nil。
    func stamp() -> DiagnosticStamp? { diagnostics.stamp(context: capture.context) }

    func decoded(since stamp: DiagnosticStamp?) {
        guard let stamp else { return }
        diagnostics.emit(.keyDecode, context: capture.context, metrics: .init(durationNs: diagnostics.elapsed(since: stamp)))
    }

    func yielded(_ result: AsyncThrowingStream<Traced<KeyEvent>, any Error>.Continuation.YieldResult) {
        let dropped: UInt64
        if case .dropped = result { dropped = 1 } else { dropped = 0 }
        diagnostics.emit(.keyStream, context: capture.context, metrics: .init(count: 1, dropped: dropped))
    }

    func finish(_ outcome: DiagnosticOutcome) { capture.finish(outcome) }
    func finish(error: any Error) { capture.finish(error: error) }
}
