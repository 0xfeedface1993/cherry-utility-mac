import XCTest

/// UI-100…UI-102：设置窗口、实验性功能开关与应用更新菜单。模拟模式的偏好存放在独立的临时域，不影响正式 App。
@MainActor
final class SettingsUITests: CherryUITestCase {
    private func openSettings(tab: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let tabButton = app.toolbars.buttons[tab].firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5), "设置窗口没有标签「\(tab)」")
        tabButton.click()
        return app.windows.containing(.any, identifier: "settings.customFirmware").firstMatch
    }

    /// UI-100 开启「自定义固件」必须勾选风险确认；开启后侧栏出现该分区，关闭后再次隐藏。
    func testEnablingCustomFirmwareRequiresRiskConfirmation() {
        launch()
        wait(for: "info.model")
        XCTAssertFalse(element("section.自定义固件").exists, "默认不显示实验分区")

        _ = openSettings(tab: "实验性功能")
        let toggle = wait(for: "settings.customFirmware")
        toggle.click()
        let confirm = wait(for: "settings.customFirmware.confirm")
        XCTAssertFalse(confirm.isEnabled, "未勾选风险确认时不能开启")
        wait(for: "settings.customFirmware.acknowledge").click()
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        waitForDisappearance(confirm)

        wait(for: "section.自定义固件", in: window).click()
        wait(for: "custom.experimentalNotice")

        toggle.click()
        waitForDisappearance(element("section.自定义固件", in: window))
        wait(for: "info.model")
    }

    /// UI-101 取消风险确认不会开启实验分区。
    func testCancellingRiskConfirmationKeepsSectionHidden() {
        launch()
        wait(for: "info.model")
        _ = openSettings(tab: "实验性功能")
        wait(for: "settings.customFirmware").click()
        wait(for: "settings.customFirmware.cancel").click()
        waitForDisappearance(element("settings.customFirmware.confirm"))
        XCTAssertFalse(element("section.自定义固件", in: window).exists)
    }

    /// UI-102 模拟模式不启动 Sparkle：「检查更新…」不可用，更新页显示版本号。
    func testUpdaterIsInactiveInSimulation() {
        launch()
        wait(for: "info.model")
        let appMenu = app.menuBars.menuBarItems.element(boundBy: 1)
        appMenu.click()
        let item = app.menuBars.menuItems["检查更新…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        XCTAssertFalse(item.isEnabled, "模拟模式不应检查更新")
        app.typeKey(.escape, modifierFlags: [])

        _ = openSettings(tab: "更新")
        waitForText("settings.version", contains: "1.0.0")
        XCTAssertFalse(element("settings.checkNow").isEnabled)
    }
}
