import XCTest

/// UI-01…UI-08：启动、导航、空设备 / 未适配型号、窗口与菜单栏的生命周期、App 菜单的名称、点程序坞图标重新打开主窗口。
@MainActor
final class LaunchAndNavigationUITests: CherryUITestCase {
    /// UI-01 启动后侧栏顶部的设备卡片显示模拟键盘并自动选中，默认显示概览，窗口标题为当前分区。
    func testLaunchListsAndSelectsKeyboard() {
        launch()
        let card = wait(for: "sidebar.keyboard")
        XCTAssertTrue(text(of: card).contains("CHERRY MX PIXIU 75"))
        XCTAssertTrue(text(of: card).contains("固件 0.1.1.7"))
        wait(for: "info.model")
        XCTAssertTrue(window.title.contains("概览"), "窗口标题应为当前分区，实际「\(window.title)」")
        XCTAssertFalse(element("section.自定义固件").exists, "自定义固件默认隐藏")
    }

    /// UI-02 侧栏可在四个功能区之间切换，每个区显示自己的内容。
    func testSectionPickerNavigatesAllSections() {
        launch()
        wait(for: "info.model")
        openSection("灯光与配置档")
        wait(for: "profile.card.0")
        openSection("按键测试")
        wait(for: "keytest.canvas")
        openSection("固件升级")
        wait(for: "firmware.current")
        openSection("概览")
        wait(for: "info.model")
    }

    /// UI-03 没有键盘时侧边栏和菜单栏都显示空状态。
    func testEmptyScenarioShowsNoDevice() {
        launch("empty")
        wait(for: "sidebar.empty")
        XCTAssertFalse(element("sidebar.keyboard").exists)
        openMenuBarPanel()
        wait(for: "menubar.empty")
    }

    /// UI-04 未适配的 CHERRY 型号只展示 USB 信息，不读取私有协议。
    func testUnsupportedModelShowsUSBInformationOnly() {
        launch("unsupported")
        waitForText("info.model", contains: "未适配型号")
        XCTAssertTrue(text("info.vidpid").contains("0x046A / 0x0999"))
        XCTAssertFalse(element("info.battery").exists)
        openSection("灯光与配置档")
        wait(for: "config.failed")
        openMenuBarPanel()
        wait(for: "menubar.unsupported")
    }

    /// UI-05 关闭主窗口后应用仍驻留菜单栏，并可从面板重新打开主窗口。
    func testClosingWindowKeepsStatusItemAndPanelReopensWindow() {
        launch()
        wait(for: "info.model")
        window.buttons["_XCUI:CloseWindow"].click()
        waitForDisappearance(window)
        XCTAssertTrue(statusItem.exists, "关闭窗口后菜单栏图标应仍在")
        openMenuBarPanel()
        element("menubar.openMain").click()
        XCTAssertTrue(window.waitForExistence(timeout: 5), "面板应能重新打开主窗口")
        wait(for: "info.model")
    }

    /// UI-06 屏幕顶部菜单栏的 App 菜单与「关于」「退出」菜单项用本地化名称「CHERRY Utility」
    /// （zh-Hans.lproj/InfoPlist.strings 的 CFBundleName；包的文件名和可执行文件名仍是 CherryUtility）。
    func testAppMenuUsesTheLocalizedName() {
        launch()
        wait(for: "info.model")
        let appMenu = app.menuBars.menuBarItems["CHERRY Utility"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5),
                      "App 菜单应为「CHERRY Utility」，实际 \(app.menuBars.menuBarItems.allElementsBoundByIndex.map(\.title))")
        appMenu.click()
        // 只看 App 菜单自己的项：苹果菜单的「最近使用的项目」里是系统记下的条目，可能还是旧构建的文件名。
        let items = appMenu.menuItems
        let named = items.matching(NSPredicate(format: "title CONTAINS %@", "CHERRY Utility"))
        XCTAssertTrue(named.matching(NSPredicate(format: "title BEGINSWITH %@", "关于")).firstMatch.waitForExistence(timeout: 5),
                      "没有「关于 CHERRY Utility」")
        XCTAssertTrue(named.matching(NSPredicate(format: "title BEGINSWITH %@", "退出")).firstMatch.exists, "没有「退出 CHERRY Utility」")
        let fileNamed = items.matching(NSPredicate(format: "title CONTAINS %@", "CherryUtility"))
        XCTAssertFalse(fileNamed.firstMatch.exists,
                       "菜单项里不应出现文件名 CherryUtility：\(fileNamed.allElementsBoundByIndex.map(\.title))")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// UI-07 关闭所有窗口后点程序坞图标（reopen 事件），重新打开主窗口；菜单栏图标一直在。
    func testDockReopensTheMainWindowAfterAllWindowsClosed() {
        launch()
        wait(for: "info.model")
        window.buttons["_XCUI:CloseWindow"].click()
        waitForDisappearance(window)
        XCTAssertTrue(statusItem.exists, "关闭窗口后菜单栏图标应仍在")
        reopenLikeTheDock()
        XCTAssertTrue(window.waitForExistence(timeout: 5), "点程序坞图标应重新打开主窗口")
        wait(for: "info.model")
    }

    /// UI-08 启动时没有打开主窗口（`--background`，与关掉「启动时显示主窗口」一样）：点程序坞图标打开主窗口；
    /// 再关掉所有窗口后点程序坞图标，又能打开。
    func testDockOpensTheMainWindowAfterABackgroundLaunch() {
        launch(arguments: ["--background"], expectsMainWindow: false)
        XCTAssertTrue(statusItem.waitForExistence(timeout: 15), "菜单栏图标没有出现")
        XCTAssertFalse(window.exists, "后台启动不应打开主窗口")
        reopenLikeTheDock()
        XCTAssertTrue(window.waitForExistence(timeout: 5), "点程序坞图标应打开主窗口")
        wait(for: "info.model")
        window.buttons["_XCUI:CloseWindow"].click()
        waitForDisappearance(window)
        reopenLikeTheDock()
        XCTAssertTrue(window.waitForExistence(timeout: 5), "关闭后再点程序坞图标应重新打开主窗口")
    }
}
