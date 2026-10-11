import CherryCore
import Foundation
import Synchronization
import Testing
@testable import CherryAdapters

/// The simulated keyboard must be protocol-faithful enough for the UI tests to exercise the real core services.
@Suite("Simulated keyboard")
struct SimulationTests {
    static func keyboard(_ hub: SimulatedKeyboardHub) async throws -> KeyboardSummary {
        try #require(await hub.keyboards().first)
    }

    @Test func resourcesWriterRoundTripsThroughTheUpdaterParser() throws {
        let data = SyntheticUpdater.updaterExe(for: .pixiu75, version: 0x0118)
        let image = try UpdaterImage(updaterExe: data)
        try image.validate()
        #expect(image.vendorID == 0x046A && image.productID == 0x01E2 && image.reportID == 5 && image.usagePage == 0xFFEF)
        #expect(image.firmware == SyntheticUpdater.firmware(version: 0x0118))
        let package = try FirmwareUpdateService.makePackage(data: data, source: .localFile(URL(fileURLWithPath: "/x.exe")), expectedMD5: SyntheticUpdater.md5(data))
        #expect(package.image.embeddedCRC == image.embeddedCRC)
    }

    @Test func configurationReadWriteThroughCoreServices() async throws {
        let hub = SimulatedKeyboardHub()
        let keyboard = try await Self.keyboard(hub)
        let configurator = KeyboardConfigurator(channels: ExclusiveChannelProvider(base: hub))

        let initial = try await configurator.configuration(of: keyboard)
        #expect(initial.activeProfile == 1 && initial.profiles.count == 3)
        #expect(initial.profile(0)?.lightingEffect == 18 && initial.profile(2)?.lightingEffect == 3)

        let switched = try await configurator.activateProfile(2, on: keyboard)
        #expect(switched.activeProfile == 2)

        var target = initial.active.settings
        target.brightness = 1
        target.color = LEDColor(r: 0x12, g: 0x34, b: 0x56)
        target.randomColor = false
        let updated = try await configurator.update(profile: 1, on: keyboard, patch: ProfilePatch(target, fields: [.brightness, .color, .randomColor]))
        #expect(updated.brightness == 1 && updated.color == target.color && !updated.randomColor)
        let space = hub.configurationSpace()
        #expect(space[0] == 2 && space[64 + 2] == 1 && Array(space[64 + 5...64 + 8]) == [0, 0x12, 0x34, 0x56])
        #expect(hub.writeCount == 2)
    }

    @Test func concurrentUsersShareTheInterfaceThroughTheGate() async throws {
        let hub = SimulatedKeyboardHub()
        let keyboard = try await Self.keyboard(hub)
        let channels = ExclusiveChannelProvider(base: hub)
        let inspector = KeyboardInspector(channels: channels)
        let configurator = KeyboardConfigurator(channels: channels)
        async let a = inspector.vendorSnapshot(of: keyboard)
        async let b = configurator.configuration(of: keyboard)
        async let c = inspector.firmwareStatus(of: keyboard)
        let (snapshot, configuration, firmware) = try await (a, b, c)
        #expect(snapshot.configuration == configuration)
        #expect(snapshot.battery.percent == 95 && snapshot.battery.charging == .charging && snapshot.status.mode == .wired)
        #expect(firmware.crc == SimulatedKeyboardHub.initialCRC && firmware.version == 0x0117)
    }

    @Test func firmwareUpdateRebootsIntoTheFlashedVersion() async throws {
        var scenario = SimulatedKeyboardHub.Scenario()
        scenario.rebootDelay = .milliseconds(200)
        let hub = SimulatedKeyboardHub(scenario: scenario)
        let keyboard = try await Self.keyboard(hub)
        let catalog = SimulatedFirmwareCatalog()
        let service = FirmwareUpdateService(catalog: catalog, downloader: catalog, channels: ExclusiveChannelProvider(base: hub), discovery: hub)

        let release = try #require(try await service.latestRelease(for: .pixiu75))
        #expect(release.version == FirmwareVersion(code: 0x0118))
        let package = try await service.download(release)
        #expect(try await service.deviceFirmware(keyboard: keyboard.id, package: package).crc == SimulatedKeyboardHub.initialCRC)

        let outcome = try await service.flash(keyboard: keyboard, package: package) { _ in }
        #expect(outcome == .confirmed)
        let after = try await service.verifyAfterFlash(keyboard: keyboard.id, package: package, timeout: .seconds(5), pollInterval: .milliseconds(100))
        #expect(after.crc == package.image.embeddedCRC && after.version == 0x0118)
        #expect(await hub.keyboards().first?.releaseNumber == 0x0118)
    }

