import Foundation

/// 进程内的观测元数据：只在内存中随领域值传递，不编码、不参与领域值的相等性。
/// `timestampNs` 只对产生它的同一个 `Diagnostics` 有意义，因此只能通过 `Diagnostics.elapsed(since:)` 读取。
public struct DiagnosticStamp: Sendable {
    let timestampNs: UInt64
    public let context: TraceContext?
}

/// 领域值与可选观测元数据的包装；端口用它传递诊断信息，领域类型保持纯净。
public struct Traced<Value: Sendable>: Sendable {
    public let value: Value
    public let stamp: DiagnosticStamp?

    public init(_ value: Value, stamp: DiagnosticStamp? = nil) {
        self.value = value
        self.stamp = stamp
    }
}

extension Diagnostics {
    /// 观测关闭时返回 nil，不读取时钟。
    public func stamp(context: TraceContext? = TraceContext.current) -> DiagnosticStamp? {
        guard isEnabled() else { return nil }
        return DiagnosticStamp(timestampNs: now(), context: context)
    }

    public func elapsed(since stamp: DiagnosticStamp) -> UInt64 {
        let now = now()
        return now >= stamp.timestampNs ? now - stamp.timestampNs : 0
    }
}
