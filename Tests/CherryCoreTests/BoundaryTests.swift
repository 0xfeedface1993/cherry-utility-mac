import Foundation
import Testing
@testable import CherryCore

@Suite("协议与升级边界")
struct BoundaryTests {
    @Test func cancellationBeforeStartSendsNothing() async throws {
        let image = try TestFirmware.updaterImage(size: 320)
        let channel = SimulatedChannel(inputReportIDs: [5]) { .reports([$0]) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FirmwareFlasher(channel: channel, reportID: 5).flash(image) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(channel.sentCount == 0)
    }

    @Test func truncatedKeyReportsDoNotReleaseHeldKeys() {
        let decoder = HIDInputDecoder(descriptor: HIDInputDecoderTests.bootKeyboard)
        #expect(decoder.pressedUsages(in: []) == nil)
        #expect(decoder.pressedUsages(in: [2, 0, 4]) == nil)
        #expect(decoder.pressedUsages(in: [2, 0, 4, 0, 0, 0, 0, 0])?.usages == [.keyboard(0xE1), .keyboard(4)])
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func corruptedResourceOffsetsAreRejected(_ index: Int) {
        var bytes = ResourceFixture.stream(name: "payload", value: [1, 2, 3])
        let positions = [8, 16, 28, 32, 51, 56]
        bytes.replaceSubrange(positions[index]..<positions[index] + 4, with: [0xEC, 0xFF, 0xFF, 0xFF])
        #expect(DotNetResources.byteArrays(in: Data(bytes)).isEmpty)
    }

    @Test func resourcesSkipMalformedStreamsAndKeepValidEntries() {
        let malformed: [UInt8] = [0xCE, 0xCA, 0xEF, 0xBE, 1, 0, 0, 0, 0xEC, 0xFF, 0xFF, 0xFF]
        let good = ResourceFixture.stream(name: "payload", value: [1, 2, 3])
        #expect(DotNetResources.byteArrays(in: Data(malformed + good)) == ["payload": Data([1, 2, 3])])
        #expect(DotNetResources.byteArrays(in: Data([0xCE, 0xCA, 0xEF, 0xBE])).isEmpty)
    }

    @Test(arguments: [0, 1, 2, 7])
    func batteryChargingBranches(_ code: UInt8) throws {
        let battery = try BatteryStatus(raw: [255, code])
        #expect(battery.percent == 100)
        #expect(battery.charging == (code == 0 ? .notCharging : code <= 2 ? .charging : .other(code)))
    }

    @Test(arguments: [1, 2, 7, 9])
    func deviceConnectionModeBranches(_ mode: UInt8) throws {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes.replaceSubrange(0..<2, with: [0xAA, 0x55])
        bytes[10] = mode
        let status = try DeviceStatusBlock(raw: bytes)
        #expect(status.mode == (mode == 1 ? .wired : [2, 7].contains(mode) ? .wireless(UInt16(mode)) : .unknown(UInt16(mode))))
    }

    @Test func malformedDomainAndVendorRepliesAreRejected() throws {
        #expect(throws: CherryError.self) { try BatteryStatus(raw: [1]) }
        #expect(throws: CherryError.self) { try DeviceStatusBlock(raw: []) }
        #expect(throws: CherryError.self) { try DeviceStatusBlock(raw: [UInt8](repeating: 0, count: 12)) }
        #expect(throws: CherryError.self) { try ProfileConfig(profile: 1, raw: []) }
        #expect(ProfileConfig.pollingRate(index: -1) == nil)
        #expect(ProfileConfig.pollingRate(index: 7) == nil)
        #expect(ProfileConfig.pollingRate(index: 6) == 8000)
        let request = VendorPacket.request(.readBattery, length: 6, offset: 0, reportID: 4)
        #expect(throws: CherryError.self) { try VendorPacket.payload(of: [], for: request) }
        #expect(throws: CherryError.self) { try VendorPacket.payload(of: Array(request.prefix(8)), for: request) }
        var reply = request
        reply[7] = 0xFE
        #expect(throws: CherryError.deviceRejected(command: 0x1A, status: 0xFE)) { try VendorPacket.payload(of: reply, for: request) }
    }

    @Test func firmwareFormatAndHashChecksRejectBadInputs() throws {
        #expect(throws: CherryError.self) { try UpdaterImage(updaterExe: Data()) }
        #expect(throws: CherryError.self) { try UpdaterImage(param: [], code: []) }
        var param = TestFirmware.param()
        param[64] = 0x5A
        #expect(throws: CherryError.self) { try UpdaterImage(param: param, code: TestFirmware.code(firmware: TestFirmware.make(size: 320))) }
        #expect(throws: CherryError.self) {
            try FirmwareUpdateService.makePackage(data: Data(), source: .localFile(URL(fileURLWithPath: "/tmp/bad.exe")), expectedMD5: "00")
        }
        var firmware = TestFirmware.make(size: 320)
        firmware[0x18] = 0
        let crc = Checksums.telinkCRC32(firmware.dropLast(4))
        firmware.replaceSubrange(316..<320, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        let badHeader = try UpdaterImage(param: TestFirmware.param(), code: TestFirmware.code(firmware: firmware))
        #expect(throws: CherryError.self) { try badHeader.validate() }
        firmware.replaceSubrange(316..<320, with: [0, 0, 0, 0])
        let badCRC = try UpdaterImage(param: TestFirmware.param(), code: TestFirmware.code(firmware: firmware))
        #expect(throws: CherryError.self) { try badCRC.validate() }
    }

    @Test func resultAndVersionParsersRejectWrongHeaders() throws {
        let proto = try TelinkOTAProtocol(reportID: 5, reportLength: 64)
        let version: [UInt8] = [5, 1, 8, 0, 0x78, 0x56, 0x34, 0x12, 4, 3, 2, 1]
        #expect(proto.parseVersion(version) == DeviceFirmwareStatus(version: 0x1234_5678, crc: 0x0102_0304))
        let result: [UInt8] = [5, 2, 3, 0, 6, 0xFF, 9]
        #expect(proto.parseResult(result) == 9)
        for i in 0..<4 {
            var wrong = version; wrong[i] ^= 0x10
            #expect(proto.parseVersion(wrong) == nil)
        }
        for i in 0..<6 {
            var wrong = result; wrong[i] ^= 0x10
            #expect(proto.parseResult(wrong) == nil)
        }
        #expect(proto.parseVersion(Array(version.prefix(11))) == nil)
        #expect(proto.parseResult(Array(result.prefix(6))) == nil)
    }
}

enum ResourceFixture {
    static func stream(name: String, value: [UInt8]) -> [UInt8] {
        func i32(_ n: Int) -> [UInt8] { withUnsafeBytes(of: Int32(n).littleEndian, Array.init) }
        let nameBytes = Array(name.utf16).flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }
        precondition(nameBytes.count < 128)
        let names = [UInt8(nameBytes.count)] + nameBytes + i32(0)
        return [0xCE, 0xCA, 0xEF, 0xBE] + i32(1) + i32(0) + i32(2) + i32(1) + i32(0)
            + i32(0) + i32(0) + i32(36 + names.count) + names + [0x20] + i32(value.count) + value
    }
}
