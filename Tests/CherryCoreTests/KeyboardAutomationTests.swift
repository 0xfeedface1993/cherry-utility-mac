import Foundation
import Synchronization
import Testing
@testable import CherryCore

/// 每次 `keyboards()` 依次返回脚本中的下一份列表，最后一份保持不变。
final class ScriptedDiscovery: KeyboardDiscoveryPort, Sendable {
    private let lists: Mutex<[[KeyboardSummary]]>
    private let count = Mutex(0)

    init(_ lists: [[KeyboardSummary]]) { self.lists = Mutex(lists) }

    var calls: Int { count.withLock { $0 } }

    func keyboards() async -> [KeyboardSummary] {
        count.withLock { $0 += 1 }
        return lists.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }

    func keyboardUpdates() -> AsyncStream<[KeyboardSummary]> {
        let current = lists.withLock { $0.last ?? [] }
        return AsyncStream { $0.yield(current); $0.finish() }
    }
}

/// 记录提交的意图，并按意图返回“读回”的配置。
final class AutomationProbe: Sendable {
    let base: KeyboardConfiguration
    private let intents = Mutex<[(ConfigurationIntent, KeyboardID)]>([])
    private let reads = Mutex(0)
    private let failure = Mutex<CherryError?>(nil)

    init(activeProfile: Int = 1) {
        base = try! KeyboardConfiguration(activeProfile: activeProfile, profiles: (0..<3).map { n in
            var raw = [UInt8](repeating: 0, count: 64)
            raw[1] = 0; raw[2] = 4; raw[3] = 2; raw[6] = 0xFF
            return try ProfileConfig(profile: n, raw: raw)
        })
    }

    var submitted: [(ConfigurationIntent, KeyboardID)] { intents.withLock { $0 } }
    var readCount: Int { reads.withLock { $0 } }
    func fail(with error: CherryError?) { failure.withLock { $0 = error } }

    func automation(
        _ discovery: some KeyboardDiscoveryPort, presets: [ProfilePreset] = [], activity: FirmwareActivity? = nil,
        feed: ConfigurationChangeFeed = .init(), battery: BatteryStatus? = nil
    ) -> KeyboardAutomation {
        KeyboardAutomation(
            discovery: discovery,
            snapshot: { [base] _ in VendorSnapshot(battery: battery, status: nil, configuration: base) },
            battery: { _ in try #require(battery) },
            configuration: { [base] _ in self.reads.withLock { $0 += 1 }; return base },
            apply: { [base] intent, keyboard in
                if let error = self.failure.withLock({ $0 }) { throw error }
                self.intents.withLock { $0.append((intent, keyboard.id)) }
                return intent.applied(to: base)
            },
            presets: { presets },
            feed: feed, activity: activity, clock: ImmediateClock()
        )
    }
}

@Suite("自动化用例：选键盘、校验与只写请求字段")
struct KeyboardAutomationTests {
    static func keyboard(_ productID: UInt16 = 0x01E2, location: UInt32 = 1, configurable: Bool = true) -> KeyboardSummary {
        let interfaces: [HIDInterfaceSummary] = configurable
            ? [.init(id: UInt64(location), usages: [.init(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])]
            : []
        return KeyboardSummary(id: KeyboardID(vendorID: 0x046A, productID: productID, locationID: location), product: "Keyboard",
                               manufacturer: "CHERRY", serialNumber: nil, transport: "USB", releaseNumber: 0x0117, interfaces: interfaces)
    }
    static let pixiu75 = keyboard()
    static let nbl = keyboard(0x0077, location: 2)          // 有线无背光
    static let wiredRGB = keyboard(0x0079, location: 3)     // 有线 RGB，无休眠
    static let singleColor = keyboard(0x00B4, location: 4)  // 单色背光
    static let pixiu98 = keyboard(0x01E6, location: 5)      // B 型灯效表

    static func discovery(_ keyboards: KeyboardSummary...) -> ScriptedDiscovery { ScriptedDiscovery([keyboards]) }

    // MARK: - Identity and names

    @Test func keyboardIDRoundTripsThroughItsDescription() {
        let id = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0310_0000)
        #expect(KeyboardID(id.description) == id)
        #expect(KeyboardID("046a:01e2@03100000") == id)
        for bad in ["", "046A:01E2", "046A01E2@03100000", "046A:01E2@0310000", "+46A:01E2@03100000", "046A:01E2@0310000G"] {
            #expect(KeyboardID(bad) == nil, "\(bad)")
        }
    }

