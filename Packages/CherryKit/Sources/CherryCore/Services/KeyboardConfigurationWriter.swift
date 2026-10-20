import Foundation

/// App 生命周期内共享的写入协调器。每台设备一个执行批次和一个合并批次。
/// 已提交意图不随调用页面的取消而撤销；只有断连取消设备事务。
public actor KeyboardConfigurationWriter {
    public typealias Apply = @Sendable (ConfigurationIntent, KeyboardSummary) async throws -> KeyboardConfiguration
    private typealias Waiter = CheckedContinuation<KeyboardConfiguration, any Error>

    private struct Work {
        let token = UUID()
        var keyboard: KeyboardSummary
        var intent: ConfigurationIntent
        var waiters: [Waiter]
        let origin = DiagnosticOrigin.current
        let trace = TraceContext.current
    }
    private struct Lane {
        var active: Work?
        var pending: Work?
        var task: Task<Void, Never>?
    }

    private let operation: Apply
    private var connected: Set<KeyboardID>?
    private var interfaces: [KeyboardID: [UInt64]] = [:]
    private var lanes: [KeyboardID: Lane] = [:]

    public init(configurator: KeyboardConfigurator) {
        operation = { try await configurator.apply($0, on: $1) }
    }

    public init(apply: @escaping Apply) { operation = apply }

    /// 模块内测试用于等待真实入队，避免用睡眠猜测任务顺序。
    func pendingRequestCount(for id: KeyboardID) -> Int { lanes[id]?.pending?.waiters.count ?? 0 }

    /// 必须先处理发现事件，再将其交给 UI，断连后不能接受旧设备的新请求。
    public func keyboardsUpdated(_ keyboards: [KeyboardSummary]) {
        let available = Set(keyboards.filter(\.canConfigure).map(\.id))
        let currentInterfaces = Dictionary(uniqueKeysWithValues: keyboards.filter(\.canConfigure).map { ($0.id, $0.configurationInterfaceIDs) })
        let previousInterfaces = interfaces
        interfaces = currentInterfaces
        connected = available
        for id in Array(lanes.keys) where !available.contains(id) || (previousInterfaces[id] != nil && previousInterfaces[id] != currentInterfaces[id]) {
            guard var lane = lanes[id] else { continue }
            lane.task?.cancel()
            for waiter in (lane.active?.waiters ?? []) + (lane.pending?.waiters ?? []) {
                waiter.resume(throwing: CherryError.disconnected)
            }
            lane.active?.waiters = []
            lane.pending = nil
            // 保留旧 worker 的占位，等待关闭通道后才启动重新连接的请求。
            lanes[id] = lane
        }
    }

    public func apply(_ intent: ConfigurationIntent, on keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        try Task.checkCancellation()
        guard connected?.contains(keyboard.id) != false else { throw CherryError.disconnected }
        guard connected == nil || interfaces[keyboard.id] == keyboard.configurationInterfaceIDs else { throw CherryError.disconnected }
        return try await withCheckedThrowingContinuation { waiter in
            var lane = lanes[keyboard.id] ?? Lane()
            if var pending = lane.pending {
                pending.intent = pending.intent.merging(intent)
                pending.keyboard = keyboard
                pending.waiters.append(waiter)
                lane.pending = pending
            } else {
                lane.pending = Work(keyboard: keyboard, intent: intent, waiters: [waiter])
            }
            lanes[keyboard.id] = lane
            startNext(keyboard.id)
        }
    }

    private func startNext(_ id: KeyboardID) {
        guard var lane = lanes[id], lane.task == nil, let work = lane.pending else { return }
        lane.pending = nil
        lane.active = work
        let operation = operation
        lane.task = Task {
            let result: Result<KeyboardConfiguration, any Error>
            do {
                result = .success(try await DiagnosticOrigin.$current.withValue(work.origin) {
                    try await TraceContext.$current.withValue(work.trace) {
                        try await operation(work.intent, work.keyboard)
                    }
                })
            }
            catch { result = .failure(error) }
            finished(id, token: work.token, result: result)
        }
        lanes[id] = lane
    }

    private func finished(_ id: KeyboardID, token: UUID, result: Result<KeyboardConfiguration, any Error>) {
        guard var lane = lanes[id], lane.active?.token == token else { return }
        for waiter in lane.active?.waiters ?? [] { waiter.resume(with: result) }
        lane.active = nil
        lane.task = nil
        lanes[id] = lane.pending == nil ? nil : lane
        startNext(id)
    }
}
