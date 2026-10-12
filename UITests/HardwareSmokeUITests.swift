import XCTest

/// UI-90…UI-92：真机用例。需要连接 PIXIU 75 并已授予本应用「输入监控」权限；
/// 以 `TEST_RUNNER_CHERRY_UITEST_HARDWARE=1 xcodebuild test …` 运行，默认跳过。
/// UI-91、UI-92 会写入键盘，结束时恢复原值，并核对三个配置档的原始数据与测试前逐字节一致。
@MainActor
final class HardwareSmokeUITests: CherryUITestCase {
    private func requireHardware() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHERRY_UITEST_HARDWARE"] == "1", "未开启真机测试")
    }

    /// UI-90 只读冒烟。
    func testRealKeyboardIsReadable() throws {
        try requireHardware()
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
        waitForText("info.activeProfile", contains: "共 3 个", timeout: 15)
        XCTAssertFalse(text("info.battery").isEmpty)

        openSection("灯效与配置")
        for n in 0..<3 { wait(for: "profile.summary.\(n)", timeout: 15) }
        XCTAssertFalse(element("savebar.status").exists, "只读检查不应产生修改")

        openMenuBarPanel()
        waitForText("menubar.device", contains: "PIXIU 75", timeout: 15)
        waitForText("menubar.summary", contains: "配置", timeout: 15)
    }

    /// UI-91 主窗口改写一个非当前配置档的全部字段，读回核对后用预设备份写回。
    /// 失败时备份预设保留在列表里（名称见失败信息），可手动载入恢复。
    func testRealKeyboardWritesEveryFieldAndRestores() throws {
        try requireHardware()
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
        let before = profileBlocks(name: "raw-before")

        openSection("灯效与配置")
        for n in 0..<3 { wait(for: "profile.summary.\(n)", timeout: 15) }
        // 改非当前配置档：键盘正在显示的灯效不变。
        let target = try XCTUnwrap((0..<3).first { element("profile.activate.\($0)").exists }, "没有非当前配置档")
        edit(profile: target)
        let backup = "真机测试备份-\(Int(Date().timeIntervalSince1970))"
        savePreset(named: backup)

        // 七个字段都换成与当前不同的值。
        let effect = text("config.effect.2").contains("已选中") ? 18 : 2
        element("config.effect.\(effect)").click()
        let brightness = window.radioGroups["config.brightness"]
        let level = try XCTUnwrap(["中", "高", "低"].first { brightness.radioButtons[$0].value as? Int != 1 })
        brightness.radioButtons[level].click()
        let speed = element("config.speed")
        speed.adjust(toNormalizedSliderPosition: "\(speed.value ?? "")".hasPrefix("5") ? 0 : 1)
        let color = text("config.color.swatch.0099FF").contains("已选中") ? "FF7200" : "0099FF"
        element("config.color.swatch.\(color)").click()
        for id in ["config.sleep.never", "config.deepSleep.never"] {
            reveal(element(id)); element(id).click()
        }
        waitForText("savebar.status", contains: "项修改")
        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 \(target + 1)", timeout: 20)
        waitForDisappearance(element("savebar.status"), timeout: 20)

        element("config.reload").click()
        waitForText("config.effect.\(effect)", contains: "已选中", timeout: 15)
        XCTAssertEqual(window.radioGroups["config.brightness"].radioButtons[level].value as? Int, 1)
        XCTAssertTrue(text("config.color.summary").contains("#\(color)"))

        let written = profileBlocks(name: "raw-written")
        XCTAssertNotEqual(written[target], before[target], "配置 \(target + 1) 应已改变")
        for n in 0..<3 where n != target {
            XCTAssertEqual(written[n], before[n], "写入只应影响配置 \(target + 1)，配置 \(n + 1) 被改动")
        }

        openSection("灯效与配置")
        edit(profile: target)
        let load = element("preset.load.\(backup)")
        reveal(load); load.click()
        waitForText("banner.success", contains: "已载入预设「\(backup)」")
        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 \(target + 1)", timeout: 20)
        waitForDisappearance(element("savebar.status"), timeout: 20)
        XCTAssertEqual(profileBlocks(name: "raw-restored"), before, "恢复后应与测试前逐字节一致；备份预设「\(backup)」已保留")

        openSection("灯效与配置")
        reveal(element("preset.menu.\(backup)"))
        choose("删除", fromMenu: "preset.menu.\(backup)")
        alertButton("删除").click()
        waitForDisappearance(element("preset.load.\(backup)"))
    }

    /// UI-92 菜单栏面板切换配置档、修改当前配置档亮度，再全部改回。
    func testRealKeyboardMenuBarWritesAndRestores() throws {
        try requireHardware()
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
        let before = profileBlocks(name: "raw-before")

        let panel = openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置", timeout: 15)
        let profiles = panel.radioGroups["menubar.profile"]
        let active = try XCTUnwrap(["1", "2", "3"].first { profiles.radioButtons[$0].value as? Int == 1 })
        let other = try XCTUnwrap(["1", "2", "3"].first { $0 != active })
        profiles.radioButtons[other].click()
        waitForText("menubar.summary", contains: "配置 \(other)", timeout: 15)
        profiles.radioButtons[active].click()
        waitForText("menubar.summary", contains: "配置 \(active)", timeout: 15)

        let brightness = panel.radioGroups["menubar.brightness"]
        let original = try XCTUnwrap(["灭", "低", "中", "高", "全亮"].first { brightness.radioButtons[$0].value as? Int == 1 })
        let changed = try XCTUnwrap(["中", "高", "低"].first { $0 != original })
        brightness.radioButtons[changed].click()
        waitForText("menubar.summary", contains: "亮度 \(changed)", timeout: 15)
        brightness.radioButtons[original].click()
        waitForText("menubar.summary", contains: "亮度 \(original)", timeout: 15)
        closeMenuBarPanel()

        XCTAssertEqual(profileBlocks(name: "raw-restored"), before, "菜单栏改回后应与测试前逐字节一致")
        openSection("设备信息")
        waitForText("info.activeProfile", contains: "配置 \(active)")
    }

    /// UI-93 真机按键采集：需要有人在键盘上按键，另设 `TEST_RUNNER_CHERRY_UITEST_KEYPRESS=1`。
    /// 「按键测试」开始监听后 90 秒内，按任意 5 个不同的键（Fn 不计），再同时按住两个键后松开。
    func testRealKeyboardCapturesPhysicalKeys() throws {
        try requireHardware()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHERRY_UITEST_KEYPRESS"] == "1", "未开启实体按键测试")
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
        openSection("按键测试")
        wait(for: "keytest.canvas")
        waitForText("keytest.state", contains: "正在监听", timeout: 15)
        func count(_ id: String) -> Int { Int(text(id).prefix { $0.isNumber }) ?? 0 }
        waitUntil("应记录到 5 个不同的按键，实际「\(text("keytest.tested"))」", timeout: 90) { count("keytest.tested") >= 5 }
        waitUntil("应记录到同时按下 2 个键", timeout: 60) { count("keytest.max") >= 2 }
        waitUntil("松开后当前按下应为 0", timeout: 15) { count("keytest.pressed") == 0 }
        XCTAssertGreaterThanOrEqual(count("keytest.events"), 2 * count("keytest.tested"), "每个键至少有按下和松开两个事件")
        XCTAssertFalse(element("keytest.error").exists)
    }

    // MARK: Helpers

    private func edit(profile n: Int) {
        wait(for: "profile.card.\(n)", timeout: 15)
        if !text("profile.card.\(n)").contains("编辑中") { element("profile.card.\(n)").click() }
        waitUntil("配置 \(n + 1) 应进入编辑") { text("profile.card.\(n)").contains("编辑中") }
    }

    private func savePreset(named name: String) {
        let field = element("preset.name")
        reveal(field)
        field.click()
        field.typeText(name)
        element("preset.save").click()
        waitForText("banner.success", contains: "已保存预设「\(name)」")
        wait(for: "preset.load.\(name)")
    }

    /// 设备信息页重新读取后，三个配置档（0x05）的原始十六进制；附在结果包里，便于失败时手动恢复。
    private func profileBlocks(name: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        openSection("设备信息")
        let refresh = element("info.refresh")
        waitUntil("刷新按钮可用", timeout: 15) { refresh.isEnabled }
        refresh.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        waitUntil("刷新完成", timeout: 15) { refresh.isEnabled }
        let toggle = element("info.raw.toggle")
        reveal(toggle)
        if text(of: toggle).contains("已收起") { toggle.click() }
        let lines = wait(for: "info.raw.content").staticTexts.allElementsBoundByIndex.map { text(of: $0) }
        // 同一段文本在无障碍树里可能出现两次，按标题去重。
        var headers: [String] = [], blocks: [String] = []
        for i in lines.indices.dropLast() where lines[i].hasPrefix("0x05") && !headers.contains(lines[i]) {
            headers.append(lines[i]); blocks.append(lines[i + 1])
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(blocks.count, 3, "应读到三个配置档的原始数据", file: file, line: line)
        return blocks
    }
}
