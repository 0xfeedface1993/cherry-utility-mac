import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import CherryCore

final class ServicePorts: ReportChannelProvider, KeyboardDiscoveryPort, FirmwareCatalogPort, FirmwareDownloadPort {
    let channels: [SimulatedChannel]
    let lists: [[KeyboardSummary]]
    let entries: [FirmwareRelease]
    let data: Data
    private let counts = Mutex((opens: 0, polls: 0))

    init(channels: [SimulatedChannel], lists: [[KeyboardSummary]] = [], entries: [FirmwareRelease] = [], data: Data = Data()) {
        self.channels = channels; self.lists = lists; self.entries = entries; self.data = data
    }
    var opens: Int { counts.withLock { $0.opens } }
    func openChannel(keyboard: KeyboardID, usagePage: UInt16, reportID: UInt8) async throws -> any HIDReportChannel {
        let index = counts.withLock { c in defer { c.opens += 1 }; return c.opens }
        guard !channels.isEmpty else { throw CherryError.deviceNotFound(keyboard) }
        let channel = channels[min(index, channels.count - 1)]
        #expect(channel.inputReportIDs.contains(reportID))
        return channel
    }
    func keyboards() async -> [KeyboardSummary] {
        let index = counts.withLock { c in defer { c.polls += 1 }; return c.polls }
        return lists.isEmpty ? [] : lists[min(index, lists.count - 1)]
    }
    func keyboardUpdates() -> AsyncStream<[KeyboardSummary]> { AsyncStream { $0.finish() } }
    func releases() async throws -> [FirmwareRelease] { entries }
    func download(_ release: FirmwareRelease) async throws -> Data { data }
}

