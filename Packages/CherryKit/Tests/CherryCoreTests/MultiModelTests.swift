import Foundation
import Synchronization
import Testing
@testable import CherryCore

/// Configuration-space device that records every command and every write (offset + bytes).
/// Battery (0x1A) and status (0x1D) are answered so tests can assert they were never asked for.
final class RecordingConfigurationDevice: Sendable {
    struct State {
        var bytes = [UInt8](repeating: 0, count: 256)
        var commands: [UInt8] = []
        var writes: [(offset: Int, bytes: [UInt8])] = []
    }

    let state = Mutex(State())

    init(configure: (inout [UInt8]) -> Void = { _ in }) {
        state.withLock { s in
            s.bytes[0] = 0
            for profile in 0..<3 {
                s.bytes[profile * 64 + 1] = 0
                s.bytes[profile * 64 + 2] = 2
                s.bytes[profile * 64 + 3] = 2
            }
            configure(&s.bytes)
        }
    }

    var commands: [UInt8] { state.withLock { $0.commands } }
    var writes: [(offset: Int, bytes: [UInt8])] { state.withLock { $0.writes } }
    func byte(_ offset: Int) -> UInt8 { state.withLock { $0.bytes[offset] } }

    func respond(_ request: [UInt8]) -> SimulatedChannel.Reply {
        state.withLock { s in
            let command = request[3], count = Int(request[4]), offset = Int(request[5]) | Int(request[6]) << 8
            s.commands.append(command)
            var payload: [UInt8] = []
            switch command {
            case VendorCommand.readConfig.rawValue:
                payload = Array(s.bytes[offset..<offset + count])
            case VendorCommand.writeConfig.rawValue:
                let bytes = Array(request[8..<8 + count])
                s.writes.append((offset, bytes))
                s.bytes.replaceSubrange(offset..<offset + count, with: bytes)
            case VendorCommand.readBattery.rawValue:
                payload = Array([0x50, 0x00, 0, 0, 0, 0].prefix(count))
            case VendorCommand.readDeviceStatus.rawValue:
                payload = Array(([0xAA, 0x55, 0, 0, 0x6A, 0x04, 0, 0, 1, 0, 2, 0] + [UInt8](repeating: 0, count: 44)).prefix(count))
            default: break
            }
            return .reports([Array(request.prefix(7)) + [0] + payload + [UInt8](repeating: 0, count: 56 - payload.count)])
        }
    }
}

