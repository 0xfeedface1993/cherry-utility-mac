import AppKit
import XCTest

/// Base class of the UI tests. Every test launches the app against the in-memory simulated PIXIU 75
/// (`CHERRY_SIMULATION`), so the full UI → TCA → core → protocol stack runs without hardware, Input Monitoring
/// or network. Each launch gets its own preset directory.
@MainActor
class CherryUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    /// Scenarios understood by the app: `pixiu75`, `empty`, `unsupported`, `denied`, `wireless`.
    /// `nil` launches against real hardware. `experimental` lists hidden features to turn on (`customFirmware`);
    /// in simulation they live in a throwaway preferences suite, so the real app's settings are untouched.
    /// `environment` adds launch variables (e.g. the local update feed of `SettingsUITests`).
    /// `arguments` are passed to the app; without `expectsMainWindow` (e.g. `--background`) the launch does not wait
    /// for the main window.
    @discardableResult
    func launch(
        _ scenario: String? = "pixiu75", experimental: [String] = [], environment extra: [String: String] = [:],
        arguments: [String] = [], expectsMainWindow: Bool = true
    ) -> XCUIApplication {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = environment["CHERRY_PROFILE_APP"].map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        if let scenario {
            app.launchEnvironment["CHERRY_SIMULATION"] = scenario
            app.launchEnvironment["CHERRY_PRESET_DIR"] = "/tmp/cherry-uitest-\(UUID().uuidString)"
            app.launchEnvironment["CHERRY_EXPERIMENTAL"] = experimental.joined(separator: ",")
        }
        app.launchEnvironment.merge(extra) { _, new in new }
        app.launchArguments = arguments
        if let output = environment["CHERRY_PROFILE_OUTPUT"] {
            app.launchEnvironment["CHERRY_DIAGNOSTIC_MODE"] = "profile"
            app.launchEnvironment["CHERRY_DIAGNOSTIC_DIR"] = output + "/journal"
        }
        app.launch()
        self.app = app
        addTeardownBlock { @MainActor in app.terminate() }
        if expectsMainWindow {
            XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 15), "主窗口没有出现")
        }
        return app
    }

    /// 相当于点程序坞图标：经 LaunchServices 再「打开」一次正在运行的 App，系统给它发 reopen 事件（与程序坞、
    /// `open -a` 相同）。万一 App 已经退出，这次打开会启动新实例，所以带上本次启动的环境变量（模拟场景），
    /// 绝不会以真机模式启动。
    func reopenLikeTheDock(file: StaticString = #filePath, line: UInt = #line) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "online.odeployer.CherryUtility")
            .filter { !$0.isTerminated }
        guard app.launchEnvironment["CHERRY_SIMULATION"] != nil, running.count == 1, let url = running[0].bundleURL else {
            return XCTFail("应当只有本用例启动的一个模拟实例在运行，实际 \(running.count) 个", file: file, line: line)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = app.launchEnvironment
        let opened = expectation(description: "reopen")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { XCTFail("打开 App 失败：\(error)") }
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
    }

    var window: XCUIElement { app.windows["main"] }

    /// First element of any type with this accessibility identifier.
    func element(_ id: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? app).descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Label and value together, so assertions work for static texts, combined rows and controls alike.
    /// Empty while the element does not exist, so `waitForText` keeps waiting instead of failing on the lookup.
    func text(of e: XCUIElement) -> String {
        guard e.exists else { return "" }
        let value = e.value.map { "\($0)" } ?? ""
        return [e.label, value].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Scrolls the main window's content until `e` can be clicked (macOS UI tests do not auto-scroll). With unsaved
    /// edits the configuration page's floating save bar covers the bottom of the scroll area; a click there lands on
    /// the bar (the preset name field then never gets focus), so `e` must also sit above it.
    func reveal(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // The detail content is the widest scroll view (the first one is the sidebar).
        guard let scroll = window.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.width < $1.frame.width }) else {
            return XCTFail("窗口里没有滚动视图", file: file, line: line)
        }
        let saveBar = element("savebar.status", in: window)
        func clear() -> Bool {
            e.isHittable && (!saveBar.exists || e.frame.maxY < saveBar.frame.minY - 16)
        }
        // The sign of deltaY that moves content up differs between input devices; try both directions.
        for delta in [-150.0, 150.0] {
            for _ in 0..<12 where !clear() {
                scroll.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
        XCTAssertTrue(clear(), "无法滚动到 \(e)", file: file, line: line)
    }

    func text(_ id: String) -> String { text(of: element(id)) }

    /// Element whose label or value contains `fragment`, below `root` (the main window by default).
    func anything(containing fragment: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? window).descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    func waitUntil(
        _ description: @autoclosure () -> String, timeout: TimeInterval = 8,
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        attachAccessibilityTree()
        XCTFail("超时：\(description())", file: file, line: line)
    }

    /// Keeps the accessibility tree in the result bundle, for diagnosing a failed lookup.
    func attachAccessibilityTree(_ name: String = "accessibility-tree") {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func waitForAnything(containing fragment: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        if !anything(containing: fragment).waitForExistence(timeout: timeout) {
            attachAccessibilityTree()
            XCTFail("界面上没有包含「\(fragment)」的元素", file: file, line: line)
        }
    }

    @discardableResult
    func wait(for id: String, in root: XCUIElement? = nil, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(id, in: root)
        if !e.waitForExistence(timeout: timeout) {
            attachAccessibilityTree()
            XCTFail("没有找到 \(id)", file: file, line: line)
        }
        return e
    }

    func waitForText(_ id: String, contains fragment: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(id) 应包含「\(fragment)」，实际「\(text(id))」", timeout: timeout, file: file, line: line) {
            text(id).contains(fragment)
        }
    }

    func waitForDisappearance(_ e: XCUIElement, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("元素应消失：\(e)", timeout: timeout, file: file, line: line) { !e.exists }
    }

    // MARK: Navigation

    /// Selects a section in the sidebar (`概览`, `灯光与配置档`, `按键测试`, `固件升级`, `自定义固件`).
    func openSection(_ title: String) {
        let item = element("section.\(title)", in: window)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "侧栏没有分区 \(title)")
        item.click()
    }

    /// Buttons of a sheet / alert attached to the main window (SwiftUI alerts are sheets on macOS).
    func alertButton(_ title: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let candidates = [app.sheets.buttons[title], app.dialogs.buttons[title], app.alerts.buttons[title]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = candidates.first(where: { $0.exists }) { return hit }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("没有出现按钮「\(title)」的对话框", file: file, line: line)
        return candidates[0]
    }

    /// Types `string` into a text field and checks what arrived. XCUITest enters non-ASCII text through Unicode Hex Input,
    /// whose keystrokes occasionally interleave under load (出 U+51FA arrived as U+551F), so a mismatch is cleared and retyped.
    func type(_ string: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(field, file: file, line: line)
        for _ in 0..<3 {
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
            field.typeText(string)
            if field.value as? String == string { return }
        }
        attachAccessibilityTree()
        XCTFail("输入框内容应为「\(string)」，实际「\(field.value ?? "")」", file: file, line: line)
    }

    /// Opens the pull-down menu `id` and picks `item`. A borderless SwiftUI `Menu` occasionally ignores a click that
    /// arrives while its row is still being laid out (seen right after saving a preset), so the click is retried.
    /// The menu bar's own items with the same title (the system Edit menu has 「删除」) are never hittable while closed,
    /// so the entry is the hittable match.
    func choose(_ item: String, fromMenu id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = element(id)
        let entries = app.menuItems.matching(NSPredicate(format: "title == %@", item))
        for _ in 0..<3 {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "没有菜单按钮 \(id)", file: file, line: line)
            button.click()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let entry = entries.allElementsBoundByIndex.first(where: { $0.isHittable }) { return entry.click() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if app.menus.firstMatch.exists { app.typeKey(.escape, modifierFlags: []) }
        }
        attachAccessibilityTree()
        XCTFail("菜单 \(id) 没有出现「\(item)」", file: file, line: line)
    }

    func choose(menu: String, item: String) {
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "没有菜单 \(menu)")
        bar.click()
        app.menuBars.menuItems[item].click()
    }

    /// ⌘, 打开设置并切到标签 `tab`（「通用」「更新」「自动化」「实验性功能」），返回设置窗口。
    @discardableResult
    func openSettings(tab: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let tabButton = app.toolbars.buttons[tab].firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5), "设置窗口没有标签「\(tab)」", file: file, line: line)
        tabButton.click()
        return app.windows["com_apple_SwiftUI_Settings_window"]
    }

    /// 开关当前是否打开（macOS 的 switch 值为 0 / 1）。
    func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int) == 1 || (toggle.value as? String) == "1" || (toggle.value as? Bool) == true
    }

    // MARK: Menu bar

    var statusItem: XCUIElement { app.statusItems["menubar.label"] }

    /// Clicks the status item and returns the panel.
    @discardableResult
    func openMenuBarPanel(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(statusItem.waitForExistence(timeout: 8), "菜单栏图标不存在", file: file, line: line)
        let panel = element("menubar.panel")
        if !panel.exists { statusItem.click() }
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "菜单栏面板没有打开", file: file, line: line)
        return panel
    }

    func closeMenuBarPanel() {
        let panel = element("menubar.panel")
        guard panel.exists else { return }
        statusItem.click()
        waitForDisappearance(panel, timeout: 3)
    }
}
