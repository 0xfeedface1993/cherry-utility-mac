import XCTest

/// UI-60…UI-62：固件升级（模拟云端目录 0.1.1.8 + 模拟 Telink OTA 设备，刷写后设备重启进入新版本）。
@MainActor
final class FirmwareUITests: CherryUITestCase {
    private func openFirmware(_ scenario: String = "pixiu75") {
        launch(scenario)
        openSection("固件升级")
        wait(for: "firmware.current")
    }

    /// UI-60 完整升级：下载校验 → 读取设备 CRC → 确认 → 传输进度 → 重启 → 读回 CRC 一致 → 版本更新。
    func testFullFirmwareUpgrade() {
        openFirmware()
        XCTAssertTrue(text("firmware.current").contains("0.1.1.7"))
        waitForText("firmware.latest", contains: "有新版本")
        let flash = element("firmware.flash")
        XCTAssertFalse(flash.isEnabled, "没有升级包时不能刷写")

        element("firmware.download").click()
        waitForText("firmware.package.file", contains: "MX_PIXIU75_WIRELESS_0118")
        XCTAssertTrue(text("firmware.package.target").contains("PID 0x01E2"))
        waitForText("firmware.package.deviceCRC", contains: "与升级包不同")
        XCTAssertTrue(flash.isEnabled)

        flash.click()
        alertButton("开始升级").click()
        waitForText("firmware.phase", contains: "升级完成，固件 CRC 与升级包一致", timeout: 40)
        waitForText("firmware.current", contains: "0.1.1.8", timeout: 10)
        waitForText("firmware.package.deviceCRC", contains: "与升级包相同")
        XCTAssertTrue(text("sidebar.keyboard").contains("固件 0.1.1.8"))
    }

    /// UI-61 确认框选择取消时不刷写，状态保持不变。
    func testCancellingConfirmationDoesNotFlash() {
        openFirmware()
        element("firmware.download").click()
        waitForText("firmware.package.deviceCRC", contains: "与升级包不同")
        element("firmware.flash").click()
        alertButton("取消").click()
        XCTAssertFalse(element("firmware.phase").exists && text("firmware.phase").contains("传输中"))
        XCTAssertTrue(text("firmware.current").contains("0.1.1.7"))
    }

    /// UI-62 无线连接没有 OTA 接口：下载后提示需要有线连接，刷写按钮不可用。
    func testWirelessConnectionBlocksFlashing() {
        openFirmware("wireless")
        element("firmware.download").click()
        waitForText("firmware.package.file", contains: "0118")
        let problem = wait(for: "firmware.problem")
        XCTAssertTrue(text(of: problem).contains("OTA 接口"))
        XCTAssertFalse(element("firmware.flash").isEnabled)
    }
}
