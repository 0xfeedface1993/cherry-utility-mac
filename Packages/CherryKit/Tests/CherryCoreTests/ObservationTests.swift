import Synchronization
import Testing
@testable import CherryCore

/// 生产默认开启观测；业务用例在关闭和记录两种配置下都必须得到相同结果。
enum Observation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case off, recording
    var testDescription: String { rawValue }
}

final class DiagnosticRecorder: Sendable {
    let observation: Observation
    private let events = Mutex<[DiagnosticEvent]>([])

    init(_ observation: Observation) { self.observation = observation }

    var port: Diagnostics {
        switch observation {
        case .off: .noop
        case .recording: .recording { [self] event in events.withLock { $0.append(event) } }
        }
    }

    var all: [DiagnosticEvent] { events.withLock { $0 } }

    func finished(_ operation: DiagnosticOperation) -> [DiagnosticEvent] {
        all.filter { $0.operation == operation && $0.phase == .finished }
    }

    func summaries(_ operation: DiagnosticOperation) -> [DiagnosticEvent] {
        all.filter { $0.operation == operation && $0.phase == .summary }
    }

    /// 关闭时不产生事件；记录时每个 began 恰好对应一个显式 finished（deinit 兜底的 abandoned 视为泄漏）。
    func expectClosedSpans(sourceLocation: SourceLocation = #_sourceLocation) {
        let events = all
        guard observation == .recording else {
            #expect(events.isEmpty, sourceLocation: sourceLocation)
            return
        }
        let began = events.filter { $0.phase == .began }.map(\.context.spanID)
        let finished = events.filter { $0.phase == .finished }
        #expect(Set(began).count == began.count, sourceLocation: sourceLocation)
        #expect(Set(finished.map(\.context.spanID)).count == finished.count, sourceLocation: sourceLocation)
        #expect(Set(began) == Set(finished.map(\.context.spanID)), sourceLocation: sourceLocation)
        #expect(!finished.contains { $0.outcome == .abandoned }, sourceLocation: sourceLocation)
    }
}

@Suite("独占通道：关闭与开启观测")
struct ExclusiveChannelObservationTests {
    static let key = ExclusiveChannelProvider.Key(keyboard: ServiceBranchTests.keyboard.id, usagePage: 0xFFEF)

    static func channel() -> SimulatedChannel { SimulatedChannel(inputReportIDs: [5]) { .reports([$0]) } }

    @Test(arguments: Observation.allCases)
    func failedOpenAndDoubleCloseReleaseTheGate(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let gate = ChannelGate<ExclusiveChannelProvider.Key>()
        let failed = ExclusiveChannelProvider(base: ServicePorts(channels: []), gate: gate, diagnostics: recorder.port)
        await #expect(throws: CherryError.deviceNotFound(Self.key.keyboard)) {
            try await failed.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5)
        }
        #expect(!gate.isHeld(Self.key))

        let raw = Self.channel()
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [raw]), gate: gate, diagnostics: recorder.port)
        let channel = try await provider.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5)
        #expect(gate.isHeld(Self.key))
        await channel.close(); await channel.close()
        #expect(!gate.isHeld(Self.key) && raw.isClosed)

        recorder.expectClosedSpans()
        if observation == .recording {
            #expect(recorder.finished(.channelQueue).map(\.outcome) == [.success, .success])
            #expect(recorder.finished(.channelOpen).map(\.outcome) == [.disconnected, .success])
            #expect(recorder.finished(.channelHeld).map(\.outcome) == [.disconnected, .success])
            #expect(recorder.summaries(.channelResume).count == 2)
        }
    }

    @Test(arguments: Observation.allCases)
    func waitingCallerGetsTheChannelAfterClose(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let gate = ChannelGate<ExclusiveChannelProvider.Key>()
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [Self.channel()]), gate: gate, diagnostics: recorder.port)
        let first = try await provider.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5)
        let second = Task { try await provider.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.isHeld(Self.key))
        await first.close()
        let channel = try await second.value
        #expect(gate.isHeld(Self.key))
        await channel.close()
        #expect(!gate.isHeld(Self.key))

        recorder.expectClosedSpans()
        if observation == .recording {
            let queued = recorder.finished(.channelQueue)
            #expect(queued.count == 2 && queued.allSatisfy { $0.outcome == .success })
            #expect(recorder.finished(.channelHeld).count == 2)
            // 第二个调用方的 held span 挂在它自己的 queue span 下，不会混进第一个 trace。
            let held = recorder.finished(.channelHeld)
            #expect(Set(held.map(\.context.traceID)) == Set(queued.map(\.context.traceID)))
        }
    }

    @Test(arguments: Observation.allCases)
    func cancelledWaiterDoesNotStealOwnership(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let gate = ChannelGate<ExclusiveChannelProvider.Key>()
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [Self.channel()]), gate: gate, diagnostics: recorder.port)
        let first = try await provider.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5)
        let waiter = Task { try await provider.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5) }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(gate.isHeld(Self.key))
        await first.close()
        #expect(!gate.isHeld(Self.key))

        recorder.expectClosedSpans()
        if observation == .recording {
            #expect(recorder.finished(.channelQueue).compactMap(\.outcome).sorted { $0.rawValue < $1.rawValue } == [.cancelled, .success])
            #expect(recorder.finished(.channelHeld).count == 1)
            #expect(recorder.finished(.channelOpen).count == 1)
        }
    }

    @Test(arguments: Observation.allCases)
    func droppedChannelReleasesOwnershipOnce(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let gate = ChannelGate<ExclusiveChannelProvider.Key>()
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [Self.channel()]), gate: gate, diagnostics: recorder.port)
        do {
            let channel = try await provider.openChannel(keyboard: Self.key.keyboard, usagePage: Self.key.usagePage, reportID: 5)
            #expect(channel.outputReportLength == 64 && gate.isHeld(Self.key))
        }
        #expect(!gate.isHeld(Self.key))
        recorder.expectClosedSpans()
        if observation == .recording {
            #expect(recorder.finished(.channelHeld).map(\.outcome) == [.success])
        }
    }
}

