import XCTest

/// XF-02、XF-04 至 XF-07：菜单栏、设置与命令行 / MCP 共用写入队列、变更流、开关和调用记录。由 `Scripts/verify-cross.sh` 驱动：
/// 脚本经 `TEST_RUNNER_CHERRY_E2E_SOCKET` 传入 socket 路径，在 shell 一侧运行 cherry、cherry mcp 和 watch。
/// runner 在沙盒里，不碰 socket 也不共享文件，双方只靠键盘状态握手。没有这个变量时跳过。
@MainActor
final class CrossEntryUITests: CherryUITestCase {
    /// 脚本给的数据目录（`TEST_RUNNER_CHERRY_E2E_DATA_DIR`）：App 在这里监听 socket、存模拟键盘的共享状态，cherry 直连时用同一个。
    private func dataDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["CHERRY_E2E_DATA_DIR"], !directory.isEmpty else {
            throw XCTSkip("只由 Scripts/verify-cross.sh 运行")
        }
        return directory
    }

    private func socket() throws -> String {
        guard let socket = ProcessInfo.processInfo.environment["CHERRY_E2E_SOCKET"], !socket.isEmpty else {
            throw XCTSkip("只由 Scripts/verify-cross.sh 运行")
        }
        return socket
    }

    /// XF-02 菜单栏的写入经 socket 可读；MCP 的写入实时更新面板和主窗口；面板上的「退出」正常退出。
    /// 脚本：开 watch → `cherry set --brightness 2`（信号）→ 等状态里出现光谱 → MCP 写呼吸、亮度 1 → 等 watch 以 3 结束。
    func testMenuBarAndMCPShareTheQueueAndFeed() throws {
        launch("pixiu75", environment: ["CHERRY_CONTROL_SOCKET": try socket()])
        let panel = openMenuBarPanel()
        // 脚本的 watch 已在运行；命令行的写入实时到达打开着的面板。
        waitForText("menubar.summary", contains: "配置 2 · 波纹 · 亮度 中", timeout: 90)
        element("menubar.effect.1").click()
        waitForText("menubar.summary", contains: "光谱")
        waitForText("menubar.summary", contains: "呼吸 · 亮度 低", timeout: 60)
        XCTAssertTrue(panel.exists, "面板全程保持打开")
        closeMenuBarPanel()
        openSection("灯光与配置档")
        waitForText("profile.summary.1", contains: "呼吸 · 低")
        openMenuBarPanel()
        element("menubar.quit").click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "点「退出」后 App 应退出")
    }

    /// XF-04 慢设备上命令行写入进行中拔出键盘：命令以 4 结束、不挂起；watch 不断开，插回后收到新事件。
    /// 脚本：开 watch → `cherry set --brightness 2`（信号）→ 立即在后台写配置 3 → 等它失败 → 键盘回来后
    /// `cherry set --brightness 3` → 等 watch 以 3 结束。
    func testUnplugDuringACommandLineWrite() throws {
        launch("slow", environment: ["CHERRY_CONTROL_SOCKET": try socket()])
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "亮度 中", timeout: 90)
        closeMenuBarPanel()
        // 脚本的第二个写入此时已在进行：慢设备上一次写入约 3 秒。
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        choose(menu: "模拟设备", item: "拔出键盘")
        openMenuBarPanel()
        wait(for: "menubar.empty", timeout: 10)
        closeMenuBarPanel()
        choose(menu: "模拟设备", item: "插入键盘")
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "亮度 高", timeout: 90)
    }

    /// XF-05 设置里的开关实时管住命令行与 MCP；设置页实时显示两者的调用，包括命令行直连时的调用（经共享记录与跨进程信号）。
    /// 脚本：MCP 调用一次 → 等 MCP 被拒 → 等命令行被拒（经由 App 与直连都拒）→ 等命令行恢复。
    func testSettingsSwitchesGateEntriesLive() throws {
        launch("pixiu75", environment: ["CHERRY_DATA_DIR": try dataDirectory()])
        openSettings(tab: "自动化")
        // 脚本先经 MCP 调用一次，随后一直调用到开关被关掉为止，所以只核对最近一次的内容，不核对次数。
        waitForText("settings.automation.mcp.activity", contains: "status · 经由 App · 成功", timeout: 90)
        let mcp = app.switches["settings.automation.mcp"]
        mcp.click()
        waitUntil("MCP 开关关闭") { !self.isOn(mcp) }
        waitForText("settings.automation.mcp.activity", contains: "经由 App · 失败", timeout: 60)
        mcp.click()
        let commandLine = app.switches["settings.automation.commandLine"]
        commandLine.click()
        waitUntil("命令行开关关闭") { !self.isOn(commandLine) }
        waitForText("settings.automation.commandLine.activity", contains: "命令行直连 · 失败", timeout: 60)
        commandLine.click()
        waitUntil("命令行开关打开") { self.isOn(commandLine) }
        waitForText("settings.automation.commandLine.activity", contains: "成功", timeout: 60)
    }

    /// XF-06 App 刷写固件期间，直连的 cherry 写入与读取都立即被拒（跨进程租约上的刷写标记）；刷写结束后直连写入生效，
    /// App 收到跨进程信号后主窗口随之刷新。脚本：等锁文件出现刷写标记 → 直连写读各一次 → 等标记清除 → 直连写配置 3。
    func testFlashBlocksADirectCommandLine() throws {
        launch("slowflash", environment: ["CHERRY_DATA_DIR": try dataDirectory()])
        openSection("固件升级")
        element("firmware.download").click()
        let flash = element("firmware.flash")
        waitUntil("可以开始升级", timeout: 20) { flash.exists && flash.isEnabled }
        flash.click()
        alertButton("开始升级").click()
        waitForText("firmware.phase", contains: "升级完成", timeout: 90)
        openSection("灯光与配置档")
        waitForText("profile.summary.2", contains: "曲线", timeout: 90)
    }

    /// XF-07 添加到 Claude Desktop：脚本预先放好含其他服务的配置；添加后状态变为「已添加」，脚本核对其他内容原样保留。
    func testAddingToClaudeDesktop() throws {
        launch("pixiu75", environment: ["CHERRY_DATA_DIR": try dataDirectory()])
        openSettings(tab: "自动化")
        waitForText("settings.automation.claudeDesktop", contains: "未添加", timeout: 10)
        wait(for: "settings.automation.claudeDesktop.add").click()
        waitForText("settings.automation.notice", contains: "已添加到 Claude Desktop，重启它后生效")
        waitForText("settings.automation.claudeDesktop", contains: "已添加（")
    }
}
