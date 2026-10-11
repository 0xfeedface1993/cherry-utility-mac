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
        XCTAssertEqual(panel.radioGroups["menubar.profile"].radioButtons["2"].value as? Int, 1)
        XCTAssertTrue(text("menubar.effect.0").contains("已选中"))
        XCTAssertTrue(text("menubar.color.summary").contains("随机颜色"))
    }

    /// UI-41 面板切换配置档，主窗口的配置页同步当前标记。
    func testPanelSwitchesProfile() {
        launch()
        let panel = openMenuBarPanel()
        panel.radioGroups["menubar.profile"].radioButtons["1"].click()
        waitForText("menubar.summary", contains: "配置 1 · 放射")
        closeMenuBarPanel()
        openSection("灯效与配置")
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

        openSection("设备信息")
        element("info.refresh").click()
        waitForText("info.effect", contains: "呼吸 · 速度 5 / 5")
        waitForText("info.brightness", contains: "中")
        waitForText("info.color", contains: "#00D70F")
    }

    /// UI-43 面板「载入预设到当前配置档」把本地预设写入键盘。
    func testPanelAppliesPreset() {
        launch()
        openSection("灯效与配置")
        wait(for: "preset.empty")
        element("config.effect.12").click()
        window.radioGroups["config.brightness"].radioButtons["高"].click()
        let field = element("preset.name")
        field.click()
        field.typeText("曲线高亮")
        element("preset.save").click()
        wait(for: "preset.load.曲线高亮")
        element("savebar.discard").click()

        openMenuBarPanel()
        element("menubar.presets").click()
        app.menuItems["曲线高亮"].click()
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
}
