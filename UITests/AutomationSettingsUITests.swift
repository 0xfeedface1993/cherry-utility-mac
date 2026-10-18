import AppKit
import XCTest

/// UI-150…UI-153：「设置 › 自动化」。App 以模拟模式加独立的数据目录启动：socket、cherry 的安装目录与 Claude 配置都在
/// 这个 /tmp 目录里（由 App 创建；runner 在沙盒里，只把路径字符串传过去），不碰正式 App 的 socket、/usr/local/bin 或真实配置。
@MainActor
final class AutomationSettingsUITests: CherryUITestCase {
    private var dataDirectory = ""

    private func launchWithDataDirectory() {
        dataDirectory = "/tmp/cherry-uitest-\(UUID().uuidString.prefix(12))"
        launch("pixiu75", environment: ["CHERRY_DATA_DIR": dataDirectory])
        openSettings(tab: "自动化")
    }

    /// UI-150 两个开关默认打开；显示监听的 socket、cherry 未安装、Claude 客户端未找到；有「打开快捷指令」。
    func testAutomationTabShowsSwitchesAndStatus() {
        launchWithDataDirectory()
        let commandLine = app.switches["settings.automation.commandLine"]
        let mcp = app.switches["settings.automation.mcp"]
        XCTAssertTrue(commandLine.waitForExistence(timeout: 5) && mcp.exists)
        XCTAssertTrue(isOn(commandLine) && isOn(mcp), "两个开关默认打开")
        waitForText("settings.automation.endpoint", contains: "正在监听 \(dataDirectory)/control.sock")
        waitForText("settings.automation.commandLine.tool", contains: "未安装")
        waitForText("settings.automation.commandLine.activity", contains: "还没有调用")
        waitForText("settings.automation.claudeDesktop", contains: "没有找到 Claude Desktop")
        waitForText("settings.automation.claudeCode", contains: "没有找到 Claude Code")
        XCTAssertFalse(element("settings.automation.claudeDesktop.add").isEnabled, "没有 Claude Desktop 时不能添加")
        XCTAssertFalse(element("settings.automation.commandLine.uninstall").isEnabled)
        XCTAssertTrue(element("settings.automation.openShortcuts").exists)
    }

    /// UI-151 安装 cherry（模拟模式装进数据目录的 bin，不弹管理员授权），再移除。
    func testInstallingTheCommandLineTool() {
        launchWithDataDirectory()
        let install = wait(for: "settings.automation.commandLine.install")
        XCTAssertTrue(install.isEnabled)
        install.click()
        waitForText("settings.automation.notice", contains: "已安装 cherry 命令")
        waitForText("settings.automation.commandLine.tool", contains: "已安装：\(dataDirectory)/bin/cherry（链接到本 App 自带的 cherry）")
        XCTAssertFalse(install.isEnabled)
        let uninstall = element("settings.automation.commandLine.uninstall")
        XCTAssertTrue(uninstall.isEnabled)
        uninstall.click()
        waitForText("settings.automation.notice", contains: "已移除 cherry 命令的链接")
        waitForText("settings.automation.commandLine.tool", contains: "未安装")
    }

    /// UI-152 复制 Claude Code 的注册命令与通用 JSON 配置；结束后还原剪贴板。
    func testCopyingTheRegistrationCommands() throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        addTeardownBlock { @MainActor in
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        launchWithDataDirectory()
        wait(for: "settings.automation.claudeCode.copy").click()
        waitForText("settings.automation.notice", contains: "已复制注册命令")
        let command = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(command.hasPrefix(#"claude mcp add --scope user cherry -- ""#) && command.hasSuffix(#"/Contents/MacOS/cherry" mcp"#), command)

        element("settings.automation.mcp.copyJSON").click()
        waitForText("settings.automation.notice", contains: "已复制JSON 配置")
        let json = try XCTUnwrap(pasteboard.string(forType: .string)?.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let cherry = try XCTUnwrap((object["mcpServers"] as? [String: Any])?["cherry"] as? [String: Any])
        XCTAssertEqual(cherry["args"] as? [String], ["mcp"])
        XCTAssertTrue((cherry["command"] as? String)?.hasSuffix("/Contents/MacOS/cherry") == true)
    }

    /// UI-153 关掉 MCP 后重新打开设置窗口仍是关的；再打开恢复。
    func testSwitchesPersist() {
        launchWithDataDirectory()
        let mcp = app.switches["settings.automation.mcp"]
        XCTAssertTrue(mcp.waitForExistence(timeout: 5))
        mcp.click()
        waitUntil("MCP 开关关闭") { !self.isOn(mcp) }
        app.windows["com_apple_SwiftUI_Settings_window"].buttons[XCUIIdentifierCloseWindow].click()
        openSettings(tab: "自动化")
        let reopened = app.switches["settings.automation.mcp"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertFalse(isOn(reopened), "关闭状态应保留")
        XCTAssertTrue(isOn(app.switches["settings.automation.commandLine"]))
        reopened.click()
        waitUntil("MCP 开关打开") { self.isOn(reopened) }
    }
}
