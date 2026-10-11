import XCTest

/// UI-50…UI-53：按键测试。模拟模式下 App 收到的按键会被转成模拟键盘的 HID 报文，走完整的采集链路。
@MainActor
final class KeyTestUITests: CherryUITestCase {
    private func openKeyTest(_ scenario: String = "pixiu75") {
        launch(scenario)
        openSection("按键测试")
        wait(for: "keytest.canvas")
    }

    /// UI-50 按下按键后键位图标记「已测」，统计与事件日志更新。
    func testTypingMarksKeysAndUpdatesStatistics() {
        openKeyTest()
        waitForText("keytest.state", contains: "正在监听")
        XCTAssertTrue(text("keytest.tested").hasPrefix("0 /"))
        XCTAssertEqual(text("key.64"), "A 未测")

        app.typeKey("a", modifierFlags: [])
        waitUntil("A 应标记为已测") { self.text("key.64").contains("已测") }
        app.typeKey("s", modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitForText("keytest.tested", contains: "4 /")
        waitForText("keytest.events", contains: "8")
        XCTAssertTrue(text("key.65").contains("已测"))
        XCTAssertTrue(text("key.108").contains("已测"))
        XCTAssertTrue(text("key.75").contains("已测"))
        XCTAssertTrue(app.staticTexts.matching(identifier: "keytest.log.label").firstMatch.exists)
        XCTAssertTrue(text("key.110").contains("不可测"), "Fn 由键盘内部处理")
    }

    /// UI-51 组合键：Shift + A 时同时按下数达到 2，修饰键也被记录。
    func testModifierChordCountsRollover() {
        openKeyTest()
        waitForText("keytest.state", contains: "正在监听")
        app.typeKey("a", modifierFlags: .shift)
        waitForText("keytest.max", contains: "2")
        XCTAssertTrue(text("key.84").contains("已测"), "左 Shift 应被记录")
        waitForText("keytest.pressed", contains: "0")
    }

    /// UI-52 重置清空已测键、计数和日志。
    func testResetClearsResults() {
        openKeyTest()
        waitForText("keytest.state", contains: "正在监听")
        app.typeKey("q", modifierFlags: [])
        waitForText("keytest.tested", contains: "1 /")
        element("keytest.reset").click()
        waitForText("keytest.tested", contains: "0 /")
        XCTAssertEqual(text("keytest.events"), "0")
        XCTAssertTrue(text("key.43").contains("未测"))
    }

    /// UI-53 未授权「输入监控」时显示授权提示，不开始监听。
    func testDeniedAccessShowsBannerAndDoesNotCapture() {
        openKeyTest("denied")
        wait(for: "keytest.access")
        wait(for: "keytest.requestAccess")
        wait(for: "keytest.openSettings")
        XCTAssertTrue(text("keytest.state").contains("未监听"))
        app.typeKey("a", modifierFlags: [])
        XCTAssertTrue(text("keytest.tested").hasPrefix("0 /"))
    }
}
