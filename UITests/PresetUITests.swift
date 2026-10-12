import XCTest

/// UI-30…UI-33：本地预设（保存、载入、删除、导入导出面板）。
@MainActor
final class PresetUITests: CherryUITestCase {
    private func openConfiguration() {
        launch()
        openSection("灯效与配置")
        wait(for: "profile.card.0")
        wait(for: "preset.empty")
    }

    private func savePreset(named name: String) {
        type(name, into: element("preset.name"))
        element("preset.save").click()
        waitForText("banner.success", contains: "已保存预设「\(name)」")
        wait(for: "preset.load.\(name)")
    }

    /// UI-30 把编辑区保存为预设，列表显示名称与摘要，空状态消失。
    func testSavePresetFromEditor() {
        openConfiguration()
        element("config.effect.18").click()
        window.radioGroups["config.brightness"].radioButtons["中"].click()
        savePreset(named: "办公")
        XCTAssertFalse(element("preset.empty").exists)
        XCTAssertTrue(text("preset.detail.办公").contains("放射"))
        XCTAssertTrue(text("preset.detail.办公").contains("亮度 中"))
        XCTAssertTrue(text("preset.name").isEmpty || text("preset.name").contains("预设名称"), "保存后名称输入框清空")
    }

    /// UI-31 载入预设到另一个配置档：进入草稿，写入后该配置档变为预设内容。
    func testLoadPresetIntoAnotherProfileAndWrite() {
        openConfiguration()
        element("config.effect.19").click()
        window.radioGroups["config.brightness"].radioButtons["低"].click()
        savePreset(named: "夜间")
        element("savebar.discard").click()

        element("profile.card.2").click()
        waitUntil("切换到配置 3") { text("profile.card.2").contains("编辑中") }
        element("preset.load.夜间").click()
        waitForText("banner.success", contains: "已载入预设「夜间」")
        XCTAssertTrue(text("config.effect.19").contains("已选中"))
        wait(for: "savebar.status")
        element("savebar.save").click()
        waitForText("banner.success", contains: "已写入配置 3")
        waitForText("profile.summary.2", contains: "扩散 · 低")
    }

    /// UI-32 删除预设需要确认；取消保留，确认后列表恢复空状态。
    func testDeletePresetAsksForConfirmation() {
        openConfiguration()
        savePreset(named: "临时")
        choose("删除", fromMenu: "preset.menu.临时")
        alertButton("取消").click()
        XCTAssertTrue(element("preset.load.临时").exists)

        choose("删除", fromMenu: "preset.menu.临时")
        alertButton("删除").click()
        wait(for: "preset.empty")
        XCTAssertFalse(element("preset.load.临时").exists)
    }

    /// UI-33 导入、导出分别打开系统文件面板，取消后不改变预设列表。
    func testImportAndExportOpenFilePanels() {
        openConfiguration()
        savePreset(named: "导出测试")

        element("preset.import").click()
        let open = app.sheets.firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "导入应打开文件面板")
        open.buttons["取消"].firstMatch.exists ? open.buttons["取消"].firstMatch.click() : app.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(open)

        choose("导出…", fromMenu: "preset.menu.导出测试")
        let save = app.sheets.firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "导出应打开存储面板")
        save.buttons["取消"].firstMatch.exists ? save.buttons["取消"].firstMatch.click() : app.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(save)
        XCTAssertTrue(element("preset.load.导出测试").exists)
    }
}
