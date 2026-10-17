import AppIntentsTesting
import XCTest

/// UI-120…UI-125：快捷指令 / Spotlight 意图。App 以模拟模式启动后，经系统的 App Intents 服务（AppIntentsTesting）
/// 执行意图，再从菜单栏和主窗口核对结果；不需要 Siri、真键盘或输入监控权限。
@available(macOS 27.0, *)
@MainActor
final class AppIntentsUITests: IntentsTestCase {
    /// UI-120 「切换配置档」意图切换后，菜单栏和主窗口无需刷新即同步。
    func testSwitchProfileIntentSyncsMenuBarAndMainWindow() async throws {
        start()
        openSection("灯光与配置档")
        wait(for: "profile.current.1")
        try await intent { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(1)) }
        wait(for: "profile.current.0")
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 1 · 放射")
    }

    /// UI-121 「设置灯效」按名字在目标型号的灯效表里解析：PIXIU 75 的呼吸是 2，PIXIU 98（B 型表）是 8。
    func testSetEffectIntentResolvesTheModelTable() async throws {
        start()
        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Breathing")) }
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 2 · 呼吸")
        XCTAssertTrue(text("menubar.effect.2").contains("已选中"))
        app.terminate()

        start("pixiu98")
        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Breathing")) }
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "呼吸")
        XCTAssertTrue(text("menubar.effect.8").contains("已选中"))
    }

    /// UI-122 「获取键盘状态」返回可在快捷指令里取用的各项。
    func testStatusIntentReturnsStructuredValues() async throws {
        start()
        let status = try await status()
        XCTAssertEqual(try status.batteryPercent as Int, 95)
        XCTAssertEqual(try status.isCharging as Bool, true)
        XCTAssertEqual(try status.activeProfile as Int, 2)
        XCTAssertEqual(try status.effect as String, "波纹")
        XCTAssertEqual(try status.brightness as Int, 4)
        XCTAssertEqual(try status.firmware as String, "0.1.1.7")
        let battery = try await intent { $0.intents["GetBatteryIntent"].makeIntent() }
        XCTAssertEqual(try battery.value as Int, 95)
    }

    /// UI-123 没有键盘时意图失败并给出中文说明。
    func testIntentsFailWithoutKeyboard() async throws {
        start("empty")
        await expectFailure(containing: "没有连接受支持的 CHERRY 键盘") { $0.intents["GetKeyboardStatusIntent"].makeIntent() }
    }

    /// UI-124 界面里保存的预设出现在意图的预设参数中，载入后主窗口同步。
    func testApplyPresetIntentUsesSavedPresets() async throws {
        start()
        openSection("灯光与配置档")
        wait(for: "preset.empty")
        element("config.effect.12").click()
        window.radioGroups["config.brightness"].radioButtons["高"].click()
        type("曲线高亮", into: element("preset.name"))
        element("preset.save").click()
        waitForText("banner.success", contains: "已保存预设「曲线高亮」")
        element("savebar.discard").click()

        let found = try await Intents.query { try await $0.entities["PresetEntity"].entities(matching: "曲线").first }
        let preset = try XCTUnwrap(found)
        try await intent { $0.intents["ApplyPresetIntent"].makeIntent(preset: preset, profile: $0.profile(3)) }
        waitForText("profile.summary.2", contains: "曲线 · 高")
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 2 · 波纹")
    }

    /// UI-125 两把键盘时必须指定键盘；指定后只改那一把。
    func testDualKeyboardsNeedTheKeyboardParameter() async throws {
        start("dual")
        await expectFailure(containing: "连接了多把键盘") { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(3)) }
        let keyboards = try await Intents.query { try await $0.entities["KeyboardEntity"].suggestedEntities().count }
        XCTAssertEqual(keyboards, 2)
        try await intent { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(3), keyboard: $0.keyboard(Self.second)) }
        let second = try await status(keyboard: Self.second)
        let first = try await status(keyboard: Self.pixiu75)
        XCTAssertEqual(try second.activeProfile as Int, 3)
        XCTAssertEqual(try first.activeProfile as Int, 2)
        XCTAssertEqual(try second.batteryPercent as Int, 53)
    }
}
