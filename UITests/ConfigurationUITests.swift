import XCTest

/// UI-20…UI-27：灯效与配置页（板载配置档、草稿编辑、写入键盘）。
@MainActor
final class ConfigurationUITests: CherryUITestCase {
    /// 写入中继续编辑并再次提交，控件保持可用，最后一批写完才清除状态。
    func testSlowSaveAllowsEditingAndQueuedSubmission() {
        launch("slow")
        openSection("灯效与配置")
        wait(for: "config.effect.2", timeout: 15)
        element("config.brightness").radioButtons["低"].click()
        element("savebar.save").click()
        waitForText("savebar.status", contains: "正在配置键盘")
        XCTAssertTrue(element("config.effect.2").isEnabled)
        element("config.effect.2").click()
        XCTAssertTrue(element("savebar.save").isEnabled)
        element("savebar.save").click()
        waitForDisappearance(element("savebar.status"), timeout: 20)
        element("config.reload").click()
        waitForText("profile.summary.1", contains: "呼吸 · 低", timeout: 15)
    }

    private func openConfiguration() {
        launch()
        openSection("灯效与配置")
        wait(for: "profile.card.0")
    }

    private var saveBarStatus: XCUIElement { element("savebar.status") }

    /// UI-20 三个板载配置档卡片，当前配置档带「当前」标记，默认编辑当前配置档。
    func testListsThreeProfilesAndMarksActiveOne() {
        openConfiguration()
        XCTAssertTrue(text("profile.summary.0").contains("放射"))
        XCTAssertTrue(text("profile.summary.1").contains("波纹"))
        XCTAssertTrue(text("profile.summary.2").contains("常亮"))
        XCTAssertTrue(element("profile.current.1").exists)
        XCTAssertFalse(element("profile.current.0").exists)
        XCTAssertTrue(text("profile.card.1").contains("编辑中"))
        XCTAssertFalse(element("profile.activate.1").exists, "当前配置档不显示「设为当前」")
        XCTAssertTrue(text("config.effect.0").contains("已选中"))
    }

    /// UI-21 「设为当前」切换键盘的当前配置档，设备信息页和菜单栏同步更新。
    func testActivatingProfileUpdatesBadgeInfoAndMenuBar() {
        openConfiguration()
        element("profile.activate.2").click()
        wait(for: "profile.current.2")
        waitForText("banner.success", contains: "已切换到配置 3")
        XCTAssertFalse(element("profile.current.1").exists)

        openSection("设备信息")
        waitForText("info.activeProfile", contains: "配置 3")
        waitForText("info.effect", contains: "常亮")

        openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 3")
        closeMenuBarPanel()
    }

    /// UI-22 修改出现「未写入」保存栏并计数；放弃后恢复为键盘上的值。
    func testEditingShowsSaveBarAndDiscardRestoresDeviceValues() {
        openConfiguration()
        XCTAssertFalse(saveBarStatus.exists)
        element("config.effect.18").click()
        wait(for: "config.effect.dirty")
        waitForText("savebar.status", contains: "1 项修改")
        window.radioGroups["config.brightness"].radioButtons["低"].click()
        waitForText("savebar.status", contains: "2 项修改")
        XCTAssertTrue(text("config.effect.18").contains("已选中"))

        element("savebar.discard").click()
        waitForDisappearance(saveBarStatus)
        XCTAssertTrue(text("config.effect.0").contains("已选中"))
        XCTAssertEqual(window.radioGroups["config.brightness"].radioButtons["全亮"].value as? Int, 1)
    }

    /// UI-23 改回原值时修改计数归零，保存栏自动消失。
    func testReturningToOriginalValueClearsDirtyState() {
        openConfiguration()
        element("config.effect.2").click()
        waitForText("savebar.status", contains: "1 项修改")
        element("config.effect.0").click()
        waitForDisappearance(saveBarStatus)
    }

    /// UI-24 写入灯效、亮度、固定颜色后，重新读取键盘仍是新值，设备信息页同步。
    func testWritingLightingPersistsOnKeyboard() {
        openConfiguration()
        element("config.effect.18").click()
        window.radioGroups["config.brightness"].radioButtons["低"].click()
        element("config.color.swatch.0099FF").click()
        waitForText("config.color.summary", contains: "固定颜色 #0099FF")
        waitForText("savebar.status", contains: "4 项修改") // 灯效、亮度、颜色、随机颜色

        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 2")
        waitForDisappearance(saveBarStatus)

        element("config.reload").click()
        waitForText("profile.summary.1", contains: "放射 · 低")
        XCTAssertTrue(text("config.effect.18").contains("已选中"))
        XCTAssertTrue(text("config.color.summary").contains("#0099FF"))

        openSection("设备信息")
        waitForText("info.effect", contains: "放射")
        waitForText("info.brightness", contains: "低")
        waitForText("info.color", contains: "#0099FF")
    }

    /// UI-25 编辑非当前配置档：写入只影响该配置档，当前配置档不变。
    func testEditingAnotherProfileDoesNotTouchActiveOne() {
        openConfiguration()
        element("profile.card.0").click()
        waitUntil("配置 1 应进入编辑") { text("profile.card.0").contains("编辑中") }
        XCTAssertTrue(text("config.effect.18").contains("已选中"))
        element("config.effect.21").click()
        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 1")
        waitForText("profile.summary.0", contains: "单点亮")
        XCTAssertTrue(text("profile.summary.1").contains("波纹"))
        XCTAssertTrue(element("profile.current.1").exists)
    }

    /// UI-26 有未写入修改时切换配置档会确认；「继续编辑」保留草稿，「放弃并切换」丢弃。
    func testSwitchingProfileWithUnsavedChangesAsksFirst() {
        openConfiguration()
        element("config.effect.3").click()
        waitForText("savebar.status", contains: "1 项修改")

        element("profile.card.2").click()
        alertButton("继续编辑").click()
        XCTAssertTrue(text("profile.card.1").contains("编辑中"))
        XCTAssertTrue(text("config.effect.3").contains("已选中"))

        element("profile.card.2").click()
        alertButton("放弃并切换").click()
        waitUntil("应切换到配置 3") { text("profile.card.2").contains("编辑中") }
        XCTAssertFalse(saveBarStatus.exists)
    }

    /// UI-27 休眠设置：勾选「不休眠」写入 0；调整二级休眠滑块后数值随之变化。
    func testSleepSettingsWriteNeverSleep() {
        openConfiguration()
        let never = element("config.sleep.never")
        XCTAssertEqual(never.value as? Int, 0)
        never.click()
        waitForText("config.sleep.value", contains: "不休眠")
        element("config.deepSleep.slider").adjust(toNormalizedSliderPosition: 1.0)
        // Slider positioning is only approximately exact; the value snaps to 5-minute steps near the maximum.
        var deepSleep = ""
        waitUntil("二级休眠应接近最大值") {
            deepSleep = self.text("config.deepSleep.value")
            return Int(deepSleep.prefix { $0.isNumber }).map { $0 >= 280 && $0 % 5 == 0 } ?? false
        }
        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入")

        openSection("设备信息")
        waitForText("info.sleep", contains: "不休眠")
        waitForText("info.deepSleep", contains: deepSleep)
    }

    /// UI-28 选择「自定义」灯效显示逐键颜色提示。
    func testCustomEffectShowsHint() {
        openConfiguration()
        XCTAssertFalse(element("config.effect.customHint").exists)
        element("config.effect.8").click()
        wait(for: "config.effect.customHint")
    }
}
