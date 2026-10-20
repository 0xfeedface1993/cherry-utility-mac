import Foundation
import Testing
@testable import CherryCore

/// Requests and replies below were captured from a real PIXIU 75 (firmware 0117) over USB.
@Suite("Vendor protocol (0xFF1C)")
struct VendorProtocolTests {
    @Test func requestMatchesCapturedBytes() {
        let battery = VendorPacket.request(.readBattery, length: 6, offset: 0, reportID: 4)
        #expect(Array(battery.prefix(8)) == [0x04, 0x20, 0x00, 0x1A, 0x06, 0x00, 0x00, 0x00])
        let status = VendorPacket.request(.readDeviceStatus, length: 56, offset: 0, reportID: 4)
        #expect(Array(status.prefix(5)) == [0x04, 0x55, 0x00, 0x1D, 0x38])
        let config = VendorPacket.request(.readConfig, length: 56, offset: 64, reportID: 4)
        #expect(config[5] == 64 && config[6] == 0)
        #expect(Checksums.vendorSum(config[3...]) == UInt16(config[1]) | UInt16(config[2]) << 8)
        #expect(battery.count == 64)
    }

    @Test func parsesCapturedBatteryReply() throws {
        let request = VendorPacket.request(.readBattery, length: 6, offset: 0, reportID: 4)
        var reply = [UInt8](repeating: 0, count: 64)
        reply.replaceSubrange(0..<10, with: [0x04, 0x20, 0x00, 0x1A, 0x06, 0x00, 0x00, 0x00, 0x57, 0x01])
        let battery = try BatteryStatus(raw: VendorPacket.payload(of: reply, for: request))
        #expect(battery.percent == 87)
        #expect(battery.charging == .charging)
    }

