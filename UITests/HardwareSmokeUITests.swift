import XCTest

/// UI-90：真机冒烟（只读）。需要连接 PIXIU 75 并已授予本应用「输入监控」权限；
/// 以 `TEST_RUNNER_CHERRY_UITEST_HARDWARE=1 xcodebuild test …` 运行，默认跳过。
@MainActor
final class HardwareSmokeUITests: CherryUITestCase {
    func testRealKeyboardIsReadable() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHERRY_UITEST_HARDWARE"] == "1", "未开启真机测试")
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
        waitForText("info.activeProfile", contains: "共 3 个", timeout: 15)
        XCTAssertFalse(text("info.battery").isEmpty)

        openSection("灯效与配置")
        for n in 0..<3 { wait(for: "profile.summary.\(n)", timeout: 15) }
        XCTAssertFalse(element("savebar.status").exists, "只读检查不应产生修改")

        openMenuBarPanel()
        waitForText("menubar.device", contains: "PIXIU 75", timeout: 15)
        waitForText("menubar.summary", contains: "配置", timeout: 15)
    }
}
