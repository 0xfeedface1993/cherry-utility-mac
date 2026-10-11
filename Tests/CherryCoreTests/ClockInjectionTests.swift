import Foundation
import Synchronization
import Testing
@testable import CherryCore

/// `sleep` 立即把时间推进到截止点的时钟：轮询逻辑按注入的时间运行，不需要真实等待。
final class ImmediateClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let current = Mutex(Instant(offset: .zero))
    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        current.withLock { $0 = max($0, deadline) }
    }
}

@Suite("注入的时间来源")
struct ClockInjectionTests {
    static func service(_ ports: ServicePorts, clock: ImmediateClock) -> FirmwareUpdateService {
        FirmwareUpdateService(catalog: ports, downloader: ports, channels: ports, discovery: ports,
                              timeouts: ServiceBranchTests.fast, clock: clock)
    }

    /// 60 秒超时、每秒轮询一次：恰好轮询 60 次后放弃，且不真实等待。
    @Test func reconnectionGivesUpAfterTheTimeoutOnTheInjectedClock() async throws {
        let clock = ImmediateClock(), ports = ServicePorts(channels: [])
        let started = ContinuousClock.now
        await #expect(throws: CherryError.timeout("设备未重新连接")) {
            try await Self.service(ports, clock: clock).verifyAfterFlash(
                keyboard: ServiceBranchTests.keyboard.id, package: ServiceBranchTests.package(), timeout: .seconds(60), pollInterval: .seconds(1))
        }
        #expect(ports.polls == 60)
        #expect(clock.now.offset == .seconds(60))
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func reconnectionReadsTheFirmwareOnceTheKeyboardReturns() async throws {
        let clock = ImmediateClock()
        let device = SimulatedOTADevice(currentCRC: 0xAABB_CCDD)
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [5], respond: device.respond)],
                                 lists: [[], [], [ServiceBranchTests.keyboard]])
        let status = try await Self.service(ports, clock: clock).verifyAfterFlash(
            keyboard: ServiceBranchTests.keyboard.id, package: ServiceBranchTests.package(), timeout: .seconds(60), pollInterval: .seconds(1))
        #expect(status.crc == 0xAABB_CCDD)
        #expect(ports.polls == 3 && clock.now.offset == .seconds(3))
    }
}
