import XCTest

/// XF-02、XF-04：菜单栏与命令行 / MCP 共用一个写入队列和变更流。由 `Scripts/verify-cross.sh` 驱动：
/// 脚本经 `TEST_RUNNER_CHERRY_E2E_SOCKET` 传入 socket 路径，在 shell 一侧运行 cherry、cherry mcp 和 watch。
/// runner 在沙盒里，不碰 socket 也不共享文件，双方只靠键盘状态握手。没有这个变量时跳过。
@MainActor
final class CrossEntryUITests: CherryUITestCase {
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
}