enum MultiModelFixtures {
    static func keyboard(_ productID: UInt16, product: String = "Keyboard") -> KeyboardSummary {
        KeyboardSummary(
            id: KeyboardID(vendorID: 0x046A, productID: productID, locationID: 0x0100_0000 | UInt32(productID)),
            product: product, manufacturer: "CHERRY", serialNumber: nil, transport: "USB", releaseNumber: 0x0100,
            interfaces: [HIDInterfaceSummary(
                id: 1, usages: [HIDUsage(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64, maxOutputReportSize: 64,
                maxFeatureReportSize: 0, collections: []
            )]
        )
    }

    static func model(_ productID: UInt16) throws -> KeyboardModel {
        try #require(KeyboardModel.matching(vendorID: 0x046A, productID: productID))
    }

    static func configurator(_ ports: ServicePorts) -> KeyboardConfigurator {
        KeyboardConfigurator(channels: ExclusiveChannelProvider(base: ports))
    }

    static func inspector(_ ports: ServicePorts) -> KeyboardInspector {
        KeyboardInspector(channels: ExclusiveChannelProvider(base: ports))
    }
}

@Suite("多型号：型号目录")
struct KeyboardCatalogTests {
    /// Type 1 / 8 product IDs of CHERRY Utility 2.3.28.7's device table, plus the MX 10.1 receiver (0x01F1), which the
    /// device table lists under the keyboard's ID but the interface table and the write lists use.
    static let driverProductIDs: Set<UInt16> = [
        0x0077, 0x0079, 0x0083, 0x00AB, 0x00AC, 0x00B4, 0x00B7, 0x00BB, 0x00C3, 0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00CA,
        0x00CB, 0x00CD, 0x00CE, 0x00D2, 0x00D3, 0x00E3, 0x00E5, 0x00E9, 0x00EA, 0x00EC, 0x0142, 0x0144, 0x014C, 0x014E,
        0x01AB, 0x01AC, 0x01AF, 0x01B0, 0x01B1, 0x01B2, 0x01B4, 0x01B7, 0x01BA, 0x01BB, 0x01BC, 0x01C2, 0x01C3, 0x01CE,
        0x01CF, 0x01D7, 0x01DA, 0x01DB, 0x01DE, 0x01E0, 0x01E2, 0x01E4, 0x01E6, 0x01E8, 0x01EF, 0x01F1, 0x01F3, 0x01F5,
        0x01F7, 0x01F9, 0x01FB, 0x01FD, 0xC0CE,
    ]

    /// Keyboard entries of `goods_drive/getDriveList` on 2026-10-14.
    static let catalogNames = [
        "CCF_MX_1.0_TKL_BL_0105", "CCF_MX_8.0_TKL_BL_0105", "G80_3000N_FL_RGB_0103", "G80_3000S_TKL_NBL_KR_0102",
        "G80_3000_TKL_NBL_0103", "G80_3000_TKL_RGB_0106", "MV_3.0_FL_RGB_0105", "MX_1.0_FL_RGB_0105", "MX_BOARD_1.0_TKL_RGB_0108",
        "MX_BOARD_10.0_FL_RGB_0108", "MX_BOARD_10.0_FL_RGB_DE_0102", "MX_BOARD_10.1_FL_RGB_Wireless_0120",
        "MX_BOARD_10.1_FL_RGB_Wireless_DONGLE_0103", "MX_BOARD_2.0S_FL_NBL_0104", "MX_BOARD_2.0S_FL_RGB2_0103",
        "MX_BOARD_2.0S_FL_RGB_0104", "MX_BOARD_2.0S_FL_RGB_KR_0101", "MX_BOARD_2.0_FL_NBL_WIRELESS_0110",
        "MX_BOARD_2.0_FL_NBL_WIRELESS_DONGLE_0103", "MX_BOARD_2.0_FL_NBL_WIRELESS_TLK_0117", "MX_BOARD_3.0S_FL_NBL_0120",
        "MX_BOARD_3.0S_FL_RGB_0136", "MX_BOARD_3.0S_FL_RGB_WIRELESS_0140", "MX_BOARD_3.0S_FL_RGB_WIRELESS_DONGLE_0124",
        "MX_BOARD_3.0S_FL_RGB_WIRELESS_POKEMON_0104", "MX_BOARD_3.0S_TKL_NBL_0103", "MX_BOARD_3.0S_TKL_RGB_0102",
        "MX_BOARD_3.1_FL_RGB_0107", "MX_BOARD_8.0_TKL_RGB_0120", "MX_BOARD_8.2_TKL_RGB_WIRELESS_0112",
        "MX_BOARD_8.2_TKL_RGB_WIRELESS_DONGLE_0108", "MX_BOARD_8.2_Xaga_TKL_RGB_WIRELESS_0105",
        "MX_BOARD_8.2_Xaga_TKL_RGB_WIRELESS_DONGLE_0102", "MX_BOARD_8.3_Dongle_Wireless_RGB_0108",
        "MX_BOARD_8.3_TKL_RGB_Wireless_0125", "MX_K6_WIRELESS_0182", "MX_K6_WIRELESS_DONGLE_0172", "MX_LP_2.1_COMPACT_WIRELESS_0103",
        "MX_LP_2.1_COMPACT_WIRELESS_DONGLE_0100", "MX_LP_6.1_COMPACT_WIRELESS_0103", "MX_PIXIU75_POKEMON_WIRELESS_0102",
        "MX_PIXIU75_WIRELESS_0117", "MX_PIXIU98_WIRELESS_0113", "MX_PIXIU99_WIRELESS_0157", "MX_PIXIU99_WIRELESS_DONGLE_0126",
    ]

    static var catalog: [FirmwareRelease] {
        catalogNames.map { name in
            FirmwareRelease(
                name: name, deviceIndex: 0, versionCode: String(name.suffix(4)), versionName: "", downloadURL: URL(string: "https://example.invalid/\(name).exe")!,
                md5: "00", isForced: false
            )
        }
    }

    @Test func coversEveryKeyboardProductIDOfTheDriverExactlyOnce() {
        let ids = KeyboardModel.all.map(\.productID)
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids) == Self.driverProductIDs)
        #expect(KeyboardModel.all.allSatisfy { $0.vendorID == 0x046A && $0.vendorUsagePage == 0xFF1C && $0.vendorReportID == 4 })
        #expect(KeyboardModel.matching(vendorID: 0x046A, productID: 0x01E2) == .pixiu75)
        #expect(KeyboardModel.matching(vendorID: 0x046A, productID: 0x0999) == nil)
    }

