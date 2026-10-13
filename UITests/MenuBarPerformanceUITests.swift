import AppKit
import XCTest

/// 固定 UI 动作驱动器。采集与分析由外部 Scripts runner 拥有，不向 App 注入 benchmark 逻辑。
@MainActor
final class MenuBarPerformanceUITests: CherryUITestCase {
    func testFixedMenuSequence() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CHERRY_PROFILE_OUTPUT"], let appPath = environment["CHERRY_PROFILE_APP"] else {
            throw XCTSkip("只由 run-menu-profile.py 启动具名性能场景")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        launch()
        waitForText("info.effect", contains: "波纹")
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 2")
        let target = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL
        let processes = NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target }
        XCTAssertEqual(processes.count, 1, "必须唯一解析当前具名产品")
        let pid = try XCTUnwrap(processes.first?.processIdentifier)
        try write(["pid": pid, "app": appPath, "ready_epoch": Date().timeIntervalSince1970], to: output.appendingPathComponent("ready.json"))
        try waitForFile(output.appendingPathComponent("profile.go"), timeout: 45)

        var actions: [[String: Any]] = []
        let start = Date().timeIntervalSince1970
        let effects: [(String, String)] = [("2", "呼吸"), ("3", "常亮"), ("12", "曲线"), ("18", "放射"), ("0", "波纹")]
        for index in 0..<20 {
            let (id, name) = effects[index % effects.count]
            let began = Date().timeIntervalSince1970
            element("menubar.effect." + id).click()
            waitForText("menubar.summary", contains: name)
            actions.append(["action": "effect", "ordinal": index, "start_epoch": began, "end_epoch": Date().timeIntervalSince1970])
        }
        for index in 0..<4 {
            let began = Date().timeIntervalSince1970
            let panel = element("menubar.panel")
            let profile = index.isMultiple(of: 2) ? "1" : "2"
            panel.radioGroups["menubar.profile"].radioButtons["配置 " + profile].click()
            waitForText("menubar.summary", contains: "配置 " + profile)
            actions.append(["action": "profile", "ordinal": index, "start_epoch": began, "end_epoch": Date().timeIntervalSince1970])
        }
        let warmEnd = Date().timeIntervalSince1970
        closeMenuBarPanel()
        waitForText("info.activeProfile", contains: "配置 2")
        waitForText("info.effect", contains: "波纹")
        try write(["scenario": "menu-effects20-profiles4-v1", "start_epoch": start, "warm_end_epoch": warmEnd,
                   "end_epoch": Date().timeIntervalSince1970, "actions": actions, "verified": true],
                  to: output.appendingPathComponent("actions.json"))
        try waitForFile(output.appendingPathComponent("profile.saved"), timeout: 60)
    }

    func testMenuMemorySequence() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CHERRY_PROFILE_OUTPUT"], let appPath = environment["CHERRY_PROFILE_APP"] else {
            throw XCTSkip("只由 run-menu-profile.py 启动具名性能场景")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        launch()
        waitForText("info.effect", contains: "波纹")
        // 先预热面板，随后统计 20 轮开关与灯效切换。
        openMenuBarPanel()
        closeMenuBarPanel()
        let target = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL
        let processes = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
        }
        XCTAssertEqual(processes.count, 1)
        let pid = try XCTUnwrap(processes.first?.processIdentifier)
        try write(["pid": pid, "app": appPath, "ready_epoch": Date().timeIntervalSince1970], to: output.appendingPathComponent("ready.json"))
        try waitForFile(output.appendingPathComponent("profile.go"), timeout: 45)
        let start = Date().timeIntervalSince1970
        var actions: [[String: Any]] = []
        for index in 0..<20 {
            let began = Date().timeIntervalSince1970
            openMenuBarPanel()
            let id = index.isMultiple(of: 2) ? "2" : "0"
            let name = index.isMultiple(of: 2) ? "呼吸" : "波纹"
            element("menubar.effect." + id).click()
            waitForText("menubar.summary", contains: name)
            closeMenuBarPanel()
            waitForText("info.effect", contains: name)
            actions.append(["action": "panel-effect-close", "ordinal": index, "start_epoch": began, "end_epoch": Date().timeIntervalSince1970])
        }
        try write(["scenario": "menu-memory20-v1", "start_epoch": start, "warm_end_epoch": Date().timeIntervalSince1970,
                   "end_epoch": Date().timeIntervalSince1970, "actions": actions, "verified": true], to: output.appendingPathComponent("actions.json"))
        try waitForFile(output.appendingPathComponent("profile.saved"), timeout: 60)
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        // XCTest runner 的 sandbox 只读外部握手文件；结果通过测试输出返回采集器。
        let prefix = url.lastPathComponent == "ready.json" ? "CHERRY_PROFILE_READY " : "CHERRY_PROFILE_ACTIONS "
        FileHandle.standardOutput.write(Data((prefix + String(decoding: data, as: UTF8.self) + "\n").utf8))
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { throw NSError(domain: "MenuProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: "采集器未完成握手：" + url.lastPathComponent]) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