    @Test func corruptedTransferIsRejectedByTheDevice() async throws {
        let hub = SimulatedKeyboardHub()
        let channel = try await hub.openChannel(keyboard: SimulatedKeyboardHub.keyboardID, usagePage: 0xFFEF, reportID: 5)
        let proto = try TelinkOTAProtocol(reportID: 5, reportLength: 64)
        var (reports, _) = proto.transferReports(firmware: SyntheticUpdater.firmware(version: 0x0118))
        reports[1][30] ^= 0xFF // breaks one packet's CRC-16
        try await channel.send(proto.startReport())
        _ = try await channel.receive(timeout: .seconds(1))
        for report in reports.dropLast() {
            try Task.checkCancellation()
            try await channel.send(report)
            _ = try await channel.receive(timeout: .seconds(1))
        }
        try await channel.send(reports.last!)
        let result = try #require(try await channel.receive(timeout: .seconds(1)))
        #expect(proto.parseResult(result) == 1)
        await channel.close()
    }

    @Test func hotPlugEndsChannelsAndEventStreamsAndNotifiesSubscribers() async throws {
        let hub = SimulatedKeyboardHub()
        var updates = hub.keyboardUpdates().makeAsyncIterator()
        #expect(await updates.next()?.count == 1)

        let channel = try await hub.openChannel(keyboard: SimulatedKeyboardHub.keyboardID, usagePage: 0xFF1C, reportID: 4)
        var events = hub.keyEvents(keyboard: SimulatedKeyboardHub.keyboardID).makeAsyncIterator()
        hub.inject(.keyboard(0x04), isDown: true, timestamp: 7)
        #expect(try await events.next() == KeyEvent(usage: .keyboard(0x04), isDown: true, timestamp: 7))

        hub.unplug()
        #expect(await updates.next() == [])
        await #expect(throws: CherryError.disconnected) { try await channel.receive(timeout: .seconds(1)) }
        await #expect(throws: CherryError.disconnected) { try await events.next() }
        await #expect(throws: CherryError.self) {
            try await hub.openChannel(keyboard: SimulatedKeyboardHub.keyboardID, usagePage: 0xFF1C, reportID: 4)
        }

        hub.plug()
        #expect(await updates.next()?.first?.id == SimulatedKeyboardHub.keyboardID)
    }

    @Test func scenariosShapeTheDevice() async throws {
        let denied = SimulatedKeyboardHub(scenario: .named("denied"))
        #expect(denied.status() == .denied)
        await #expect(throws: CherryError.accessDenied) {
            try await denied.openChannel(keyboard: SimulatedKeyboardHub.keyboardID, usagePage: 0xFF1C, reportID: 4)
        }

        let wireless = SimulatedKeyboardHub(scenario: .named("wireless"))
        let keyboard = try await Self.keyboard(wireless)
        #expect(!keyboard.hasInterface(usagePage: 0xFFEF))
        let snapshot = try await KeyboardInspector(channels: wireless).vendorSnapshot(of: keyboard)
        #expect(snapshot.status.mode == .wireless(2) && snapshot.battery.percent == 15)

        #expect(await SimulatedKeyboardHub(scenario: .named("empty")).keyboards().isEmpty)
        #expect(await SimulatedKeyboardHub(scenario: .named("unsupported")).keyboards().first?.model == nil)
    }

    @Test func rejectsBadChecksumsAndUnknownCommands() async throws {
        let hub = SimulatedKeyboardHub()
        let channel = try await hub.openChannel(keyboard: SimulatedKeyboardHub.keyboardID, usagePage: 0xFF1C, reportID: 4)
        var bad = VendorPacket.request(.readBattery, length: 6, offset: 0, reportID: 4)
        bad[1] ^= 0xFF
        try await channel.send(bad)
        #expect(try await channel.receive(timeout: .seconds(1))?[7] == 0xFE)
        try await channel.send(VendorPacket.request(.readKeymap, length: 8, offset: 0, reportID: 4))
        #expect(try await channel.receive(timeout: .seconds(1))?[7] == 0xFF)
        await channel.close()
    }
}