    @Test func onlyPIXIU75IsVerifiedAndOnlyTelinkModelsCanBeFlashed() {
        #expect(KeyboardModel.all.filter { $0.verification == .hardware } == [.pixiu75])
        #expect(Set(KeyboardModel.all.filter(\.canFlashFirmware).map(\.productID)) == [0x01E2, 0x01F7])
        #expect(KeyboardModel.pixiu75Pokemon.ota == .telink)
    }

    @Test func editableFieldsFollowTheDriverWriteRanges() throws {
        let lighting: Set<ProfileField> = [.effect, .brightness, .speed, .randomColor, .color]
        let sleep: Set<ProfileField> = [.sleepSeconds, .deepSleepMinutes]
        // No-backlight boards: the driver returns before writing anything.
        for id: UInt16 in [0x0077, 0x00C3, 0x00CD, 0x00CB, 0x00D2, 0x00CE, 0x01AB, 0x01AF, 0x01BB, 0xC0CE] {
            let model = try MultiModelFixtures.model(id)
            #expect(model.editableFields.isEmpty && model.lightingEffects.isEmpty, "\(model.name)")
        }
        #expect(try MultiModelFixtures.model(0x00B4).editableFields == [.effect, .brightness, .speed])
        // Wired RGB (default branch): lighting only, and no battery.
        let wired = try MultiModelFixtures.model(0x0079)
        #expect(wired.editableFields == lighting && !wired.hasBattery && !wired.isWireless)
        // Wireless, default branch: no sleep timers.
        #expect(try MultiModelFixtures.model(0x01CE).editableFields == lighting)
        // No backlight but in the 0x38-byte block list: sleep only.
        #expect(try MultiModelFixtures.model(0x01DE).editableFields == sleep)
        #expect(KeyboardModel.pixiu75.editableFields == lighting.union(sleep))
        #expect(try MultiModelFixtures.model(0x01FB).editableFields == lighting.union(sleep))
        #expect(KeyboardModel.all.filter { !$0.isWireless }.allSatisfy { !$0.hasSleepSettings })
    }

    @Test func effectTablesMatchTheDriver() throws {
        #expect(KeyboardModel.pixiu75.lightingEffects.map(\.rawValue) == [0, 1, 2, 10, 12, 15, 18, 19, 21, 3, 8])
        let pixiu98 = try MultiModelFixtures.model(0x01E6)
        #expect(pixiu98.lightingEffects.map(\.rawValue) == [6, 7, 8, 9, 5, 10, 11, 0, 1, 2, 3, 4])
        #expect(pixiu98.effect(8)?.englishName == "Breathing" && pixiu98.effect(4)?.isCustom == true)
        #expect(try MultiModelFixtures.model(0x01EF).effect(5) == nil)
        #expect(try MultiModelFixtures.model(0x01C2).effect(22)?.englishName == "RGB Static")
        #expect(try MultiModelFixtures.model(0x01F3).effect(24)?.englishName == "Flame")
        #expect(KeyboardModel.pixiu75Pokemon.effect(23)?.englishName == "Battle")
        // Every effect value fits the low 6 bits the app reads and writes.
        #expect(KeyboardModel.all.flatMap(\.lightingEffects).allSatisfy { $0.rawValue <= ProfileConfig.effectMask })
    }