@Suite("应用服务业务分支")
struct ServiceBranchTests {
    static let keyboard = KeyboardSummary(
        id: KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 1), product: "PIXIU 75", manufacturer: "CHERRY",
        serialNumber: nil, transport: "USB", releaseNumber: 0x0117,
        interfaces: [HIDInterfaceSummary(id: 1, usages: [HIDUsage(page: 0xFFEF, usage: 0)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])]
    )
    static let fast = FirmwareFlasher.Timeouts(reply: .milliseconds(10), start: .milliseconds(10), ack: .milliseconds(10), result: .milliseconds(10))

    static func package() throws -> FirmwarePackage {
        FirmwarePackage(source: .localFile(URL(fileURLWithPath: "/tmp/test.exe")), fileMD5: "AA", image: try TestFirmware.updaterImage(size: 320))
    }
    static func service(_ ports: ServicePorts) -> FirmwareUpdateService {
        FirmwareUpdateService(catalog: ports, downloader: ports, channels: ports, discovery: ports, timeouts: fast)
    }

    @Test func inspectorReadsAndClosesEveryChannel() async throws {
        let vendor = SimulatedChannel(inputReportIDs: [4], respond: VendorSessionTests.device)
        let ports = ServicePorts(channels: [vendor])
        let inspector = KeyboardInspector(channels: ports)
        #expect(try await inspector.battery(of: Self.keyboard).percent == 87)
        let snapshot = try await inspector.vendorSnapshot(of: Self.keyboard)
        #expect(snapshot.profile.profile == 1)
        #expect(vendor.isClosed && ports.opens == 2)
        let device = SimulatedOTADevice(currentCRC: 0xAABB_CCDD)
        let ota = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        #expect(try await KeyboardInspector(channels: ServicePorts(channels: [ota])).firmwareStatus(of: Self.keyboard).crc == 0xAABB_CCDD)
        #expect(ota.isClosed)
    }

    @Test func channelClosesAfterReadFailureAndUnsupportedModelDoesNotOpen() async throws {
        let channel = SimulatedChannel(inputReportIDs: [4]) { _ in .disconnect }
        let ports = ServicePorts(channels: [channel])
        await #expect(throws: CherryError.disconnected) { try await KeyboardInspector(channels: ports).battery(of: Self.keyboard) }
        #expect(channel.isClosed)
        let unknown = KeyboardSummary(id: KeyboardID(vendorID: 1, productID: 1, locationID: 1), product: "Unknown", manufacturer: "", serialNumber: nil, transport: "USB", releaseNumber: 0, interfaces: [])
        await #expect(throws: CherryError.unsupportedModel) { try await KeyboardInspector(channels: ports).battery(of: unknown) }
        #expect(ports.opens == 1)
    }

    @Test func missingOTAInterfacePreventsOpeningOrFlashing() async throws {
        let keyboard = KeyboardSummary(id: Self.keyboard.id, product: "PIXIU 75", manufacturer: "CHERRY", serialNumber: nil, transport: "USB", releaseNumber: 0x0117, interfaces: [])
        let ports = ServicePorts(channels: [])
        let package = try Self.package()
        #expect(FirmwareUpdateService.incompatibilities(of: package, with: keyboard).count == 1)
        await #expect(throws: CherryError.self) { try await Self.service(ports).flash(keyboard: keyboard, package: package) { _ in } }
        #expect(ports.opens == 0)
    }

    @Test func compatibleFlashClosesChannelAndVerifiesAfterReconnectRetry() async throws {
        let device = SimulatedOTADevice(currentCRC: 0xAABB_CCDD)
        let flash = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        let ports = ServicePorts(channels: [flash])
        #expect(try await Self.service(ports).flash(keyboard: Self.keyboard, package: Self.package()) { _ in } == .confirmed)
        #expect(flash.isClosed)
        let failure = SimulatedChannel(inputReportIDs: [5]) { _ in .disconnect }
        let success = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        let retry = ServicePorts(channels: [failure, success], lists: [[], [Self.keyboard]])
        let status = try await Self.service(retry).verifyAfterFlash(keyboard: Self.keyboard.id, package: Self.package(), timeout: .seconds(1), pollInterval: .milliseconds(1))
        #expect(status.crc == 0xAABB_CCDD)
        #expect(retry.opens == 2 && failure.isClosed && success.isClosed)
    }

    @Test func reconnectTimeoutAndCancellationEndVerification() async throws {
        let ports = ServicePorts(channels: [])
        let package = try Self.package()
        await #expect(throws: CherryError.self) {
            try await Self.service(ports).verifyAfterFlash(keyboard: Self.keyboard.id, package: package, timeout: .zero)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.service(ports).verifyAfterFlash(keyboard: Self.keyboard.id, package: package)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ports.opens == 0)
    }

    @Test func downloadValidatesHashAndExtractsSyntheticUpdater() async throws {
        let data = Data(ResourceFixture.stream(name: "param_128K", value: TestFirmware.param()) + ResourceFixture.stream(name: "code_2M", value: TestFirmware.code(firmware: TestFirmware.make(size: 320))))
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let release = FirmwareRelease(name: "MX_PIXIU75_WIRELESS_0120", deviceIndex: 60, versionCode: "0120", versionName: "0.1.2.0", downloadURL: URL(string: "https://example.invalid/test.exe")!, md5: md5, isForced: false)
        let ports = ServicePorts(channels: [], entries: [release], data: data)
        #expect(try await Self.service(ports).latestRelease(for: .pixiu75) == release)
        let package = try await Self.service(ports).download(release)
        #expect(package.source == .catalog(release))
        #expect(package.fileMD5 == md5.uppercased())
        try package.image.validate()
        await #expect(throws: CherryError.self) { try await Self.service(ServicePorts(channels: [])).download(release) }
        #expect(FirmwareUpdateService.latestRelease(for: .pixiu75, in: []) == nil)
    }

    @Test func dataAckTimeoutAndMissingFinalResultHaveDifferentOutcomes() async throws {
        let package = try Self.package()
        let noDataAck = SimulatedChannel(inputReportIDs: [5]) { r in .reports(r[2] == 2 ? [r] : []) }
        await #expect(throws: CherryError.self) { try await FirmwareFlasher(channel: noDataAck, reportID: 5, timeouts: Self.fast).flash(package.image) { _ in } }
        #expect(noDataAck.sentCount == 2)
        let noResult = SimulatedChannel(inputReportIDs: [5]) { r in .reports(r[2] == 6 ? [] : [r]) }
        #expect(try await FirmwareFlasher(channel: noResult, reportID: 5, timeouts: Self.fast).flash(package.image) { _ in } == .unconfirmed)
    }

    @Test func versionQuerySkipsNoiseAndTimesOutWithoutValidVersion() async throws {
        let channel = SimulatedChannel(inputReportIDs: [5]) { _ in .reports([[1], [5, 2, 0, 0]]) }
        await #expect(throws: CherryError.self) { try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: Self.fast).readFirmwareStatus() }
        let device = SimulatedOTADevice()
        let good = SimulatedChannel(inputReportIDs: [5]) { r in
            guard case .reports(let replies) = device.respond(r) else { return .disconnect }
            return .reports([[5, 2, 0, 0]] + replies)
        }
        #expect(try await FirmwareFlasher(channel: good, reportID: 5).readFirmwareStatus().crc == 0x1234_5678)
    }
}
