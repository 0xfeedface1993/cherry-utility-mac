import XCTest

/// UI-100…UI-104：设置窗口、实验性功能开关与应用更新入口。模拟模式的偏好存放在独立的临时域，不影响正式 App。
/// UI-103、UI-104 用 `CHERRY_ENABLE_UPDATER=1` 在模拟模式里启动真实的 Sparkle，`CHERRY_UPDATE_FEED` 指向本用例写入的
/// 本地 appcast（Debug 构建才认这个变量；Sparkle 只接受 http(s)，所以由用例在 127.0.0.1 上提供），只检查、不下载也不安装；Sparkle 写入的 `SU*` 偏好在 App 退出时还原。
@MainActor
final class SettingsUITests: CherryUITestCase {
    private func openSettings(tab: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let tabButton = app.toolbars.buttons[tab].firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5), "设置窗口没有标签「\(tab)」")
        tabButton.click()
        return app.windows["com_apple_SwiftUI_Settings_window"]
    }

    /// UI-100 开启「自定义固件」必须勾选风险确认；开启后侧栏出现该分区，关闭后再次隐藏。
    func testEnablingCustomFirmwareRequiresRiskConfirmation() {
        launch()
        wait(for: "info.model")
        XCTAssertFalse(element("section.自定义固件").exists, "默认不显示实验分区")

        _ = openSettings(tab: "实验性功能")
        let toggle = app.switches["settings.customFirmware"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        let confirm = wait(for: "settings.customFirmware.confirm")
        XCTAssertFalse(confirm.isEnabled, "未勾选风险确认时不能开启")
        wait(for: "settings.customFirmware.acknowledge").click()
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        waitForDisappearance(confirm)

        wait(for: "section.自定义固件", in: window).click()
        wait(for: "custom.experimentalNotice")

        // 点侧栏后主窗口在前，设置窗口被挡住；⌘, 把它带回前台（仍停在「实验性功能」）。
        _ = openSettings(tab: "实验性功能")
        toggle.click()
        waitForDisappearance(element("section.自定义固件", in: window))
        wait(for: "info.model")
    }

    /// UI-101 取消风险确认不会开启实验分区。
    func testCancellingRiskConfirmationKeepsSectionHidden() {
        launch()
        wait(for: "info.model")
        _ = openSettings(tab: "实验性功能")
        app.switches["settings.customFirmware"].click()
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

    // MARK: 应用内更新（真实 Sparkle + 本地 appcast）

    /// Writes an appcast offering `build` / `version` and launches the app with Sparkle pointed at it.
    private func launchWithLocalFeed(offering version: String, build: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-update-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let server = try LocalHTTPServer(serving: directory)
        let base = try server.start()
        addTeardownBlock { server.stop() }
        // The enclosure is never fetched: the tests stop at Sparkle's first prompt.
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>CHERRY Utility</title>
            <item>
              <title>\(version)</title>
              <sparkle:version>\(build)</sparkle:version>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
              <description><![CDATA[<meta charset="utf-8"><h3>\(version)</h3><ul><li>UI 测试用的本地更新说明。</li></ul>]]></description>
              <enclosure url="\(base.absoluteString)CherryUtility-\(version).dmg" length="1" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
            </item>
          </channel>
        </rss>
        """
        try xml.write(to: directory.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)
        launch(environment: ["CHERRY_ENABLE_UPDATER": "1", "CHERRY_UPDATE_FEED": base.absoluteString + "appcast.xml"])
        // Quit with ⌘Q before the base class terminates the app (teardown blocks run last-in, first-out): only a normal
        // quit lets the app restore the Sparkle preferences it shares with the real CHERRY Utility.
        addTeardownBlock { @MainActor [app] in
            guard let app, app.state != .notRunning else { return }
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App 没有正常退出，Sparkle 偏好可能未还原")
        }
        wait(for: "info.model")
    }

    /// First button with one of `titles` in any window, sheet or alert of the app (Sparkle's UI follows the system language).
    private func sparkleButton(_ titles: [String], timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for title in titles {
                let button = app.descendants(matching: .button).matching(identifier: title).firstMatch
                if button.exists { return button }
                let labelled = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
                if labelled.exists { return labelled }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        attachAccessibilityTree()
        XCTFail("Sparkle 没有出现按钮 \(titles)", file: file, line: line)
        return app.buttons[titles[0]]
    }

    private func checkForUpdatesMenuItem() -> XCUIElement {
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        let item = app.menuBars.menuItems["检查更新…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        return item
    }

    /// UI-103 已是最新：App 菜单「检查更新…」与设置 › 更新「立即检查」都完成一次真实检查；自动检查 / 自动下载开关联动。
    func testCheckForUpdatesReportsUpToDate() throws {
        try launchWithLocalFeed(offering: "1.0.0", build: 1)

        let item = checkForUpdatesMenuItem()
        waitUntil("「检查更新…」应可用") { item.isEnabled }
        item.click()
        let ok = sparkleButton(["好", "OK"])
        waitForAppText("最新", "up to date")
        ok.click()
        waitForDisappearance(ok)

        _ = openSettings(tab: "更新")
        waitForText("settings.version", contains: "1.0.0 (1)")
        let checkNow = wait(for: "settings.checkNow")
        waitUntil("「立即检查」应可用") { checkNow.isEnabled }
        checkNow.click()
        let again = sparkleButton(["好", "OK"])
        again.click()
        waitForDisappearance(again)
        waitForAppText("上次检查")

        let autoCheck = wait(for: "settings.autoCheck")
        let autoDownload = wait(for: "settings.autoDownload")
        XCTAssertEqual(autoCheck.value as? Int, 1, "Info.plist 默认开启自动检查")
        XCTAssertTrue(autoDownload.isEnabled)
        autoCheck.click()
        waitUntil("关闭自动检查后「自动下载并安装」应不可用") { !autoDownload.isEnabled }
        XCTAssertEqual(autoDownload.value as? Int, 0)
        autoCheck.click()
        waitUntil("重新开启自动检查后「自动下载并安装」应可用") { autoDownload.isEnabled }
        autoDownload.click()
        waitUntil("自动下载应开启") { autoDownload.value as? Int == 1 }
        autoDownload.click()
        waitUntil("自动下载应关闭") { autoDownload.value as? Int == 0 }
    }

    /// UI-104 有新版本：「立即检查」弹出 Sparkle 更新窗口，显示新版本与更新说明；选「稍后提醒我」后关闭，不下载、不安装。
    func testCheckForUpdatesOffersNewerVersion() throws {
        try launchWithLocalFeed(offering: "1.0.1", build: 2)
        _ = openSettings(tab: "更新")
        let checkNow = wait(for: "settings.checkNow")
        waitUntil("「立即检查」应可用") { checkNow.isEnabled }
        checkNow.click()

        let later = sparkleButton(["稍后提醒我", "Remind Me Later"])
        XCTAssertTrue(sparkleButton(["安装更新", "Install Update"]).exists)
        waitForAppText("1.0.1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "sparkle-update-available"; screenshot.lifetime = .keepAlways; add(screenshot)
        later.click()
        waitForDisappearance(later)

        // 关闭提示后菜单项恢复可用，App 仍是 1.0.0 (1)。
        let item = checkForUpdatesMenuItem()
        waitUntil("「检查更新…」应恢复可用") { item.isEnabled }
        app.typeKey(.escape, modifierFlags: [])
        waitForText("settings.version", contains: "1.0.0 (1)")
    }

    /// Any of `fragments` anywhere in the app (Sparkle's windows are outside the main window; its UI may be Chinese or English).
    private func waitForAppText(_ fragments: String..., file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: fragments.map {
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", $0, $0)
        })
        if !app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: 8) {
            attachAccessibilityTree()
            XCTFail("界面上没有 \(fragments)", file: file, line: line)
        }
    }
}
