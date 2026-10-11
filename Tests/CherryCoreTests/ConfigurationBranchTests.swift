import Foundation
import Synchronization
import Testing
@testable import CherryCore

final class ConfigurationDevice: Sendable {
    struct State {
        var bytes = [UInt8](repeating: 0, count: 256)
        var commands: [UInt8] = []
        var ignoreWrites = false
        var rejectWrites = false
    }
    let state = Mutex(State())
    init() {
        state.withLock {
            $0.bytes[0] = 1
            for profile in 0..<3 {
                $0.bytes[profile * 64 + 1] = 0x0A
                $0.bytes[profile * 64 + 2] = 2
                $0.bytes[profile * 64 + 3] = 2
                $0.bytes[profile * 64 + 5] = 0xFF
            }
        }
    }
    func respond(_ request: [UInt8]) -> SimulatedChannel.Reply {
        state.withLock { s in
            let command = request[3], count = Int(request[4]), offset = Int(request[5]) | Int(request[6]) << 8
            s.commands.append(command)
            var payload: [UInt8] = [], status: UInt8 = 0
            switch command {
            case VendorCommand.readConfig.rawValue:
                payload = Array(s.bytes[offset..<offset + count])
            case VendorCommand.writeConfig.rawValue:
                #expect(request[7] == 0x55)
                #expect(Checksums.vendorSum(request[3...]) == UInt16(request[1]) | UInt16(request[2]) << 8)
                if s.rejectWrites { status = 0xFF }
                else if !s.ignoreWrites { s.bytes.replaceSubrange(offset..<offset + count, with: request[8..<8 + count]) }
            default: break
            }
            return .reports([Array(request.prefix(7)) + [status] + payload + [UInt8](repeating: 0, count: 56 - payload.count)])
        }
    }
}

@Suite("配置档写入与独占通道")
struct ConfigurationBranchTests {
    static var settings: ProfileSettings {
        ProfileSettings(effect: 0x0A, brightness: 2, speed: 3, randomColor: true, color: .white, sleepSeconds: 300, deepSleepMinutes: 30)
    }

    @Test func partialPatchPreservesUneditedBytesAndNormalizesFields() throws {
        var raw = [UInt8](repeating: 0x33, count: 64)
        raw[5] = 0xFF
        let config = try ProfileConfig(profile: 1, raw: raw)
        var values = Self.settings
        values.brightness = 99; values.speed = -1
        values.sleepSeconds = 1; values.deepSleepMinutes = 999
        let patch = ProfilePatch(values, fields: [.brightness, .speed, .randomColor, .sleepSeconds, .deepSleepMinutes])
        let updated = config.applying(patch)
        #expect(updated[2] == 4 && updated[3] == 4 && updated[5] == 0xFF)
        #expect(updated[0x22] == 30 && updated[0x24] == 0x2C && updated[0x25] == 1)
        let edited: Set<Int> = [2, 3, 5, 0x22, 0x23, 0x24, 0x25]
        #expect((0..<64).filter { !edited.contains($0) }.allSatisfy { updated[$0] == raw[$0] })
        #expect(config.changedRange(to: raw) == nil)
        #expect(config.changedRange(to: updated) == 2..<0x26)
        #expect(config.applying(ProfilePatch(values, fields: [])) == raw)
        values.sleepSeconds = 0; values.deepSleepMinutes = 0
        #expect(values.normalized.sleepSeconds == 0 && values.normalized.deepSleepMinutes == 0)
    }

    @Test func fieldsAndColorsRoundTrip() {
        #expect(LEDColor(hex: "#11aAff") == LEDColor(r: 0x11, g: 0xAA, b: 0xFF))
        #expect(LEDColor(hex: "xyzxyz") == nil)
        #expect(LEDColor(hex: "123") == nil)
        var updated = Self.settings
        updated.effect = 2; updated.brightness = 4; updated.speed = 1
        updated.randomColor = false; updated.color = LEDColor(r: 1, g: 2, b: 3)
        updated.sleepSeconds = 90; updated.deepSleepMinutes = 40
        #expect(ProfileField.differences(between: Self.settings, and: updated) == Set(ProfileField.allCases))
        #expect(ProfilePatch.all(updated).applied(to: Self.settings) == updated)
    }

    @Test func configurationRequiresActiveBlockAndReplacementKeepsOtherProfiles() throws {
        let zero = try ProfileConfig(profile: 0, raw: [UInt8](repeating: 0, count: 64))
        let one = try ProfileConfig(profile: 1, raw: [UInt8](repeating: 1, count: 64))
        #expect(throws: CherryError.self) { try KeyboardConfiguration(activeProfile: 2, profiles: [zero, one]) }
        let config = try KeyboardConfiguration(activeProfile: 1, profiles: [one, zero])
        #expect(config.profiles.map(\.profile) == [0, 1] && config.active == one)
        #expect(config.profile(2) == nil)
        #expect(config.replacing(zero).profile(1) == one)
    }