    @Test func rejectsErrorStatusAndMismatchedEcho() {
        let request = VendorPacket.request(.readConfig, length: 4, offset: 0, reportID: 4)
        var reply = [UInt8](repeating: 0, count: 64)
        reply.replaceSubrange(0..<8, with: [0x04, 0x3B, 0x00, 0x05, 0x04, 0x00, 0x00, 0xFF])
        #expect(throws: CherryError.deviceRejected(command: 0x05, status: 0xFF)) {
            try VendorPacket.payload(of: reply, for: request)
        }
        reply[3] = 0x07
        #expect(!VendorPacket.matches(reply, request: request))
    }

    @Test func parsesCapturedStatusAndProfile() throws {
        var status = [UInt8](repeating: 0, count: 56)
        status.replaceSubrange(0..<14, with: [0xAA, 0x55, 0, 0, 0x6A, 0x04, 0xE2, 0x01, 1, 0, 1, 0, 1, 0])
        let block = try DeviceStatusBlock(raw: status)
        #expect(block.vendorID == 0x046A && block.productID == 0x01E2 && block.mode == .wired)

        var profile = [UInt8](repeating: 0, count: 64)
        profile.replaceSubrange(0..<9, with: [0x01, 0x0A, 0x02, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        profile[0x19] = 0xFF
        profile.replaceSubrange(0x22..<0x26, with: [0x2C, 0x01, 0x1E, 0x00])
        let config = try ProfileConfig(profile: 1, raw: profile)
        #expect(config.lightingEffect == 0x0A)
        #expect(config.brightness == 2)
        #expect(config.speed == 0)
        #expect(config.colors[0] == .init(r: 0xFF, g: 0, b: 0))
        #expect(config.sleepSeconds == 300)
        #expect(config.deepSleepMinutes == 30)
        #expect(config.keyLocks.isEmpty)
    }
}

@Suite("Domain")
struct DomainTests {
    @Test func firmwareVersionMatchesCatalogEncoding() {
        #expect(FirmwareVersion(code: 0x0117).description == "0.1.1.7")
        #expect(FirmwareVersion(versionCode: "0117") == FirmwareVersion(code: 0x0117))
        #expect(FirmwareVersion(versionCode: "0120")! > FirmwareVersion(code: 0x0117))
    }

    @Test func pixiuLayoutCoversEveryKeyOnce() {
        let layout = KeyboardLayout.pixiu75
        #expect(layout.keys.count == 84)
        #expect(layout.testableKeys.count == 83) // all but Fn
        let usages = layout.testableKeys.compactMap(\.usage)
        #expect(Set(usages).count == usages.count)
        #expect(layout.key(for: .keyboard(0x29))?.label == "Esc")
    }

    @Test func latestReleasePicksKeyboardEntriesOnly() {
        func release(_ name: String, _ code: String) -> FirmwareRelease {
            FirmwareRelease(name: name, deviceIndex: 60, versionCode: code, versionName: code,
                            downloadURL: URL(string: "https://example.invalid/\(name).exe")!, md5: "00", isForced: false)
        }
        let releases = [
            release("MX_PIXIU75_WIRELESS_0117", "0117"),
            release("MX_PIXIU75_WIRELESS_0110", "0110"),
            release("MX_PIXIU75_POKEMON_WIRELESS_0102", "102"),
            release("MX_PIXIU75_WIRELESS_DONGLE_0200", "0200"),
        ]
        #expect(FirmwareUpdateService.latestRelease(for: .pixiu75, in: releases)?.name == "MX_PIXIU75_WIRELESS_0117")
    }

    @Test func reportLayoutParsesVendorCollection() {
        // UsagePage 0xFFEF, Usage 0, Collection, ReportID 5, 63 × 8-bit input + output, End Collection.
        let descriptor: [UInt8] = [
            0x06, 0xEF, 0xFF, 0x09, 0x00, 0xA1, 0x01, 0x85, 0x05,
            0x75, 0x08, 0x95, 0x3F, 0x09, 0x01, 0x81, 0x02, 0x09, 0x01, 0x91, 0x02, 0xC0,
        ]
        let summary = HIDReportLayout(descriptor: descriptor).collections.map(\.summary)
        #expect(summary.count == 1)
        #expect(summary[0].usage == HIDUsage(page: 0xFFEF, usage: 0))
        #expect(summary[0].inputReports == [5: 64])
        #expect(summary[0].outputReports == [5: 64])
    }
}

@Suite("Telink OTA framing")
struct TelinkOTATests {
    @Test func framesMatchTheWindowsUpdater() throws {
        let proto = try TelinkOTAProtocol(reportID: 5, reportLength: 64)
        #expect(Array(proto.versionQueryReport().prefix(5)) == [0x05, 0x01, 0x00, 0x00, 0xFF])
        #expect(Array(proto.startReport().prefix(6)) == [0x05, 0x02, 0x02, 0x00, 0x01, 0xFF])

        let firmware = TestFirmware.make(size: 100)
        let (reports, progress) = proto.transferReports(firmware: firmware)
        // 100 bytes → 7 packets of 16 bytes → 3 data reports (3+3+1) + end.
        #expect(reports.count == 4)
        #expect(progress.last == 100)
        #expect(reports[0][2] == 60 && reports[2][2] == 20)
        let end = reports[3]
        #expect(Array(end.prefix(10)) == [0x05, 0x02, 0x06, 0x00, 0x02, 0xFF, 0x06, 0x00, 0xFA, 0xFF])
        // First packet: index 0, 16 bytes, CRC-16 over index+data.
        let packet = Array(reports[0][4..<24])
        #expect(Array(packet[2..<18]) == Array(firmware[0..<16]))
        let crc = Checksums.otaCRC16(packet[0..<18])
        #expect(packet[18] == UInt8(crc & 0xFF) && packet[19] == UInt8(crc >> 8))
    }

    @Test func reportIDSevenSendsOnePacketPerReport() throws {
        let proto = try TelinkOTAProtocol(reportID: 7, reportLength: 64)
        let (reports, _) = proto.transferReports(firmware: TestFirmware.make(size: 64))
        #expect(reports.count == 5) // 4 packets + end
    }

    @Test func rejectsShortReports() {
        #expect(throws: CherryError.self) { try TelinkOTAProtocol(reportID: 5, reportLength: 33) }
    }

    @Test func updaterImageValidation() throws {
        let image = try TestFirmware.updaterImage(size: 1000)
        try image.validate()
        #expect(image.vendorID == 0x046A && image.productID == 0x01E2 && image.reportID == 5 && image.usagePage == 0xFFEF)

        var corrupted = TestFirmware.make(size: 1000)
        corrupted[100] ^= 0xFF
        let bad = try UpdaterImage(param: TestFirmware.param(), code: TestFirmware.code(firmware: corrupted))
        #expect(throws: CherryError.self) { try bad.validate() }
    }
}

enum TestFirmware {
    /// A synthetic Telink image: header size at 0x18, "KNLT" at 0x20, CRC32 trailer.
    static func make(size: Int) -> [UInt8] {
        var fw = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        fw.replaceSubrange(0x18..<0x1C, with: withUnsafeBytes(of: UInt32(size).littleEndian, Array.init))
        fw.replaceSubrange(0x20..<0x24, with: Array("KNLT".utf8))
        let crc = Checksums.telinkCRC32(fw.dropLast(4))
        fw.replaceSubrange(size - 4..<size, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        return fw
    }

    static func param() -> [UInt8] {
        var p = [UInt8](repeating: 0xFF, count: 256)
        p.replaceSubrange(64..<74, with: Array("046A01E205".utf8))
        p.replaceSubrange(80..<84, with: Array("FFEF".utf8))
        return p
    }

    static func code(firmware: [UInt8]) -> [UInt8] {
        var c = [UInt8](repeating: 0x56, count: 256)
        let n = UInt32(firmware.count)
        c.replaceSubrange(48..<52, with: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        return c + firmware + [UInt8](repeating: 0xFF, count: 16)
    }

    static func updaterImage(size: Int) throws -> UpdaterImage {
        try UpdaterImage(param: param(), code: code(firmware: make(size: size)))
    }
}
