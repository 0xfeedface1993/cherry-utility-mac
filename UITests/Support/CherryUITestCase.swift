import XCTest

/// Base class of the UI tests. Every test launches the app against the in-memory simulated PIXIU 75
/// (`CHERRY_SIMULATION`), so the full UI → TCA → core → protocol stack runs without hardware, Input Monitoring
/// or network. Each launch gets its own preset directory.
@MainActor
class CherryUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    /// Scenarios understood by the app: `pixiu75`, `empty`, `unsupported`, `denied`, `wireless`.
    /// `nil` launches against real hardware.
    @discardableResult
    func launch(_ scenario: String? = "pixiu75") -> XCUIApplication {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = environment["CHERRY_PROFILE_APP"].map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        if let scenario {
            app.launchEnvironment["CHERRY_SIMULATION"] = scenario
            app.launchEnvironment["CHERRY_PRESET_DIR"] = "/tmp/cherry-uitest-\(UUID().uuidString)"
        }
        if let output = environment["CHERRY_PROFILE_OUTPUT"] {
            app.launchEnvironment["CHERRY_DIAGNOSTIC_MODE"] = "profile"
            app.launchEnvironment["CHERRY_DIAGNOSTIC_DIR"] = output + "/journal"
        }
        app.launch()
        self.app = app
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 15), "主窗口没有出现")
        return app
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

    /// Scrolls the main window's content until `e` can be clicked (macOS UI tests do not auto-scroll).
    func reveal(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // The detail content is the widest scroll view (the first one is the sidebar).
        guard let scroll = window.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.width < $1.frame.width }) else {
            return XCTFail("窗口里没有滚动视图", file: file, line: line)
        }
        // The sign of deltaY that moves content up differs between input devices; try both directions.
        for delta in [-150.0, 150.0] {
            for _ in 0..<12 where !e.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
        XCTAssertTrue(e.isHittable, "无法滚动到 \(e)", file: file, line: line)
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

    func openSection(_ title: String) {
        let button = window.radioGroups["section.picker"].radioButtons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "没有分区 \(title)")
        button.click()
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
    func choose(_ item: String, fromMenu id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = element(id), entry = app.menuItems[item]
        for _ in 0..<3 {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "没有菜单按钮 \(id)", file: file, line: line)
            button.click()
            if entry.waitForExistence(timeout: 2) { return entry.click() }
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