    @Test func receiversShareTheirKeyboardsCapabilitiesAndLayout() throws {
        let receivers = KeyboardModel.all.filter { $0.kind == .receiver }
        #expect(receivers.count == 17)
        for receiver in receivers {
            let keyboard = try #require(KeyboardModel.all.first { $0.kind == .keyboard && $0.deviceIndex == receiver.deviceIndex })
            #expect(receiver.name == keyboard.name + " Receiver")
            #expect(receiver.layout == keyboard.layout && receiver.lightingEffects == keyboard.lightingEffects)
            #expect(receiver.isWireless && receiver.ota == nil)
        }
    }

    @Test func everyLayoutIsDrawableAndTestable() {
        for model in KeyboardModel.all {
            let keys = model.layout.keys
            #expect(keys.count >= 60, "\(model.name)")
            #expect(Set(keys.map(\.id)).count == keys.count, "\(model.name)")
            #expect(keys.allSatisfy { $0.width > 1 && $0.height > 1 && $0.x >= 0 && $0.y >= 0 }, "\(model.name)")
            #expect(model.layout.key(for: .keyboard(0x29)) != nil, "\(model.name) has no Esc")
            #expect(model.layout.testableKeys.count >= 60, "\(model.name)")
        }
    }

    @Test func catalogNamesResolveToTheOfficialCatalog() {
        let releases = Self.catalog
        for model in KeyboardModel.all {
            let release = FirmwareUpdateService.latestRelease(for: model, in: releases)
            #expect((release != nil) == (model.catalogName != nil), "\(model.name)")
            #expect((model.catalogName == nil) == (model.firmwareFamily == .unpublished), "\(model.name)")
        }
        let mx10 = try? MultiModelFixtures.model(0x00BB)
        // The German variant shares the product ID; only the base name is matched.
        #expect(mx10.flatMap { FirmwareUpdateService.latestRelease(for: $0, in: releases)?.name } == "MX_BOARD_10.0_FL_RGB_0108")
    }
}

