import Foundation
import Testing
@testable import CherryCore

/// 由测试逐步发布设备列表的发现端口。
final class SteppedDiscovery: KeyboardDiscoveryPort {
    let (stream, continuation) = AsyncStream.makeStream(of: [KeyboardSummary].self)
    func keyboards() async -> [KeyboardSummary] { [] }
    func keyboardUpdates() -> AsyncStream<[KeyboardSummary]> { stream }
}

@Suite("Core 服务装配")
struct CoreServicesTests {
    /// 带配置接口的 PIXIU 75，写入队列只接受这类设备。
    static let configurable = KeyboardSummary(
        id: ServiceBranchTests.keyboard.id, product: "PIXIU 75", manufacturer: "CHERRY", serialNumber: nil, transport: "USB",
        releaseNumber: 0x0117,
        interfaces: [HIDInterfaceSummary(id: 2, usages: [HIDUsage(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64,
                                         maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])]
    )

    static func services(_ ports: ServicePorts, discovery: any KeyboardDiscoveryPort, _ recorder: DiagnosticRecorder) -> CoreServices {
        CoreServices(discovery: discovery, channels: ports, catalog: ports, downloader: ports, diagnostics: recorder.port)
    }

    /// 订阅方收到新列表时，写入队列已经按它更新：断连的设备不再接受请求。
    @Test(arguments: Observation.allCases)
    func discoveryReachesTheWriterBeforeSubscribers(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let device = ConfigurationDevice()
        let discovery = SteppedDiscovery()
        let services = Self.services(ServicePorts(channels: [SimulatedChannel(inputReportIDs: [4], respond: device.respond)]), discovery: discovery, recorder)
        var updates = services.keyboardUpdates().makeAsyncIterator()

        discovery.continuation.yield([Self.configurable])
        #expect(await updates.next() == [Self.configurable])
        let patch = ProfilePatch.set(\.brightness, 4, field: .brightness, on: ConfigurationBranchTests.settings)
        #expect(try await services.writer.update(profile: 1, patch: patch, on: Self.configurable).brightness == 4)

        discovery.continuation.yield([])
        #expect(await updates.next() == [])
        await #expect(throws: CherryError.disconnected) { try await services.writer.apply(.activate(0), on: Self.configurable) }
        discovery.continuation.finish()
        #expect(await updates.next() == nil)
        recorder.expectClosedSpans()
    }

    @Test(arguments: Observation.allCases)
    func localUpdaterIsParsedAndMeasuredByTheService(_ observation: Observation) throws {
        let recorder = DiagnosticRecorder(observation)
        let ports = ServicePorts(channels: [])
        let firmware = Self.services(ports, discovery: ports, recorder).firmware
        let data = Data(ResourceFixture.stream(name: "param_128K", value: TestFirmware.param())
            + ResourceFixture.stream(name: "code_2M", value: TestFirmware.code(firmware: TestFirmware.make(size: 320))))
        let url = URL(fileURLWithPath: "/tmp/local.exe")
        let package = try firmware.loadLocal(data, from: url)
        #expect(package.source == .localFile(url))
        try package.image.validate()
        #expect(throws: CherryError.self) { try firmware.loadLocal(Data([1, 2, 3]), from: url) }
        recorder.expectClosedSpans()
        if observation == .recording {
            #expect(recorder.finished(.firmwareParse).map(\.outcome) == [.success, .failed])
        }
    }
}
