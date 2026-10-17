import AppIntentsTesting
import XCTest

/// UI-126、UI-127、UI-141、UI-143：写入类意图的字段、校验、与草稿共存、后台启动。
/// 对话框读不到，每次写入后用「获取键盘状态」回读，并核对菜单栏和主窗口。
@available(macOS 27.0, *)
@MainActor
final class AppIntentsWriteUITests: IntentsTestCase {
    /// UI-126 其余写入意图逐个执行：只改请求的字段，单位换算正确，菜单栏和主窗口同步。
    func testEachWriteIntentChangesOnlyItsField() async throws {
        start()
        openMenuBarPanel()

        try await intent { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("medium")) }
        var s = try await status()
        XCTAssertEqual(try s.brightness as Int, 2)
        XCTAssertEqual(try s.effect as String, "波纹")
        XCTAssertEqual(try s.color as String, "随机颜色")
        XCTAssertEqual(try s.activeProfile as Int, 2)
        waitForText("menubar.summary", contains: "配置 2 · 波纹 · 亮度 中")

        try await intent { $0.intents["SetLightingSpeedIntent"].makeIntent(speed: $0.speed(5)) }
        s = try await status()
        XCTAssertEqual(try s.speed as Int, 5)
        XCTAssertEqual(try s.brightness as Int, 2)

        try await intent { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("orange")) }
        s = try await status()
        XCTAssertEqual(try s.color as String, "#FF7200")
        waitForText("menubar.color.summary", contains: "固定颜色 #FF7200")

        try await intent { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("random")) }
        let value4 = try await status()
        XCTAssertEqual(try value4.color as String, "随机颜色")

        try await intent { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("custom"), hex: " #00d70f ") }
        let value5 = try await status()
        XCTAssertEqual(try value5.color as String, "#00D70F")

        try await intent { $0.intents["TurnOffBacklightIntent"].makeIntent() }
        s = try await status()
        XCTAssertEqual(try s.brightness as Int, 0)
        XCTAssertEqual(try s.speed as Int, 5)
        waitForText("menubar.summary", contains: "亮度 灭")

        try await intent { $0.intents["SetSleepTimersIntent"].makeIntent(sleepSeconds: 0, deepSleepMinutes: 20) }
        s = try await status()
        XCTAssertEqual(try s.sleepSeconds as Int, 0)
        XCTAssertEqual(try s.deepSleepMinutes as Int, 20)

        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Curve"), profile: $0.profile(3)) }
        s = try await status()
        XCTAssertEqual(try s.activeProfile as Int, 2, "指定配置档的写入不切换当前配置档")
        XCTAssertEqual(try s.effect as String, "波纹")
        closeMenuBarPanel()
        openSection("灯光与配置档")
        waitForText("profile.summary.2", contains: "曲线")
    }

    /// UI-127 校验失败不产生部分写入，错误是中文说明。
    func testValidationFailuresWriteNothing() async throws {
        start()
        let before = try await status()
        let baseline = [try before.brightness as Int, try before.speed as Int, try before.sleepSeconds as Int, try before.deepSleepMinutes as Int]
        let baselineColor = try before.color as String

        await expectFailure(containing: "休眠时间须为 0（不休眠）或 30–300 秒，收到 10") {
            $0.intents["SetSleepTimersIntent"].makeIntent(sleepSeconds: 10, deepSleepMinutes: 20)
        }
        await expectFailure(containing: "深度休眠须为 0（不休眠）或 15–300 分钟，收到 10") {
            $0.intents["SetSleepTimersIntent"].makeIntent(deepSleepMinutes: 10)
        }
        await expectFailure(containing: "没有需要修改的设置") { $0.intents["SetSleepTimersIntent"].makeIntent() }
        // 超出参数声明的 0–300 范围时，系统改为向用户要值（与缺 hex 相同），不调用意图。
        await expectFailure(containing: "parameter 'sleepSeconds'") { $0.intents["SetSleepTimersIntent"].makeIntent(sleepSeconds: 301) }
        for hex in ["#GG0000", "#FF72", "+FF720", "random"] {
            await expectFailure(containing: "格式不对，请用 #RRGGBB") {
                $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("custom"), hex: hex)
            }
        }
        // 缺 hex 时意图向用户要值（快捷指令里弹出输入框），测试的自动确认代理不支持，以参数 hex 的错误结束。
        await expectFailure(containing: "parameter 'hex'", within: 10) { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("custom")) }
        await expectFailure(containing: "没有「彩虹雨」灯效，可选：波纹、光谱") {
            $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Rainbow Rain"))
        }

        let after = try await status()
        XCTAssertEqual([try after.brightness as Int, try after.speed as Int, try after.sleepSeconds as Int, try after.deepSleepMinutes as Int], baseline)
        XCTAssertEqual(try after.color as String, baselineColor)
    }

    /// UI-141 主窗口有未写入的草稿时执行意图：草稿保留；保存草稿后不会抹掉意图写入的灯效。
    func testUnsavedDraftSurvivesAnIntentWrite() async throws {
        start()
        openSection("灯光与配置档")
        wait(for: "profile.current.1")
        window.radioGroups["config.brightness"].radioButtons["低"].click()
        waitForText("savebar.status", contains: "1 项修改尚未写入键盘")

        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Curve")) }
        waitUntil("灯效同步为曲线") { self.text("config.effect.12").contains("已选中") }
        waitForText("savebar.status", contains: "1 项修改尚未写入键盘")

        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 2")
        let s = try await status()
        XCTAssertEqual(try s.effect as String, "曲线")
        XCTAssertEqual(try s.brightness as Int, 1)
    }

    /// UI-143 以 --background 启动（命令行拉起 App 的方式）：不显示主窗口，意图照常执行。
    func testBackgroundLaunchRunsIntentsWithoutAWindow() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CHERRY_SIMULATION"] = "pixiu75"
        app.launchEnvironment["CHERRY_PRESET_DIR"] = NSTemporaryDirectory() + "cherry-presets-\(UUID().uuidString)"
        app.launchArguments = ["--background"]
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.statusItems["menubar.label"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows["main"].waitForExistence(timeout: 2), "后台启动不应显示主窗口")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Intents.bundleIdentifier)
        XCTAssertEqual(running.count, 1)
        try await Intents.run { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(1)) }
        let status: AnyTransientAppEntity = try await Intents.run { $0.intents["GetKeyboardStatusIntent"].makeIntent() }.value
        XCTAssertEqual(try status.activeProfile as Int, 1)
        XCTAssertFalse(app.windows["main"].exists)
    }
}
