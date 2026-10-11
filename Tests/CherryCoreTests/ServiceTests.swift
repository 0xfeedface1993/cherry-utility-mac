import Foundation
import Synchronization
import Testing
@testable import CherryCore

/// In-memory HID channel whose "device" is a closure turning each output report into zero or more replies.
final class SimulatedChannel: HIDReportChannel, Sendable {
    enum Reply: Sendable { case reports([[UInt8]]), disconnect }

    let outputReportLength: Int
    let inputReportIDs: Set<UInt8>
    private let respond: @Sendable ([UInt8]) -> Reply
    private let state = Mutex<(queue: [[UInt8]], disconnected: Bool, sent: Int, closed: Bool)>(([], false, 0, false))

    init(outputReportLength: Int = 64, inputReportIDs: Set<UInt8>, respond: @escaping @Sendable ([UInt8]) -> Reply) {
        self.outputReportLength = outputReportLength
        self.inputReportIDs = inputReportIDs
        self.respond = respond
    }

    var sentCount: Int { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func inject(_ report: [UInt8]) { state.withLock { $0.queue.append(report) } }

    func send(_ report: [UInt8]) async throws {
        #expect(report.count == outputReportLength)
        let reply = respond(report)
        try state.withLock { s in
            guard !s.disconnected else { throw CherryError.disconnected }
            s.sent += 1
            switch reply {
            case .reports(let r): s.queue += r
            case .disconnect: s.disconnected = true
            }
        }
    }

    func receive(timeout: Duration) async throws -> [UInt8]? {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            let next: [UInt8]?? = try state.withLock { s in
                if !s.queue.isEmpty { return .some(s.queue.removeFirst()) }
                if s.disconnected { throw CherryError.disconnected }
                return .none
            }
            if let next { return next }
            if ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func discardPending() async { state.withLock { $0.queue.removeAll() } }
    func close() async { state.withLock { $0.closed = true } }
}

/// Device side of the Telink USB OTA, reassembling the image like the keyboard bootloader would.
final class SimulatedOTADevice: Sendable {
    struct Memory {
        var image = [UInt8](repeating: 0xFF, count: 1 << 20)
        var highestIndex = -1
        var started = false
        var packetErrors = 0
    }

    let memory = Mutex(Memory())
    let currentCRC: UInt32
    let disconnectAfterEnd: Bool

    init(currentCRC: UInt32 = 0x1234_5678, disconnectAfterEnd: Bool = false) {
        self.currentCRC = currentCRC
        self.disconnectAfterEnd = disconnectAfterEnd
    }

    func respond(_ r: [UInt8]) -> SimulatedChannel.Reply {
        let rid = r[0]
        switch (r[1], r[4]) {
        case (1, _): // version query
            var reply = [UInt8](repeating: 0xFF, count: 64)
            reply.replaceSubrange(0..<4, with: [rid, 1, 8, 0])
            reply.replaceSubrange(4..<8, with: [0, 0, 0, 0])
            reply.replaceSubrange(8..<12, with: withUnsafeBytes(of: currentCRC.littleEndian, Array.init))
            return .reports([reply])
        case (2, 0x01) where r[2] == 2: // start
            memory.withLock { $0.started = true }
            return .reports([r])
        case (2, 0x02) where r[2] == 6 && r[5] == 0xFF: // end: payload 02 FF, last index, 0x10000 - last
            let last = Int(r[6]) | Int(r[7]) << 8
            let neg = Int(r[8]) | Int(r[9]) << 8
            let ok = memory.withLock { m -> Bool in
                guard m.started, m.packetErrors == 0, m.highestIndex == last, (last + neg) & 0xFFFF == 0 else { return false }
                let size = Int(m.image[0x18]) | Int(m.image[0x19]) << 8 | Int(m.image[0x1A]) << 16 | Int(m.image[0x1B]) << 24
                guard size > 4, size <= (last + 1) * 16 else { return false }
                let image = Array(m.image[0..<size])
                let trailer = UInt32(image[size - 4]) | UInt32(image[size - 3]) << 8 | UInt32(image[size - 2]) << 16 | UInt32(image[size - 1]) << 24
                return Checksums.telinkCRC32(image.dropLast(4)) == trailer
            }
            if disconnectAfterEnd && ok { return .disconnect }
            return .reports([[rid, 2, 3, 0, 6, 0xFF, ok ? 0 : 1] + [UInt8](repeating: 0xFF, count: 57)])
        default: // data
            let length = Int(r[2])
            memory.withLock { m in
                for p in stride(from: 0, to: length, by: 20) {
                    let pkt = Array(r[4 + p ..< 4 + p + 20])
                    let crc = Checksums.otaCRC16(pkt[0..<18])
                    guard pkt[18] == UInt8(crc & 0xFF), pkt[19] == UInt8(crc >> 8) else { m.packetErrors += 1; continue }
                    let index = Int(pkt[0]) | Int(pkt[1]) << 8
                    m.image.replaceSubrange(index * 16 ..< index * 16 + 16, with: pkt[2..<18])
                    m.highestIndex = max(m.highestIndex, index)
                }
            }
            return .reports([r])
        }
    }
}

final class ProgressLog: Sendable {
    private let events = Mutex<[FlashProgress]>([])
    func append(_ e: FlashProgress) { events.withLock { $0.append(e) } }
    var all: [FlashProgress] { events.withLock { $0 } }
}

@Suite("FirmwareFlasher against a simulated keyboard")
struct FirmwareFlasherTests {
    let fast = FirmwareFlasher.Timeouts(reply: .milliseconds(200), start: .milliseconds(200), ack: .milliseconds(200), result: .milliseconds(300))

    @Test(arguments: Observation.allCases)
    func flashesAndDeviceReassemblesIdenticalImage(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let image = try TestFirmware.updaterImage(size: 5000)
        let device = SimulatedOTADevice()
        let channel = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        let log = ProgressLog()

        let outcome = try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast, diagnostics: recorder.port).flash(image) { log.append($0) }

        #expect(outcome == .confirmed)
        let reassembled = device.memory.withLock { Array($0.image[0..<image.firmware.count]) }
        #expect(reassembled == image.firmware)
        let events = log.all
        #expect(events.first == .started(totalReports: channel.sentCount))
        #expect(events.last == .verifying)
        let percents = events.compactMap { if case .transferred(_, _, let p) = $0 { p } else { nil } }
        #expect(percents == percents.sorted() && percents.last == 100 && Set(percents).count == percents.count)
        recorder.expectClosedSpans()
        if observation == .recording {
            // 开始 ACK + 除结束命令外每个数据报文的 ACK + 结束结果，各占一个 span。
            #expect(recorder.finished(.otaACK).count == channel.sentCount)
            #expect(recorder.finished(.otaResult).map(\.outcome) == [.success])
        }
    }

    @Test func readsFirmwareStatus() async throws {
        let device = SimulatedOTADevice(currentCRC: 0xCFE1_A03E)
        let channel = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        let status = try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast).readFirmwareStatus()
        #expect(status.crc == 0xCFE1_A03E)
    }

