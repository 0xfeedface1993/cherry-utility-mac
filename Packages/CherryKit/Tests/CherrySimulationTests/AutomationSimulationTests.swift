import CherryCore
import CherrySimulation
import Foundation
import Testing

/// 自动化用例跑在真实 Core 装配（独占通道、合并写入队列、协议编解码）和模拟键盘上。
@Suite("自动化用例：模拟键盘集成")
struct AutomationSimulationTests {
    struct Stack {
        let hub: SimulatedKeyboardHub
        let automation: KeyboardAutomation
        let presets: PresetLibrary
    }

    final class MemoryPresets: ProfilePresetStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ProfilePreset] = []
        func presets() async throws -> [ProfilePreset] { lock.withLock { items } }
        func save(_ preset: ProfilePreset) async throws { lock.withLock { items.insert(preset, at: 0) } }
        func delete(id: UUID) async throws { lock.withLock { items.removeAll { $0.id == id } } }
    }

    static func stack(_ scenario: String = "pixiu75", sharedState: URL? = nil) -> Stack {
        var named = SimulatedKeyboardHub.Scenario.named(scenario)
        named.sharedState = sharedState
        let hub = SimulatedKeyboardHub(scenario: named)
        let services = CoreServices(discovery: hub, channels: hub, catalog: SimulatedFirmwareCatalog(), downloader: SimulatedFirmwareCatalog())
        let presets = PresetLibrary(store: MemoryPresets())
        let timing = KeyboardAutomation.Timing(discoveryTimeout: .milliseconds(50), settle: .zero, poll: .milliseconds(10))
        return Stack(hub: hub, automation: services.automation(presets: presets, timing: timing), presets: presets)
    }

    @Test func pixiu75StatusAndWritesReadBackFromTheKeyboard() async throws {
        let s = Self.stack()
        let status = try await s.automation.status(of: nil)
        #expect(status.model == .pixiu75)
        let snapshot = try #require(status.snapshot)
        #expect(snapshot.battery?.percent == 95 && snapshot.battery?.charging == .charging)
        #expect(snapshot.configuration.activeProfile == 1 && snapshot.configuration.active.lightingEffect == 0)

        let activated = try await s.automation.activate(profile: 0, on: nil)
        #expect(activated.configuration.activeProfile == 0)
        let lit = try await s.automation.update(SettingsRequest(effect: "呼吸", brightness: 2, speed: 4), profile: nil, on: nil)
        #expect(lit.profile == 0)
        #expect(lit.settings?.effect == 2 && lit.settings?.brightness == 2 && lit.settings?.speed == 4)
        let colored = try await s.automation.update(SettingsRequest(color: .fixed(LEDColor(hex: "#00D70F")!)), profile: 2, on: nil)
        #expect(colored.settings?.color == LEDColor(hex: "#00D70F") && colored.settings?.randomColor == false)
        let asleep = try await s.automation.update(SettingsRequest(sleepSeconds: 0, deepSleepMinutes: 120), profile: 1, on: nil)
        #expect(asleep.settings?.sleepSeconds == 0 && asleep.settings?.deepSleepMinutes == 120)

        // 其余字节保持键盘原值：profile 1 的灯效和颜色没有被休眠写入改动。
        let after = try await s.automation.status(of: nil).snapshot?.configuration
        #expect(after?.profile(1)?.lightingEffect == snapshot.configuration.profile(1)?.lightingEffect)
        #expect(after?.profile(1)?.randomColor == snapshot.configuration.profile(1)?.randomColor)
        #expect(after?.activeProfile == 0)
    }

    /// 两套各自装配的 Core（相当于 App 与直连的命令行）对着同一个状态文件：一方写入，另一方读到。
    @Test func processesSharingAStateFileSeeEachOthersWrites() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "CherrySimulationState-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + ".lock"))
        }
        let app = Self.stack(sharedState: file), cli = Self.stack(sharedState: file)
        _ = try await cli.automation.update(SettingsRequest(effect: "呼吸", brightness: 1), profile: 2, on: nil)
        _ = try await cli.automation.activate(profile: 0, on: nil)
        let seen = try #require(try await app.automation.status(of: nil).snapshot?.configuration)
        #expect(seen.activeProfile == 0 && seen.profile(2)?.lightingEffect == 2 && seen.profile(2)?.brightness == 1)
        // 新启动的一方从文件开始，而不是从模拟场景的初始值开始。
        let later = try #require(try await Self.stack(sharedState: file).automation.status(of: nil).snapshot?.configuration)
        #expect(later == seen)
    }

    /// 不指定配置档的并发写入与切换（B4）：每个写入报告的配置档里都有它写的字段，报告的就是读回里它落到的那一档。
    @Test func concurrentActiveProfileWritesReportWhereTheyLanded() async throws {
        let s = Self.stack()
        async let dim = s.automation.update(SettingsRequest(brightness: 1), profile: nil, on: nil)
        async let fast = s.automation.update(SettingsRequest(speed: 4), profile: nil, on: nil)
        async let switched = s.automation.activate(profile: 0, on: nil)
        let (a, b, c) = try await (dim, fast, switched)
        #expect(a.settings?.brightness == 1 && b.settings?.speed == 4 && c.configuration.activeProfile == 0)
        #expect(a.profile == a.configuration.activeProfile && b.profile == b.configuration.activeProfile)
        let after = try #require(try await s.automation.status(of: nil).snapshot?.configuration)
        #expect(after.profile(a.profile)?.brightness == 1 && after.profile(b.profile)?.speed == 4)
    }

    @Test func presetsLoadIntoTheActiveProfile() async throws {
        let s = Self.stack()
        let keyboard = try await s.automation.keyboard(nil)
        let settings = ProfileSettings(effect: 12, brightness: 3, speed: 1, randomColor: false, color: LEDColor(hex: "FF7200")!, sleepSeconds: 60, deepSleepMinutes: 30)
        let preset = try await s.presets.save(name: "曲线高亮", settings: settings, from: keyboard)
        let result = try await s.automation.applyPreset(id: preset.id, profile: nil, on: nil)
        #expect(result.profile == 1 && result.settings == settings)
    }

    @Test func dualKeyboardsNeedAnExplicitChoice() async throws {
        let s = Self.stack("dual")
        let keyboards = try await s.automation.keyboards()
        #expect(keyboards.map(\.id) == [SimulatedKeyboardHub.keyboardID, SimulatedKeyboardHub.secondKeyboardID])
        await #expect(throws: AutomationError.ambiguousKeyboard(keyboards)) { try await s.automation.activate(profile: 0, on: nil) }
        _ = try await s.automation.activate(profile: 2, on: SimulatedKeyboardHub.secondKeyboardID)
        #expect(try await s.automation.status(of: SimulatedKeyboardHub.secondKeyboardID).snapshot?.configuration.activeProfile == 2)
        #expect(try await s.automation.status(of: SimulatedKeyboardHub.keyboardID).snapshot?.configuration.activeProfile == 1)
    }

    @Test func otherModelsAreLimitedToTheirCapabilities() async throws {
        let nbl = Self.stack("nbl")
        let nblModel = try #require(try await nbl.automation.keyboard(nil).model)
        await #expect(throws: AutomationError.fieldUnsupported(.effect, model: nblModel)) {
            try await nbl.automation.update(SettingsRequest(effect: "Wave"), profile: nil, on: nil)
        }
        #expect(try await nbl.automation.activate(profile: 2, on: nil).configuration.activeProfile == 2)

        let wired = Self.stack("mx30s")
        let wiredModel = try #require(try await wired.automation.keyboard(nil).model)
        await #expect(throws: AutomationError.noBattery(model: wiredModel)) { try await wired.automation.battery(of: nil) }
        #expect(try await wired.automation.status(of: nil).snapshot?.battery == nil)
        await #expect(throws: AutomationError.fieldUnsupported(.sleepSeconds, model: wiredModel)) {
            try await wired.automation.update(SettingsRequest(sleepSeconds: 60), profile: nil, on: nil)
        }

        let receiver = Self.stack("receiver")
        let battery = try await receiver.automation.battery(of: nil).battery
        #expect(battery.percent == 64)
        #expect(try await receiver.automation.status(of: nil).snapshot?.status?.mode != .wired)
    }

    @Test func effectNamesResolveInTheTypeBTable() async throws {
        let s = Self.stack("pixiu98")
        #expect(try await s.automation.update(SettingsRequest(effect: "Breathing"), profile: 0, on: nil).settings?.effect == 8)
        #expect(try await s.automation.update(SettingsRequest(effect: "彩虹雨"), profile: 0, on: nil).settings?.effect == 5)
        #expect(try await s.automation.lightingEffects(of: nil).effects == KeyboardModel.pixiu98.lightingEffects)
        await #expect(throws: AutomationError.unknownEffect("彩虹雨", model: .pixiu75)) {
            try await Self.stack().automation.update(SettingsRequest(effect: "彩虹雨"), profile: 0, on: nil)
        }
    }

    @Test func missingUnsupportedAndDeniedKeyboardsAreReported() async throws {
        await #expect(throws: AutomationError.noKeyboard) { try await Self.stack("empty").automation.status(of: nil) }
        await #expect(throws: AutomationError.noKeyboard) { try await Self.stack("unsupported").automation.status(of: nil) }
        await #expect(throws: CherryError.accessDenied) { try await Self.stack("denied").automation.status(of: nil) }
    }

    @Test func automationWritesAreBroadcast() async throws {
        let s = Self.stack()
        var changes = s.automation.changes().makeAsyncIterator()
        let result = try await s.automation.activate(profile: 2, on: nil)
        let change = try #require(await changes.next())
        #expect(change.keyboardID == SimulatedKeyboardHub.keyboardID && change.change == .configuration(result.configuration))
    }
}