    @Test func configuratorWritesOnlyRequestedSettingsAndReadsBack() async throws {
        let device = ConfigurationDevice()
        let channel = SimulatedChannel(inputReportIDs: [4], respond: device.respond)
        let configurator = KeyboardConfigurator(channels: ServicePorts(channels: [channel]))
        let initial = try await configurator.configuration(of: ServiceBranchTests.keyboard)
        #expect(initial.activeProfile == 1 && initial.profiles.count == 3)
        let active = try await configurator.activateProfile(2, on: ServiceBranchTests.keyboard)
        #expect(active.activeProfile == 2)
        let patch = ProfilePatch.set(\.brightness, 4, field: .brightness, on: initial.active.settings)
        let updated = try await configurator.update(profile: 1, on: ServiceBranchTests.keyboard, patch: patch)
        #expect(updated.brightness == 4 && updated.speed == initial.active.speed)
        let commands = device.state.withLock { $0.commands }
        #expect(commands.filter { $0 == 1 }.count == 2 && commands.filter { $0 == 2 }.count == 2)
        #expect(channel.isClosed)
    }

    @Test func writeRejectionStillEndsTransactionAndClosesChannel() async throws {
        let device = ConfigurationDevice()
        device.state.withLock { $0.rejectWrites = true }
        let channel = SimulatedChannel(inputReportIDs: [4], respond: device.respond)
        await #expect(throws: CherryError.deviceRejected(command: 6, status: 0xFF)) {
            try await KeyboardConfigurator(channels: ServicePorts(channels: [channel])).activateProfile(2, on: ServiceBranchTests.keyboard)
        }
        #expect(device.state.withLock { $0.commands } == [1, 6, 2])
        #expect(channel.isClosed)
    }

    @Test func unchangedPatchSendsNoWriteAndUnsupportedValuesDoNotOpenChannel() async throws {
        let device = ConfigurationDevice()
        let channel = SimulatedChannel(inputReportIDs: [4], respond: device.respond)
        let ports = ServicePorts(channels: [channel])
        let configurator = KeyboardConfigurator(channels: ports)
        _ = try await configurator.update(profile: 1, on: ServiceBranchTests.keyboard, patch: ProfilePatch(Self.settings, fields: []))
        #expect(!device.state.withLock { $0.commands }.contains(6))
        await #expect(throws: CherryError.self) { try await configurator.activateProfile(-1, on: ServiceBranchTests.keyboard) }
        var bad = Self.settings; bad.effect = 0xFF
        await #expect(throws: CherryError.self) { try await configurator.update(profile: 1, on: ServiceBranchTests.keyboard, patch: ProfilePatch(bad, fields: [.effect])) }
        #expect(ports.opens == 1)
    }

    @Test func readBackMismatchIsRejected() async throws {
        let device = ConfigurationDevice()
        device.state.withLock { $0.ignoreWrites = true }
        let channel = SimulatedChannel(inputReportIDs: [4], respond: device.respond)
        let configurator = KeyboardConfigurator(channels: ServicePorts(channels: [channel]))
        await #expect(throws: CherryError.self) { try await configurator.activateProfile(2, on: ServiceBranchTests.keyboard) }
        let patch = ProfilePatch.set(\.brightness, 4, field: .brightness, on: Self.settings)
        await #expect(throws: CherryError.self) { try await configurator.update(profile: 1, on: ServiceBranchTests.keyboard, patch: patch) }
    }

    @Test func gateCancellationDoesNotStealOrLeakOwnership() async throws {
        let gate = ChannelGate<Int>()
        try await gate.acquire(1)
        try await gate.acquire(2)
        let waiter = Task { try await gate.acquire(1) }
        await Task.yield(); waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(gate.isHeld(1) && gate.isHeld(2))
        gate.release(1); gate.release(2)
        #expect(!gate.isHeld(1) && !gate.isHeld(2))
        try await gate.acquire(1)
        gate.release(1)
    }

    @Test func gateHandsOwnershipToWaitingConsumer() async throws {
        let gate = ChannelGate<Int>()
        try await gate.acquire(1)
        let task = Task { try await gate.acquire(1) }
        await Task.yield()
        gate.release(1)
        try await task.value
        #expect(gate.isHeld(1))
        gate.release(1)
        #expect(!gate.isHeld(1))
    }

    @Test func exclusiveProviderReleasesFailedOpenAndDoubleClose() async throws {
        let gate = ChannelGate<ExclusiveChannelProvider.Key>()
        let key = ExclusiveChannelProvider.Key(keyboard: ServiceBranchTests.keyboard.id, usagePage: 0xFFEF)
        let failed = ExclusiveChannelProvider(base: ServicePorts(channels: []), gate: gate)
        await #expect(throws: CherryError.self) { try await failed.openChannel(keyboard: key.keyboard, usagePage: key.usagePage, reportID: 5) }
        #expect(!gate.isHeld(key))
        let raw = SimulatedChannel(inputReportIDs: [5]) { .reports([$0]) }
        let provider = ExclusiveChannelProvider(base: ServicePorts(channels: [raw]), gate: gate)
        let channel = try await provider.openChannel(keyboard: key.keyboard, usagePage: key.usagePage, reportID: 5)
        #expect(gate.isHeld(key) && channel.outputReportLength == 64 && channel.inputReportIDs == [5])
        await channel.discardPending()
        let report = try TelinkOTAProtocol(reportID: 5, reportLength: 64).startReport()
        try await channel.send(report)
        #expect(try await channel.receive(timeout: .seconds(1)) == report)
        await channel.close(); await channel.close()
        #expect(!gate.isHeld(key) && raw.isClosed)
    }
}