    @Test func reportsDeviceSideFailure() async throws {
        let image = try TestFirmware.updaterImage(size: 640)
        // Corrupt every CRC-16 so the device rejects the image at the end.
        let device = SimulatedOTADevice()
        let channel = SimulatedChannel(inputReportIDs: [5]) { report in
            var r = report
            if r[1] == 2, r[2] == 60 || r[2] == 20 { r[22] ^= 0x01 } // first packet's CRC
            return device.respond(r)
        }
        await #expect(throws: CherryError.otaFailed(status: 1)) {
            try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast).flash(image) { _ in }
        }
    }

    @Test(arguments: Observation.allCases)
    func treatsDisconnectAfterTransferAsReboot(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let image = try TestFirmware.updaterImage(size: 640)
        let device = SimulatedOTADevice(disconnectAfterEnd: true)
        let channel = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        let outcome = try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast, diagnostics: recorder.port).flash(image) { _ in }
        #expect(outcome == .deviceRebooted)
        recorder.expectClosedSpans()
        if observation == .recording {
            #expect(recorder.finished(.otaTransfer).map(\.outcome) == [.deviceRebooted])
        }
    }

    @Test func timesOutWhenDeviceIgnoresStart() async throws {
        let image = try TestFirmware.updaterImage(size: 640)
        let channel = SimulatedChannel(inputReportIDs: [5]) { _ in .reports([]) }
        await #expect(throws: CherryError.self) {
            try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast).flash(image) { _ in }
        }
        #expect(channel.sentCount == 1)
    }

    @Test func ignoresReportsFromOtherCollections() async throws {
        let image = try TestFirmware.updaterImage(size: 640)
        let device = SimulatedOTADevice()
        let channel = SimulatedChannel(inputReportIDs: [5]) { report in
            // A stray keyboard report (ID 1) ahead of every ack must not be taken as the ack.
            guard case .reports(let replies) = device.respond(report) else { return .disconnect }
            return .reports([[1, 0, 0x04, 0, 0, 0, 0, 0]] + replies)
        }
        let outcome = try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast).flash(image) { _ in }
        #expect(outcome == .confirmed)
    }

    @Test(arguments: Observation.allCases)
    func cancellationStopsTheTransfer(_ observation: Observation) async throws {
        let recorder = DiagnosticRecorder(observation)
        let image = try TestFirmware.updaterImage(size: 50_000)
        let device = SimulatedOTADevice()
        let channel = SimulatedChannel(inputReportIDs: [5], respond: device.respond)
        let task = Task {
            try await FirmwareFlasher(channel: channel, reportID: 5, timeouts: fast, diagnostics: recorder.port).flash(image) { progress in
                if case .transferred(_, _, let p) = progress, p >= 10 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(channel.sentCount < 1000)
        recorder.expectClosedSpans()
        if observation == .recording {
            #expect(recorder.finished(.otaTransfer).map(\.outcome) == [.cancelled])
        }
    }
}

@Suite("VendorSession against a simulated keyboard")
struct VendorSessionTests {
    static func device(_ request: [UInt8]) -> SimulatedChannel.Reply {
        let length = Int(request[4])
        let offset = Int(request[5]) | Int(request[6]) << 8
        var space: [UInt8]
        switch request[3] {
        case 0x1A: space = [0x57, 0x01, 0, 0, 0, 0]
        case 0x1D: space = [0xAA, 0x55, 0, 0, 0x6A, 0x04, 0xE2, 0x01, 1, 0, 1, 0, 1, 0] + [UInt8](repeating: 0, count: 42)
        case 0x05:
            space = [UInt8](repeating: 0, count: 192)
            space[0] = 1
            space.replaceSubrange(64..<68, with: [0x01, 0x0A, 0x03, 0x02])
            space.replaceSubrange(64 + 0x22..<64 + 0x26, with: [0x2C, 0x01, 0x1E, 0x00])
            space[64 + 0x16] = 0b0000_0011
        default:
            return .reports([Array(request[0..<7]) + [0xFF] + [UInt8](repeating: 0, count: 56)])
        }
        let payload = Array(space[offset..<offset + length])
        return .reports([[1, 0, 0x04, 0, 0, 0, 0, 0], Array(request[0..<7]) + [0x00] + payload + [UInt8](repeating: 0, count: 56 - length)])
    }

    @Test func readsSnapshotAcrossChunksSkippingStrayReports() async throws {
        let channel = SimulatedChannel(inputReportIDs: [4], respond: Self.device)
        let snapshot = try await VendorSession(channel: channel, reportID: 4).snapshot()
        #expect(snapshot.battery.percent == 87)
        #expect(snapshot.status.mode == .wired)
        #expect(snapshot.profile.profile == 1)
        #expect(snapshot.profile.brightness == 3)
        #expect(snapshot.profile.speed == 2)
        #expect(snapshot.profile.sleepSeconds == 300)
        #expect(snapshot.profile.keyLocks == [.win, .altTab])
        // battery + status + profile number + 64-byte block in two chunks
        #expect(channel.sentCount == 5)
    }

    @Test func surfacesDeviceRejection() async throws {
        let channel = SimulatedChannel(inputReportIDs: [4], respond: Self.device)
        await #expect(throws: CherryError.deviceRejected(command: 0x07, status: 0xFF)) {
            try await VendorSession(channel: channel, reportID: 4).read(.readKeymap, length: 8)
        }
    }
}
