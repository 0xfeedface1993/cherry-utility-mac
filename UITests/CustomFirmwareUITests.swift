import XCTest

/// UI-63…UI-66：自定义固件（模拟场景 `customfw`：键盘运行合成的 0117 原厂镜像，模拟目录提供该原厂升级包和一份模拟定义）。
@MainActor
final class CustomFirmwareUITests: CherryUITestCase {
    private func openCustomFirmware(_ scenario: String = "customfw") {
        launch(scenario, experimental: ["customFirmware"])
        openSection("自定义固件")
        wait(for: "custom.installed")
    }

    private func fetchStock() {
        element("custom.stock.fetch").click()
        waitForText("custom.stock.status", contains: "已获取")
    }

    /// UI-63 新建方案 → 打开选项 → 保存 → 写入并验证 → 识别为该方案 → 恢复原厂 → 识别为原厂。
    func testVariantIsFlashedRecognisedAndStockRestored() {
        openCustomFirmware()
        waitForText("custom.installed", contains: "原厂固件 0.1.1.7")
        XCTAssertFalse(element("custom.install").isEnabled, "没有方案和原厂镜像时不能写入")

        fetchStock()
        element("custom.variant.new").click()
        waitForText("custom.variant.name", contains: "方案 1")
        let toggle = wait(for: "custom.option.frow.fixed")
        toggle.click()
        waitForText("custom.summary", contains: "保存后计算 CRC")
        XCTAssertFalse(element("custom.install").isEnabled, "未保存的方案不能写入")

        element("custom.save").click()
        waitForText("custom.summary", contains: "镜像 CRC")
        let install = element("custom.install")
        reveal(install)
        XCTAssertTrue(install.isEnabled)
        install.click()
        alertButton("开始写入").click()
        waitForText("custom.phase", contains: "键盘读回的 CRC 与写入镜像一致", timeout: 40)
        waitForText("custom.installed", contains: "自定义方案「方案 1」")
        waitForAnything(containing: "已写入")

        let restore = element("custom.restore")
        reveal(restore)
        restore.click()
        alertButton("开始写入").click()
        waitForText("custom.phase", contains: "已写入原厂固件", timeout: 40)
        waitForText("custom.installed", contains: "原厂固件 0.1.1.7")
    }

    /// UI-64 草稿：未保存时不能写入；切换方案前询问；放弃修改恢复已保存内容。
    func testUnsavedChangesAreGuarded() {
        openCustomFirmware()
        element("custom.variant.new").click()
        waitForText("custom.variant.name", contains: "方案 1")
        element("custom.variant.new").click()
        waitForText("custom.variant.name", contains: "方案 2")

        wait(for: "custom.option.frow.fixed").click()
        let discard = wait(for: "custom.discard")
        element("custom.variant.row").click()
        alertButton("继续编辑").click()
        XCTAssertTrue(text("custom.variant.name").contains("方案 2"))

        discard.click()
        waitForDisappearance(discard)
        XCTAssertFalse(element("custom.save").isEnabled)
    }

    /// UI-65 默认场景的键盘运行真实原厂 CRC，不属于模拟定义：显示未知固件。
    func testUnknownImageIsReported() {
        openCustomFirmware("pixiu75")
        waitForText("custom.installed", contains: "未知固件")
        XCTAssertTrue(text("custom.installed").contains("0xCFE1A03E"))
    }

    /// UI-66 无线连接没有 OTA 接口：提示需要有线连接，写入与恢复都不可用。
    func testWirelessConnectionBlocksInstalling() {
        openCustomFirmware("wireless")
        waitForText("custom.installed", contains: "需要用 USB 线有线连接")
        fetchStock()
        XCTAssertFalse(element("custom.restore").isEnabled)
    }
}
