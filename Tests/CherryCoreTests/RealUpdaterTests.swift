import CryptoKit
import Foundation
import Testing
@testable import CherryCore

/// Golden test against the official PIXIU 75 updater, when it has been extracted next to the project
/// (`CHEERY-Utilty/extracted/pixiu75/`). The reference hash comes from a line-by-line Python port of the
/// updater's C# `ota_write`, which was also confirmed on hardware (3461 reports, OTA Success).
@Suite("Official PIXIU 75 updater")
struct RealUpdaterTests {
    static let updater = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../../extracted/pixiu75/MX_PIXIU75_WIRELESS_0117.exe")
        .standardizedFileURL

    static var available: Bool { FileManager.default.fileExists(atPath: updater.path) }

    @Test(.enabled(if: available))
    func extractsAndFramesExactlyLikeTheWindowsUpdater() throws {
        let package = try FirmwareUpdateService.makePackage(
            data: try Data(contentsOf: Self.updater),
            source: .localFile(Self.updater),
            expectedMD5: "08A5108DF49B0F49D4E23130A9F035D6"
        )
        let image = package.image
        #expect(image.vendorID == 0x046A && image.productID == 0x01E2)
        #expect(image.reportID == 5 && image.usagePage == 0xFFEF)
        #expect(image.firmware.count == 165_972)
        #expect(image.embeddedCRC == 0xCFE1_A03E)

        let proto = try TelinkOTAProtocol(reportID: image.reportID, reportLength: 64)
        let (reports, _) = proto.transferReports(firmware: image.firmware)
        var hasher = SHA256()
        for report in [proto.startReport()] + reports { hasher.update(data: Data(report)) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(reports.count + 1 == 3460)
        #expect(digest == "3712b52f4cddd81d5b0f4bc90376962ae19f1854916b55e2a2d81817647f8274")
    }
}