@Suite("多型号：按能力读写")
struct MultiModelServiceTests {
    @Test func wiredSnapshotNeverAsksForBatteryOrStatus() async throws {
        let device = RecordingConfigurationDevice()
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [4], respond: device.respond)])
        let snapshot = try await MultiModelFixtures.inspector(ports).vendorSnapshot(of: MultiModelFixtures.keyboard(0x0079))
        #expect(snapshot.battery == nil && snapshot.status == nil)
        #expect(!device.commands.contains(0x1A) && !device.commands.contains(0x1D))
        #expect(snapshot.configuration.profiles.count == 3)

        await #expect(throws: CherryError.self) {
            try await MultiModelFixtures.inspector(ports).battery(of: MultiModelFixtures.keyboard(0x0079))
        }
        await #expect(throws: CherryError.self) {
            try await MultiModelFixtures.inspector(ports).firmwareStatus(of: MultiModelFixtures.keyboard(0x0079))
        }
        #expect(ports.opens == 1)
    }

    @Test func wirelessSnapshotReadsBatteryAndStatus() async throws {
        let device = RecordingConfigurationDevice()
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [4], respond: device.respond)])
        let snapshot = try await MultiModelFixtures.inspector(ports).vendorSnapshot(of: MultiModelFixtures.keyboard(0x01E6))
        #expect(snapshot.battery?.percent == 0x50 && snapshot.status?.mode == .wireless(2))
    }

    @Test func fieldsTheDriverNeverWritesAreRejectedBeforeAnyIO() async throws {
        let ports = ServicePorts(channels: [])
        let base = ProfileSettings(effect: 0, brightness: 2, speed: 2, randomColor: false, color: .white, sleepSeconds: 0, deepSleepMinutes: 0)
        let configurator = MultiModelFixtures.configurator(ports)
        await #expect(throws: CherryError.self) {
            try await configurator.update(profile: 0, on: MultiModelFixtures.keyboard(0x0077), patch: .set(\.brightness, 4, field: .brightness, on: base))
        }
        await #expect(throws: CherryError.self) {
            try await configurator.update(profile: 0, on: MultiModelFixtures.keyboard(0x0079), patch: .set(\.sleepSeconds, 60, field: .sleepSeconds, on: base))
        }
        await #expect(throws: CherryError.self) {
            try await configurator.update(profile: 0, on: MultiModelFixtures.keyboard(0x00B4), patch: .set(\.color, LEDColor(r: 1, g: 2, b: 3), field: .color, on: base))
        }
        await #expect(throws: CherryError.self) {
            try await configurator.apply(.update(0, patch: .set(\.effect, 12, field: .effect, on: base)), on: MultiModelFixtures.keyboard(0x01E6))
        }
        #expect(ports.opens == 0)
    }

    @Test func lightingAndSleepAreWrittenAsSeparateRanges() async throws {
        let device = RecordingConfigurationDevice()
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [4], respond: device.respond)])
        let configurator = MultiModelFixtures.configurator(ports)
        let keyboard = MultiModelFixtures.keyboard(0x01E2)
        let current = try await configurator.configuration(of: keyboard).active.settings
        var target = current
        target.effect = 18
        target.sleepSeconds = 120
        let saved = try await configurator.update(profile: 0, on: keyboard, patch: ProfilePatch(target, fields: [.effect, .sleepSeconds]))
        #expect(saved.lightingEffect == 18 && saved.sleepSeconds == 120)
        #expect(device.writes.map(\.offset) == [1, 0x22])
        // Only the changed bytes: 0x23 (high byte of 120 s) is already 0.
        #expect(device.writes.map(\.bytes) == [[18], [120]])
    }

    @Test func pixiu99EffectKeepsTheHighBits() async throws {
        let device = RecordingConfigurationDevice { $0[1] = 0x80 | 3 }
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [4], respond: device.respond)])
        let configurator = MultiModelFixtures.configurator(ports)
        let keyboard = MultiModelFixtures.keyboard(0x01FB)
        let current = try await configurator.configuration(of: keyboard).active
        #expect(current.lightingEffect == 3)
        let saved = try await configurator.update(profile: 0, on: keyboard, patch: .set(\.effect, 18, field: .effect, on: current.settings))
        #expect(saved.lightingEffect == 18)
        #expect(device.byte(1) == 0x80 | 18)
    }

    @Test func typeBEffectsAreWrittenWithTheirOwnNumbering() async throws {
        let device = RecordingConfigurationDevice()
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [4], respond: device.respond)])
        let configurator = MultiModelFixtures.configurator(ports)
        let keyboard = MultiModelFixtures.keyboard(0x01E6)
        let current = try await configurator.configuration(of: keyboard).active.settings
        let saved = try await configurator.apply(.update(0, patch: .set(\.effect, 5, field: .effect, on: current)), on: keyboard)
        #expect(saved.active.lightingEffect == 5)
        #expect(device.writes.map(\.offset) == [1])
    }

    @Test func presetsOnlyCarryTheFieldsAModelCanStore() throws {
        let preset = ProfileSettings(effect: 18, brightness: 4, speed: 1, randomColor: true, color: .white, sleepSeconds: 60, deepSleepMinutes: 30)
        let base = ProfileSettings(effect: 0, brightness: 2, speed: 2, randomColor: false, color: LEDColor(r: 1, g: 1, b: 1), sleepSeconds: 0, deepSleepMinutes: 0)
        let wired = try MultiModelFixtures.model(0x0079)
        #expect(wired.applying(preset, onto: base) == ProfileSettings(effect: 18, brightness: 4, speed: 1, randomColor: true, color: .white, sleepSeconds: 0, deepSleepMinutes: 0))
        // Effect 18 is not in the type-B table: keep the keyboard's own effect.
        let pixiu98 = try MultiModelFixtures.model(0x01E6)
        #expect(pixiu98.applicableFields(of: preset) == [.brightness, .speed, .randomColor, .color, .sleepSeconds, .deepSleepMinutes])
        #expect(try MultiModelFixtures.model(0x0077).applying(preset, onto: base) == base)
    }
}
