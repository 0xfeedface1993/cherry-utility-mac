import Foundation

public struct TraceContext: Codable, Equatable, Sendable {
    @TaskLocal public static var current: TraceContext?

    public let traceID: UUID
    public let spanID: UUID
    public let parentSpanID: UUID?
    public let deviceSessionID: UUID?
    public let origin: DiagnosticOrigin

    enum CodingKeys: String, CodingKey { case traceID = "traceId", spanID = "spanId", parentSpanID = "parentSpanId", deviceSessionID = "deviceSessionId", origin }

    public init(parent: TraceContext? = nil, origin: DiagnosticOrigin = DiagnosticOrigin.current ?? .background, deviceSessionID: UUID? = nil) {
        traceID = parent?.traceID ?? UUID()
        spanID = UUID()
        parentSpanID = parent?.spanID
        self.deviceSessionID = deviceSessionID ?? parent?.deviceSessionID
        self.origin = parent?.origin ?? origin
    }
}

extension DiagnosticOrigin {
    /// 由驱动侧（Feature effect、组合根、Profile 工具）声明的调用来源。
    /// Core 服务和被驱动适配器不指定 origin：有父 trace 时继承父 trace，否则读取这里，再否则为 `.background`。
    @TaskLocal public static var current: DiagnosticOrigin?
}

public struct DiagnosticClock: Sendable {
    public let now: @Sendable () -> UInt64

    public init(now: @escaping @Sendable () -> UInt64) { self.now = now }

    public static func continuous() -> Self {
        let start = ContinuousClock.now
        return Self { nanoseconds(start.duration(to: .now)) }
    }

    public static func nanoseconds(_ duration: Duration) -> UInt64 {
        let c = duration.components
        guard c.seconds >= 0 else { return 0 }
        let (seconds, overflow) = UInt64(c.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return .max }
        let fractional = c.attoseconds >= 0 ? UInt64(c.attoseconds / 1_000_000_000) : 0
        let (value, additionOverflow) = seconds.addingReportingOverflow(fractional)
        return additionOverflow ? .max : value
    }
}
