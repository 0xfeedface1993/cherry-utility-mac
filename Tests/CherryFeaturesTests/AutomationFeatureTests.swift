import CherryCore
import CherryPresentation
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("自动化入口：界面同步与文案")
struct AutomationFeatureTests {
    static let other = KeyboardSummary(
        id: KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0320_0000), product: "PIXIU 75", manufacturer: "CHERRY",
        serialNumber: nil, transport: "USB", releaseNumber: 0x0117, interfaces: KeyboardSummary.preview.interfaces
    )
    static let activated = try! KeyboardConfiguration(activeProfile: 2, profiles: KeyboardConfiguration.preview.profiles)

    static func state(detail keyboard: KeyboardSummary) -> AppFeature.State {
        var state = AppFeature.State()
        state.keyboards = [.preview, other]
        state.detail = KeyboardFeature.State(keyboard: keyboard)
        state.detail?.configuration.configuration = .loaded(.preview)
        state.detail?.info.vendor = .loaded(.preview)
        state.menuBar.keyboards = [.preview, other]
        state.menuBar.snapshot = .loaded(.preview)
        state.menuBar.snapshotID = KeyboardSummary.preview.id
        return state
    }

    @Test func externalWriteRefreshesMenuBarAndTheMatchingDetail() async {
        let store = TestStore(initialState: Self.state(detail: .preview)) { AppFeature() }
        store.exhaustivity = .off
        let change = ExternalConfigurationChange(keyboardID: KeyboardSummary.preview.id, change: .configuration(Self.activated))
        await store.send(.externalConfigurationChanged(change))
        await store.receive(\.menuBar.configurationSynchronized)
        await store.receive(\.detail.configuration.configurationSynchronized)
        await store.receive(\.detail.info.configurationSynchronized)
        #expect(store.state.menuBar.currentSnapshot?.configuration.activeProfile == 2)
        #expect(store.state.detail?.configuration.configuration.value?.activeProfile == 2)
        #expect(store.state.detail?.info.vendor.value?.configuration.activeProfile == 2)
        #expect(store.state.detail?.info.vendor.value?.battery == VendorSnapshot.preview.battery)
    }

    @Test func externalWriteToAnotherKeyboardLeavesTheDetailAlone() async {
        let store = TestStore(initialState: Self.state(detail: Self.other)) { AppFeature() }
        store.exhaustivity = .off
        await store.send(.externalConfigurationChanged(.init(keyboardID: KeyboardSummary.preview.id, change: .configuration(Self.activated))))
        await store.receive(\.menuBar.configurationSynchronized)
        await store.finish()
        #expect(store.state.menuBar.currentSnapshot?.configuration.activeProfile == 2)
        #expect(store.state.detail?.configuration.configuration.value == .preview)
        #expect(store.state.detail?.info.vendor.value?.configuration == .preview)
    }

    @Test func startListensForExternalWrites() async {
        let (changes, continuation) = AsyncStream.makeStream(of: ExternalConfigurationChange.self)
        let store = TestStore(initialState: Self.state(detail: .preview)) { AppFeature() } withDependencies: {
            $0.keyboardClient.updates = { AsyncStream { _ in } }
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.presetClient.presets = { [] }
            $0.configurationChangeClient.changes = { changes }
            $0.continuousClock = TestClock()
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        let task = await store.send(.task)
        continuation.yield(.init(keyboardID: KeyboardSummary.preview.id, change: .configuration(Self.activated)))
        await store.receive(\.externalConfigurationChanged)
        await task.cancel()
    }

    // MARK: - Text

    @Test func everyAutomationErrorHasChineseText() throws {
        let nbl = try #require(KeyboardModel.matching(vendorID: 0x046A, productID: 0x0077))
        let errors: [AutomationError] = [
            .noKeyboard, .ambiguousKeyboard([.preview, Self.other]), .fieldUnsupported(.effect, model: nbl),
            .fieldUnsupported(.randomColor, model: nbl), .fieldUnsupported(.sleepSeconds, model: nbl), .unknownEffect("彩虹雨", model: .pixiu75),
            .valueOutOfRange(.brightness, 9), .valueOutOfRange(.speed, 7), .valueOutOfRange(.sleepSeconds, 10), .valueOutOfRange(.deepSleepMinutes, 1),
            .profileOutOfRange(3, model: .pixiu75), .noBattery(model: nbl), .invalidColor("#12"), .presetNotFound(UUID()),
            .presetIncompatible(name: "办公"), .nothingToChange, .firmwareUpdateInProgress,
        ]
        for error in errors {
            #expect(error.userMessage.unicodeScalars.contains { $0.properties.isIdeographic }, "\(error)")
        }
        #expect(AutomationError.ambiguousKeyboard([.preview, Self.other]).userMessage
            == "连接了多把键盘（CHERRY MX PIXIU 75 · 03100000、CHERRY MX PIXIU 75 · 03200000），请在操作的「键盘」参数里选择一把")
        #expect(AutomationError.fieldUnsupported(.effect, model: nbl).userMessage == "MX BOARD 3.0S FL NBL 没有背光，不能设置灯效")
        #expect(AutomationError.unknownEffect("彩虹雨", model: .pixiu75).userMessage.hasPrefix("MX PIXIU 75 没有「彩虹雨」灯效，可选：波纹、光谱"))
        #expect(AutomationError.profileOutOfRange(3, model: .pixiu75).userMessage == "MX PIXIU 75 只有 3 个配置档，没有配置 4")
        #expect(AutomationError.valueOutOfRange(.speed, 7).userMessage == "速度须为 1–5，收到 8")
    }

    @Test func statusTextSummarisesBatteryConnectionAndLighting() throws {
        let wireless = KeyboardStatusReport(keyboard: .preview, model: .pixiu75, snapshot: .preview)
        #expect(AutomationText.status(wireless) == "CHERRY MX PIXIU 75 · 电量 95%（充电中） · 有线 USB · 固件 0.1.1.7 · 配置 2 · 波纹 · 亮度 全亮")
        let nbl = try #require(KeyboardModel.matching(vendorID: 0x046A, productID: 0x0077))
        let wiredKeyboard = KeyboardSummary(id: KeyboardID(vendorID: 0x046A, productID: 0x0077, locationID: 1), product: "MX 3.0S", manufacturer: "CHERRY",
                                            serialNumber: nil, transport: "USB", releaseNumber: 0x0120, interfaces: [])
        let wired = KeyboardStatusReport(keyboard: wiredKeyboard, model: nbl,
                                         snapshot: VendorSnapshot(battery: nil, status: nil, configuration: .preview))
        #expect(AutomationText.status(wired) == "CHERRY MX BOARD 3.0S FL NBL · USB · 固件 0.1.2.0 · 配置 2 · 无背光")
        let bluetooth = KeyboardStatusReport(keyboard: wiredKeyboard, model: nbl, snapshot: nil)
        #expect(AutomationText.status(bluetooth).hasSuffix("没有配置接口，读不到配置（请用 USB 线或 2.4G 接收器连接）"))
    }

    @Test func resultTextListsOnlyRequestedFields() throws {
        let result = AutomationResult(keyboard: .preview, model: .pixiu75, configuration: .preview, profile: 0)
        #expect(AutomationText.activated(AutomationResult(keyboard: .preview, model: .pixiu75, configuration: .preview, profile: 1))
            == "已切换到配置 2（波纹 · 亮度 全亮）")
        #expect(AutomationText.updated(result, request: SettingsRequest(effect: "放射", brightness: 4))
            == "已更新配置 1：灯效 放射，亮度 全亮")
        #expect(AutomationText.updated(result, request: SettingsRequest(speed: 2, color: .random, sleepSeconds: 300))
            == "已更新配置 1：速度 3 / 5，颜色 #33FF33，休眠 300 秒")
        #expect(AutomationText.presetApplied("办公", result) == "已把预设「办公」载入配置 1（放射 · 亮度 全亮）")
    }
}