    @Test func effectNamesResolvePerModelInEnglishOrChinese() throws {
        let pixiu98 = try #require(Self.pixiu98.model), pixiu75 = KeyboardModel.pixiu75
        #expect(pixiu98.lightingEffect(named: "breathing")?.rawValue == 8)
        #expect(pixiu75.lightingEffect(named: "Breathing")?.rawValue == 2)
        #expect(pixiu98.lightingEffect(named: "SingleKey")?.rawValue == 2)
        #expect(pixiu98.lightingEffect(named: "single key")?.rawValue == 2)
        #expect(pixiu98.lightingEffect(named: "彩虹雨")?.rawValue == 5)
        #expect(pixiu75.lightingEffect(named: "Rainbow Rain") == nil)
        #expect(pixiu75.lightingEffect(named: "  ") == nil)
        #expect(KeyboardModel.pixiu75Pokemon.lightingEffect(named: "对战")?.rawValue == 23)
    }

    @Test func catalogEffectNamesAreListedOnce() {
        let names = KeyboardModel.allLightingEffects.map(\.englishName)
        #expect(names.count == Set(names).count)
        #expect(Set(names) == [
            "Wave", "Spectrum", "Breathing", "Rolling", "Curve", "Scan", "Radiation", "Ripples", "Single Key", "Static", "Custom",
            "Rainbow Rain", "RGB Static", "Lightning", "Flame", "Battle",
        ])
        #expect(Set(KeyboardModel.all.flatMap(\.lightingEffects).map(\.englishName)) == Set(names))
    }

    @Test func colorParsingAcceptsHexAndRandom() throws {
        #expect(try SettingsRequest.Color(parsing: "#00D70F") == .fixed(LEDColor(r: 0, g: 0xD7, b: 0x0F)))
        #expect(try SettingsRequest.Color(parsing: " ff7200 ") == .fixed(LEDColor(r: 0xFF, g: 0x72, b: 0)))
        #expect(try SettingsRequest.Color(parsing: "Random") == .random)
        #expect(try SettingsRequest.Color(parsing: "随机") == .random)
        #expect(throws: AutomationError.invalidColor("#12")) { try SettingsRequest.Color(parsing: "#12") }
    }

    @Test func presetPatchTakesOnlyWhatTheModelAccepts() throws {
        let settings = ProfileSettings(effect: 5, brightness: 2, speed: 1, randomColor: false, color: .white, sleepSeconds: 60, deepSleepMinutes: 30)
        let preset = ProfilePreset(name: "彩虹雨", createdAt: .now, productID: nil, settings: settings)
        #expect(preset.patch(for: try #require(Self.pixiu98.model)).fields.contains(.effect))
        #expect(!preset.patch(for: .pixiu75).fields.contains(.effect))
        #expect(preset.patch(for: .pixiu75).fields.isSuperset(of: [.brightness, .sleepSeconds]))
        #expect(preset.patch(for: try #require(Self.nbl.model)).isEmpty)
    }

    // MARK: - Choosing the keyboard

    @Test func choosesTheOnlyOrTheOnlyConfigurableKeyboard() async throws {
        let probe = AutomationProbe()
        #expect(try await probe.automation(Self.discovery(Self.pixiu75)).keyboard(nil) == Self.pixiu75)
        let mixed = Self.keyboard(0x01E2, location: 9, configurable: false)
        #expect(try await probe.automation(Self.discovery(mixed, Self.nbl)).keyboard(nil) == Self.nbl)
        let unknown = Self.keyboard(0x0999, location: 7)
        #expect(try await probe.automation(Self.discovery(unknown, Self.pixiu75)).keyboard(nil) == Self.pixiu75)
    }

    @Test func refusesWhenNoneOrSeveralKeyboardsMatch() async throws {
        let probe = AutomationProbe()
        await #expect(throws: AutomationError.noKeyboard) { try await probe.automation(Self.discovery()).keyboard(nil) }
        await #expect(throws: AutomationError.noKeyboard) {
            try await probe.automation(Self.discovery(Self.keyboard(0x0999))).keyboard(nil)
        }
        await #expect(throws: AutomationError.ambiguousKeyboard([Self.pixiu75, Self.nbl])) {
            try await probe.automation(Self.discovery(Self.pixiu75, Self.nbl)).keyboard(nil)
        }
    }

    @Test func explicitIDMatchesExactlyOrByUniqueProduct() async throws {
        let probe = AutomationProbe()
        let second = Self.keyboard(0x01E2, location: 2)
        let both = probe.automation(Self.discovery(Self.pixiu75, second, Self.nbl))
        #expect(try await both.keyboard(second.id) == second)
        // 换了 USB 口：同型号只有一把时仍能找到。
        let moved = KeyboardID(vendorID: 0x046A, productID: 0x0077, locationID: 0xAA)
        #expect(try await both.keyboard(moved) == Self.nbl)
        let stale = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0xAA)
        await #expect(throws: CherryError.deviceNotFound(stale)) { try await both.keyboard(stale) }
        let absent = KeyboardID(vendorID: 0x046A, productID: 0x0079, locationID: 3)
        await #expect(throws: CherryError.deviceNotFound(absent)) { try await both.keyboard(absent) }
    }

    @Test func coldStartWaitsForDiscoveryToSettleOnce() async throws {
        let probe = AutomationProbe()
        let second = Self.keyboard(0x01E2, location: 2)
        // IOKit 先发布一把键盘、稍后才发布第二把：静默窗口后两把都在，必须报歧义而不是悄悄选第一把。
        let discovery = ScriptedDiscovery([[], [], [Self.pixiu75], [Self.pixiu75, second]])
        let automation = probe.automation(discovery)
        await #expect(throws: AutomationError.ambiguousKeyboard([Self.pixiu75, second])) { try await automation.keyboard(nil) }
        let calls = discovery.calls
        #expect(try await automation.keyboard(second.id) == second)
        #expect(discovery.calls == calls + 1)
    }

    @Test func coldStartGivesUpAfterTheTimeout() async throws {
        let discovery = ScriptedDiscovery([[]])
        let automation = AutomationProbe().automation(discovery)
        await #expect(throws: AutomationError.noKeyboard) { try await automation.keyboard(nil) }
        #expect(discovery.calls == 31) // 首次 + 3 s / 100 ms
        await #expect(throws: AutomationError.noKeyboard) { try await automation.keyboard(nil) }
        #expect(discovery.calls == 32)
    }

    // MARK: - Reading

    @Test func statusReadsTheSnapshotOnlyWhenTheKeyboardCanBeConfigured() async throws {
        let probe = AutomationProbe()
        let status = try await probe.automation(Self.discovery(Self.pixiu75)).status(of: nil)
        #expect(status.model == .pixiu75 && status.snapshot?.configuration == probe.base)
        let bluetooth = Self.keyboard(0x01E2, location: 9, configurable: false)
        let offline = try await probe.automation(Self.discovery(bluetooth)).status(of: nil)
        #expect(offline.snapshot == nil && offline.keyboard == bluetooth)
    }

    @Test func batteryIsRefusedForWiredBoards() async throws {
        let battery = try BatteryStatus(raw: [80, 1])
        let wireless = try await AutomationProbe().automation(Self.discovery(Self.pixiu75), battery: battery).battery(of: nil)
        #expect(wireless.battery.percent == 80 && wireless.keyboard == Self.pixiu75)
        let wired = try #require(Self.wiredRGB.model)
        await #expect(throws: AutomationError.noBattery(model: wired)) {
            try await AutomationProbe().automation(Self.discovery(Self.wiredRGB)).battery(of: nil)
        }
    }

    // MARK: - Writing

    @Test func updateWritesOnlyRequestedFieldsToTheActiveProfile() async throws {
        let probe = AutomationProbe(activeProfile: 1)
        let automation = probe.automation(Self.discovery(Self.pixiu75))
        let result = try await automation.update(SettingsRequest(effect: "Breathing", brightness: 2), profile: nil, on: nil)
        #expect(probe.readCount == 1)
        let (intent, id) = try #require(probe.submitted.first)
        #expect(id == Self.pixiu75.id && intent.activeProfile == nil)
        #expect(intent.patches.keys.sorted() == [1])
        #expect(intent.patches[1]?.fields == [.effect, .brightness])
        #expect(result.profile == 1 && result.settings?.effect == 2 && result.settings?.brightness == 2)
        #expect(result.settings?.speed == probe.base.profile(1)?.speed)
    }

    @Test func explicitProfileSkipsTheReadAndColorsSetTheRandomFlag() async throws {
        let probe = AutomationProbe()
        let automation = probe.automation(Self.discovery(Self.pixiu75))
        let fixed = try await automation.update(SettingsRequest(color: .fixed(LEDColor(r: 0, g: 0x99, b: 0xFF))), profile: 2, on: nil)
        #expect(probe.readCount == 0)
        #expect(probe.submitted[0].0.patches[2]?.fields == [.color, .randomColor])
        #expect(fixed.settings?.color == LEDColor(r: 0, g: 0x99, b: 0xFF) && fixed.settings?.randomColor == false)
        let random = try await automation.update(SettingsRequest(color: .random), profile: 0, on: nil)
        #expect(probe.submitted[1].0.patches[0]?.fields == [.randomColor])
        #expect(random.settings?.randomColor == true)
    }

    @Test func activateValidatesTheProfileNumber() async throws {
        let probe = AutomationProbe()
        let automation = probe.automation(Self.discovery(Self.pixiu75))
        let result = try await automation.activate(profile: 2, on: nil)
        #expect(result.configuration.activeProfile == 2 && probe.submitted[0].0 == .activate(2))
        await #expect(throws: AutomationError.profileOutOfRange(3, model: .pixiu75)) { try await automation.activate(profile: 3, on: nil) }
        await #expect(throws: AutomationError.profileOutOfRange(-1, model: .pixiu75)) {
            try await automation.update(SettingsRequest(brightness: 1), profile: -1, on: nil)
        }
    }

    @Test func requestsAreValidatedAgainstTheModelBeforeWriting() async throws {
        let probe = AutomationProbe()
        let pixiu = probe.automation(Self.discovery(Self.pixiu75))
        await #expect(throws: AutomationError.nothingToChange) { try await pixiu.update(SettingsRequest(), profile: nil, on: nil) }
        await #expect(throws: AutomationError.valueOutOfRange(.brightness, 5)) { try await pixiu.update(SettingsRequest(brightness: 5), profile: 0, on: nil) }
        await #expect(throws: AutomationError.valueOutOfRange(.speed, -1)) { try await pixiu.update(SettingsRequest(speed: -1), profile: 0, on: nil) }
        await #expect(throws: AutomationError.valueOutOfRange(.sleepSeconds, 10)) { try await pixiu.update(SettingsRequest(sleepSeconds: 10), profile: 0, on: nil) }
        await #expect(throws: AutomationError.valueOutOfRange(.deepSleepMinutes, 14)) {
            try await pixiu.update(SettingsRequest(deepSleepMinutes: 14), profile: 0, on: nil)
        }
        await #expect(throws: AutomationError.unknownEffect("Rainbow Rain", model: .pixiu75)) {
            try await pixiu.update(SettingsRequest(effect: "Rainbow Rain"), profile: 0, on: nil)
        }
        _ = try await pixiu.update(SettingsRequest(sleepSeconds: 0, deepSleepMinutes: 300), profile: 0, on: nil)
        #expect(probe.submitted.count == 1)

        let nbl = try #require(Self.nbl.model), single = try #require(Self.singleColor.model), wired = try #require(Self.wiredRGB.model)
        await #expect(throws: AutomationError.fieldUnsupported(.effect, model: nbl)) {
            try await probe.automation(Self.discovery(Self.nbl)).update(SettingsRequest(effect: "Wave"), profile: 0, on: nil)
        }
        await #expect(throws: AutomationError.fieldUnsupported(.color, model: single)) {
            try await probe.automation(Self.discovery(Self.singleColor)).update(SettingsRequest(color: .fixed(.white)), profile: 0, on: nil)
        }
        await #expect(throws: AutomationError.fieldUnsupported(.randomColor, model: single)) {
            try await probe.automation(Self.discovery(Self.singleColor)).update(SettingsRequest(color: .random), profile: 0, on: nil)
        }
        await #expect(throws: AutomationError.fieldUnsupported(.sleepSeconds, model: wired)) {
            try await probe.automation(Self.discovery(Self.wiredRGB)).update(SettingsRequest(sleepSeconds: 60), profile: 0, on: nil)
        }
        #expect(probe.submitted.count == 1)
    }

    @Test func writesNeedTheConfigurationInterface() async throws {
        let bluetooth = Self.keyboard(0x01E2, location: 9, configurable: false)
        await #expect(throws: CherryError.interfaceNotFound(usagePage: 0xFF1C)) {
            try await AutomationProbe().automation(Self.discovery(bluetooth)).activate(profile: 0, on: nil)
        }
    }

    @Test func presetsLoadLikeTheMenuBar() async throws {
        let settings = ProfileSettings(effect: 12, brightness: 3, speed: 4, randomColor: true, color: .white, sleepSeconds: 120, deepSleepMinutes: 60)
        let office = ProfilePreset(name: "办公", createdAt: .now, productID: 0x01E2, settings: settings)
        let other = ProfilePreset(name: "别的型号", createdAt: .now, productID: 0x0079, settings: settings)
        let any = ProfilePreset(name: "通用", createdAt: .now, productID: nil, settings: settings)
        let probe = AutomationProbe()
        let automation = probe.automation(Self.discovery(Self.pixiu75), presets: [office, other, any])
        #expect(try await automation.presets().map(\.name) == ["办公", "别的型号", "通用"])
        let result = try await automation.applyPreset(id: office.id, profile: 0, on: nil)
        #expect(probe.submitted[0].0.patches[0] == office.patch(for: .pixiu75))
        #expect(result.settings?.effect == 12 && result.settings?.sleepSeconds == 120)
        await #expect(throws: AutomationError.presetIncompatible(name: "别的型号")) { try await automation.applyPreset(id: other.id, profile: 0, on: nil) }
        let missing = UUID()
        await #expect(throws: AutomationError.presetNotFound(missing)) { try await automation.applyPreset(id: missing, profile: 0, on: nil) }
        await #expect(throws: AutomationError.nothingToChange) {
            try await probe.automation(Self.discovery(Self.nbl), presets: [any]).applyPreset(id: any.id, profile: 0, on: nil)
        }
    }

    @Test func firmwareFlashBlocksWritesToThatKeyboardOnly() async throws {
        let activity = FirmwareActivity()
        let probe = AutomationProbe()
        let automation = probe.automation(Self.discovery(Self.pixiu75, Self.nbl), activity: activity)
        try await activity.during(Self.pixiu75.id) {
            await #expect(throws: AutomationError.firmwareUpdateInProgress) { try await automation.activate(profile: 0, on: Self.pixiu75.id) }
            _ = try await automation.activate(profile: 0, on: Self.nbl.id)
            _ = try await automation.status(of: Self.pixiu75.id)
        }
        #expect(!activity.isBusy(Self.pixiu75.id))
        _ = try await automation.activate(profile: 0, on: Self.pixiu75.id)
        #expect(probe.submitted.map(\.1) == [Self.nbl.id, Self.pixiu75.id])
    }

    @Test func firmwareActivityClearsWhenTheFlashFails() async throws {
        let activity = FirmwareActivity()
        await #expect(throws: CherryError.disconnected) {
            try await activity.during(Self.pixiu75.id) { () async throws -> Int in throw CherryError.disconnected }
        }
        #expect(!activity.isBusy(Self.pixiu75.id))
    }

    @Test func successfulWritesAreBroadcastToEverySubscriber() async throws {
        let feed = ConfigurationChangeFeed()
        let probe = AutomationProbe()
        let automation = probe.automation(Self.discovery(Self.pixiu75), feed: feed)
        var first = automation.changes().makeAsyncIterator()
        var second = feed.changes().makeAsyncIterator()
        probe.fail(with: .writeNotApplied("x"))
        await #expect(throws: CherryError.writeNotApplied("x")) { try await automation.activate(profile: 0, on: nil) }
        probe.fail(with: nil)
        let result = try await automation.activate(profile: 2, on: nil)
        let expected = ExternalConfigurationChange(keyboardID: Self.pixiu75.id, change: .configuration(result.configuration))
        #expect(await first.next() == expected)
        #expect(await second.next() == expected)
    }
}
