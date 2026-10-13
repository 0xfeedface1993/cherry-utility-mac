import XCTest

/// UI-40…UI-46：菜单栏图标与面板。
@MainActor
final class MenuBarUITests: CherryUITestCase {
    /// UI-40 菜单栏图标存在，点开面板显示设备、电量、工作模式、固件和当前灯效。
    func testPanelShowsDeviceStatus() {
        launch()
        let panel = openMenuBarPanel()
        waitForText("menubar.device", contains: "CHERRY MX PIXIU 75")
        waitForText("menubar.battery", contains: "95%")
        XCTAssertTrue(text("menubar.battery").contains("充电中"))
        XCTAssertTrue(text("menubar.connection").contains("有线 USB"))
        XCTAssertTrue(text("menubar.firmware").contains("固件 0.1.1.7"))
        XCTAssertTrue(text("menubar.summary").contains("配置 2 · 波纹 · 亮度 全亮"))
        XCTAssertEqual(panel.radioGroups["menubar.profile"].radioButtons["配置 2"].value as? Int, 1)
        XCTAssertTrue(text("menubar.effect.0").contains("已选中"))
        XCTAssertTrue(text("menubar.color.summary").contains("随机颜色"))
    }

    /// UI-41 面板切换配置档，主窗口的配置页同步当前标记。
    func testPanelSwitchesProfile() {
        launch()
        let panel = openMenuBarPanel()
        panel.radioGroups["menubar.profile"].radioButtons["配置 1"].click()
        waitForText("menubar.summary", contains: "配置 1 · 放射")
        closeMenuBarPanel()
        openSection("灯光与配置档")
        wait(for: "profile.current.0")
    }

    /// UI-42 面板修改灯效、亮度、速度、颜色，立即写入当前配置档，主窗口同步。
    func testPanelChangesLightingImmediately() {
        launch()
        let panel = openMenuBarPanel()
        element("menubar.effect.2").click()
        waitForText("menubar.summary", contains: "呼吸")
        panel.radioGroups["menubar.brightness"].radioButtons["中"].click()
        waitForText("menubar.summary", contains: "亮度 中")
        element("menubar.color.swatch.00D70F").click()
        waitForText("menubar.color.summary", contains: "固定颜色 #00D70F")
        element("menubar.speed").adjust(toNormalizedSliderPosition: 1.0)
        waitUntil("速度应写到最快") { (self.element("menubar.speed").value as? String).map { $0.hasPrefix("4") } ?? (self.element("menubar.speed").value as? Int == 4) }
        closeMenuBarPanel()

        openSection("概览")
        element("info.refresh").click()
        waitForText("info.effect", contains: "呼吸 · 速度 5 / 5")
        waitForText("info.brightness", contains: "中")
        waitForText("info.color", contains: "#00D70F")
    }

    /// UI-43 面板「载入预设到当前配置档」把本地预设写入键盘。
    func testPanelAppliesPreset() {
        launch()
        openSection("灯光与配置档")
        wait(for: "preset.empty")
        element("config.effect.12").click()
        window.radioGroups["config.brightness"].radioButtons["高"].click()
        type("曲线高亮", into: element("preset.name"))
        element("preset.save").click()
        wait(for: "preset.load.曲线高亮")
        element("savebar.discard").click()

        openMenuBarPanel()
        choose("曲线高亮", fromMenu: "menubar.presets")
        waitForText("menubar.summary", contains: "曲线 · 亮度 高")
    }

    /// UI-44 面板「打开 CHERRY Utility」在窗口最小化后把主窗口带回前台。
    func testPanelOpensMainWindow() {
        launch()
        window.buttons["_XCUI:MinimizeWindow"].click()
        openMenuBarPanel()
        element("menubar.openMain").click()
        waitUntil("主窗口应可点击") { self.window.isHittable }
    }

    /// UI-45 没有「输入监控」权限时面板提示错误并提供系统设置入口。
    func testDeniedScenarioOffersInputMonitoringSettings() {
        launch("denied")
        openMenuBarPanel()
        waitForText("menubar.error", contains: "输入监控")
        wait(for: "menubar.openSettings")
    }

    /// UI-46 菜单栏面板刷新按钮可重新读取状态。
    func testPanelRefresh() {
        launch()
        openMenuBarPanel()
        waitForText("menubar.battery", contains: "95%")
        element("menubar.refresh").click()
        waitForText("menubar.battery", contains: "95%")
    }

    /// 同型号双设备可区分，写入第二台后切回第一台，配置互不影响。
    func testPanelSwitchesBetweenTwoIndependentDevices() {
        launch("dual")
        openMenuBarPanel()
        waitForText("menubar.battery", contains: "95%")
        selectMenuBarDevice("03200000")
        waitForText("menubar.battery", contains: "53%")
        element("menubar.profile").radioButtons["配置 1"].click()
        waitForText("menubar.summary", contains: "配置 1 · 放射")
        waitForDisappearance(element("menubar.configuring"))
        selectMenuBarDevice("03100000")
        waitForText("menubar.battery", contains: "95%")
        waitForText("menubar.summary", contains: "配置 2 · 波纹")
    }

    /// 慢写期间仍可切换 profile 和灯效；最新意图稳定显示，最终落到正确的 profile。
    func testSlowWritesKeepProfileAndLightingControlsEnabled() {
        launch("slow")
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 2 · 波纹", timeout: 15)
        let profiles = element("menubar.profile")
        profiles.radioButtons["配置 1"].click()
        wait(for: "menubar.configuring")
        XCTAssertTrue(profiles.radioButtons["配置 3"].isEnabled)
        XCTAssertTrue(element("menubar.effect.2").isEnabled)
        profiles.radioButtons["配置 3"].click()
        element("menubar.effect.2").click()
        waitForText("menubar.summary", contains: "配置 3 · 呼吸")
        XCTAssertTrue(element("menubar.brightness").isEnabled)
        waitForDisappearance(element("menubar.configuring"), timeout: 20)
        element("menubar.refresh").click()
        waitForText("menubar.summary", contains: "配置 3 · 呼吸", timeout: 15)
    }

    private func selectMenuBarDevice(_ location: String) {
        let picker = element("menubar.devicePicker")
        picker.click()
        // 原生 PopUpButton 的选项在 AX 树中是 title，菜单打开时 isHittable 也不可靠。
        // dual 场景按 KeyboardID 排序，使用已验证的菜单层级和顺序，切换后的独立状态另行断言。
        let option = picker.menuItems.element(boundBy: location == "03100000" ? 0 : 1)
        XCTAssertTrue(option.waitForExistence(timeout: 5), "设备选项 \(location) 应显示")
        option.click()
    }
}