@Suite("观测元数据与领域值分离")
struct DiagnosticStampTests {
    @Test func stampTravelsBesideTheEventAndUsesTheSameClock() throws {
        let clock = Mutex<UInt64>(100)
        let port = Diagnostics.recording(clock: .init(now: { clock.withLock { $0 } })) { _ in }
        #expect(Diagnostics.noop.stamp() == nil)
        let session = TraceContext(origin: .keytest)
        let stamp = try #require(port.stamp(context: session))
        clock.withLock { $0 = 130 }
        #expect(port.elapsed(since: stamp) == 30)
        let traced = Traced(KeyEvent(usage: .keyboard(4), isDown: true, timestamp: 1), stamp: stamp)
        // 领域值的相等性与是否开启观测无关。
        #expect(traced.value == KeyEvent(usage: .keyboard(4), isDown: true, timestamp: 1))
        #expect(traced.stamp?.context == session)
    }
}

@Suite("调用来源由驱动侧声明")
struct DiagnosticOriginTests {
    @Test func withoutADriverTheOriginIsBackgroundAndParentsWin() {
        #expect(TraceContext().origin == .background)
        let parent = TraceContext(origin: .firmware)
        DiagnosticOrigin.$current.withValue(.menuBar) {
            #expect(TraceContext().origin == .menuBar)
            #expect(TraceContext(parent: parent).origin == .firmware)
        }
    }

    @Test func servicesInheritTheDriverOrigin() async throws {
        let recorder = DiagnosticRecorder(.recording)
        let device = ConfigurationDevice()
        let channel = SimulatedChannel(inputReportIDs: [4], respond: device.respond)
        let configurator = ConfigurationBranchTests.configurator(ServicePorts(channels: [channel]), recorder)
        let patch = ProfilePatch.set(\.brightness, 4, field: .brightness, on: ConfigurationBranchTests.settings)
        _ = try await DiagnosticOrigin.$current.withValue(.menuBar) {
            try await configurator.update(profile: 1, on: ServiceBranchTests.keyboard, patch: patch)
        }
        #expect(recorder.finished(.configurationWrite).map(\.outcome) == [.success])
        #expect(recorder.all.allSatisfy { $0.context.origin == .menuBar })
        recorder.expectClosedSpans()
    }

    /// 交接回调运行在释放方的任务上；等待方的 held/resume 仍归属等待方自己的来源。
    @Test func handOffKeepsTheWaitersOrigin() async throws {
        let recorder = DiagnosticRecorder(.recording)
        let key = ExclusiveChannelObservationTests.key
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [ExclusiveChannelObservationTests.channel()]), diagnostics: recorder.port)
        let first = try await DiagnosticOrigin.$current.withValue(.deviceInfo) {
            try await provider.openChannel(keyboard: key.keyboard, usagePage: key.usagePage, reportID: 5)
        }
        let second = Task {
            try await DiagnosticOrigin.$current.withValue(.menuBar) {
                try await provider.openChannel(keyboard: key.keyboard, usagePage: key.usagePage, reportID: 5)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        await DiagnosticOrigin.$current.withValue(.deviceInfo) { await first.close() }
        try await second.value.close()
        recorder.expectClosedSpans()
        for operation in [DiagnosticOperation.channelHeld, .channelOpen] {
            #expect(recorder.finished(operation).map(\.context.origin).sorted { $0.rawValue < $1.rawValue } == [.deviceInfo, .menuBar])
        }
        let byTrace = Dictionary(grouping: recorder.all, by: \.context.traceID)
        #expect(byTrace.count == 2 && byTrace.values.allSatisfy { Set($0.map(\.context.origin)).count == 1 })
    }
}
