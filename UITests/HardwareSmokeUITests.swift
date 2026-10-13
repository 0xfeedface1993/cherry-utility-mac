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

        openSection("灯光与配置档")
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

        openSection("灯光与配置档")
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

        openSection("灯光与配置档")
        edit(profile: target)
        let load = element("preset.load.\(backup)")
        reveal(load); load.click()
        waitForText("banner.success", contains: "已载入预设「\(backup)」")
        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 \(target + 1)", timeout: 20)
        waitForDisappearance(element("savebar.status"), timeout: 20)
        XCTAssertEqual(profileBlocks(name: "raw-restored"), before, "恢复后应与测试前逐字节一致；备份预设「\(backup)」已保留")

        openSection("灯光与配置档")
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
        let active = try XCTUnwrap(["配置 1", "配置 2", "配置 3"].first { profiles.radioButtons[$0].value as? Int == 1 })
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
        openSection("概览")
        waitForText("info.activeProfile", contains: "配置 \(active)")
    }

    /// UI-93 真机按键采集：需要有人在键盘上按键，另设 `TEST_RUNNER_CHERRY_UITEST_KEYPRESS=1`。
    /// 「按键测试」开始监听后 90 秒内，按任意 5 个不同的键（Fn 不计），再同时按住两个键后松开。
    func testRealKeyboardCapturesPhysicalKeys() throws {
        try requireOperator()
        openRealKeyTest()
        waitUntil("应记录到 5 个不同的按键，实际「\(text("keytest.tested"))」", timeout: 90) { number("keytest.tested") >= 5 }
        waitUntil("应记录到同时按下 2 个键", timeout: 60) { number("keytest.max") >= 2 }
        // 各项统计分几次查询读取；等停手后数字稳定再比较，避免边按边读造成前后不一致。
        var stats = keyStats()
        waitUntil("停手后统计应稳定且没有按住的键", timeout: 30) {
            let previous = stats
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            stats = keyStats()
            return stats == previous && stats.pressed == 0
        }
        XCTAssertGreaterThanOrEqual(stats.events, 2 * stats.tested, "每个键至少有按下和松开两个事件：\(stats)")
        XCTAssertFalse(element("keytest.error").exists)
    }

    /// UI-94 真机 USB 拔插：需要有人操作，与 UI-93 共用 `TEST_RUNNER_CHERRY_UITEST_KEYPRESS=1`。
    /// 菜单栏面板弹出后拔下 USB 线；面板自动关闭后插回同一个接口；再次「正在监听」后按任意一个字母键。
    /// 面板在拔线前打开（打开面板后 XCUITest 要等数秒空闲），拔线的同时就能核对，不受插回快慢影响。
    func testRealKeyboardSurvivesUnplugAndReplug() throws {
        try requireOperator()
        openSection("概览")
        waitForText("info.crc", contains: "0x", timeout: 15)
        let crc = text("info.crc")
        openRealKeyTest()
        openMenuBarPanel()

        // 面板对人已可见时 XCUITest 可能仍在等空闲，拔线可能早于这里；只看拔线后的结果。
        // 键盘若改走无线连接，面板会显示那个设备；有线的这一个不应再出现。
        waitUntil("拔出后菜单栏应清空或不再显示有线设备", timeout: 120) {
            let connection = self.element("menubar.connection")
            return self.element("menubar.empty").exists || (connection.exists && !self.text(of: connection).contains("有线"))
        }
        waitForText("keytest.state", contains: "未监听", timeout: 10)
        XCTAssertTrue(element("detail.disconnected").exists, "详情页应提示断开")
        XCTAssertTrue(element("sidebar.disconnectedKeyboard").exists, "拔出的键盘应列在「已断开」")
        closeMenuBarPanel()

        waitForDisappearance(element("detail.disconnected"), timeout: 120)
        app.activate()
        waitForText("keytest.state", contains: "正在监听", timeout: 20)
        let events = number("keytest.events")
        waitUntil("插回后按键应被记录", timeout: 60) { number("keytest.events") > events }

        openMenuBarPanel()
        waitForText("menubar.device", contains: "PIXIU 75", timeout: 15)
        waitForText("menubar.connection", contains: "有线", timeout: 15)
        closeMenuBarPanel()
        openSection("概览")
        waitForText("info.connection", contains: "USB", timeout: 15)
        waitForText("info.crc", contains: "0x", timeout: 15)
        XCTAssertEqual(text("info.crc"), crc, "插回后重新读取的固件 CRC 应与拔出前一致")
    }

    /// UI-95 真机官方固件刷写：会改写键盘固件，另设 `TEST_RUNNER_CHERRY_UITEST_FLASH=1`。
    /// 从官方目录下载并校验升级包，刷写后等待重启，读回 CRC 与升级包一致。键盘原先若是修改过的同版本固件，这一步即恢复原厂。
    func testRealKeyboardFlashesOfficialFirmware() throws {
        try requireFlash()
        let before = profileBlocks(name: "raw-before-official")
        openSection("固件升级")
        wait(for: "firmware.current", timeout: 15)
        waitForText("firmware.latest", contains: "0.1.1", timeout: 30)
        element("firmware.download").click()
        waitForText("firmware.package.file", contains: "MX_PIXIU75_WIRELESS_", timeout: 120)
        XCTAssertTrue(text("firmware.package.target").contains("PID 0x01E2"))
        waitForText("firmware.package.deviceCRC", contains: "与升级包", timeout: 30)
        note("device-before-official", text("firmware.package.deviceCRC"))
        let flash = element("firmware.flash")
        reveal(flash)
        XCTAssertTrue(flash.isEnabled)
        flash.click()
        alertButton("开始升级").click()
        waitForText("firmware.phase", contains: "升级完成，固件 CRC 与升级包一致", timeout: 240)
        waitForText("firmware.package.deviceCRC", contains: "与升级包相同", timeout: 30)
        note("device-after-official", text("firmware.phase"))
        XCTAssertEqual(profileBlocks(name: "raw-after-official"), before, "刷写固件不应改动板载配置")
    }

    /// UI-96 真机自定义固件写入：会改写键盘固件，另设 `TEST_RUNNER_CHERRY_UITEST_FLASH=1`。
    /// 键盘应识别为原厂 0117；写入已保存的「方案 1」后读回 CRC 一致，并识别为该方案。
    func testRealKeyboardInstallsSavedVariant() throws {
        try requireFlash()
        let before = profileBlocks(name: "raw-before-variant")
        openSection("自定义固件")
        waitForText("custom.installed", contains: "原厂固件 0.1.1.7", timeout: 30)
        note("installed-before-variant", text("custom.installed"))
        element("custom.stock.fetch").click()
        waitForText("custom.stock.status", contains: "已获取", timeout: 120)
        waitForText("custom.variant.name", contains: "方案 1", timeout: 15)
        waitForText("custom.summary", contains: "0x46F8C57A", timeout: 30)
        let install = element("custom.install")
        reveal(install)
        XCTAssertTrue(install.isEnabled)
        install.click()
        alertButton("开始写入").click()
        waitForText("custom.phase", contains: "键盘读回的 CRC 与写入镜像一致", timeout: 240)
        waitForText("custom.installed", contains: "自定义方案「方案 1」", timeout: 30)
        XCTAssertTrue(text("custom.installed").contains("0x46F8C57A"))
        note("installed-after-variant", text("custom.installed"))
        XCTAssertEqual(profileBlocks(name: "raw-after-variant"), before, "刷写固件不应改动板载配置")
    }

    // MARK: Helpers

    /// 会改写固件的用例：真机 + 单独的开关，平时运行真机用例不会刷写。
    private func requireFlash() throws {
        try requireHardware()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHERRY_UITEST_FLASH"] == "1", "未开启会改写固件的真机测试")
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
    }

    private func note(_ name: String, _ value: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// 需要有人在键盘旁操作的用例：启动真机 App 并等到读出型号。
    private func requireOperator() throws {
        try requireHardware()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHERRY_UITEST_KEYPRESS"] == "1", "未开启需要人工操作的真机测试")
        launch(nil)
        waitForText("info.model", contains: "MX PIXIU 75", timeout: 15)
    }

    private func openRealKeyTest() {
        app.activate() // 按键会同时输入到前台应用，确保前台是本 App。
        openSection("按键测试")
        wait(for: "keytest.canvas")
        waitForText("keytest.state", contains: "正在监听", timeout: 15)
    }

    private func number(_ id: String) -> Int { Int(text(id).prefix { $0.isNumber }) ?? 0 }

    private struct KeyStats: Equatable { var tested = 0, pressed = 0, events = 0 }
    private func keyStats() -> KeyStats {
        KeyStats(tested: number("keytest.tested"), pressed: number("keytest.pressed"), events: number("keytest.events"))
    }

    private func edit(profile n: Int) {
        wait(for: "profile.card.\(n)", timeout: 15)
        if !text("profile.card.\(n)").contains("编辑中") { element("profile.card.\(n)").click() }
        waitUntil("配置 \(n + 1) 应进入编辑") { text("profile.card.\(n)").contains("编辑中") }
    }

    private func savePreset(named name: String) {
        let field = element("preset.name")
        reveal(field)
        type(name, into: field)
        element("preset.save").click()
        waitForText("banner.success", contains: "已保存预设「\(name)」")
        wait(for: "preset.load.\(name)")
    }

    /// 设备信息页重新读取后，三个配置档（0x05）的原始十六进制；附在结果包里，便于失败时手动恢复。
    private func profileBlocks(name: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        openSection("概览")
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
