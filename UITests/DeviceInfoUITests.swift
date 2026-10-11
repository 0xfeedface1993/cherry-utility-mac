import XCTest

/// UI-10…UI-13：设备信息页。
@MainActor
final class DeviceInfoUITests: CherryUITestCase {
    /// UI-10 基本信息、电源状态、当前配置档参数和固件信息都来自私有协议读回。
    func testShowsIdentityPowerProfileAndFirmware() {
        launch()
        waitForText("info.model", contains: "MX PIXIU 75")
        XCTAssertEqual(text("info.vidpid"), "0x046A / 0x01E2")
        XCTAssertTrue(text("info.firmware").contains("0.1.1.7"))
        XCTAssertTrue(text("info.connection").contains("USB"))

        waitForText("info.mode", contains: "有线 USB")
        XCTAssertTrue(text("info.battery").contains("95") || text("info.battery").contains("0.95"))
        XCTAssertTrue(text("info.activeProfile").contains("配置 2（共 3 个）"))

        XCTAssertTrue(text("info.effect").contains("波纹"))
        XCTAssertTrue(text("info.effect").contains("速度 2 / 5"))
        XCTAssertTrue(text("info.brightness").contains("全亮"))
        XCTAssertTrue(text("info.color").contains("随机颜色"))
        XCTAssertTrue(text("info.sleep").contains("300 秒"))
        XCTAssertTrue(text("info.deepSleep").contains("30 分钟"))
        XCTAssertTrue(text("info.polling").contains("对应频率未确认"))
        XCTAssertTrue(text("info.keyLocks").contains("无"))

        waitForText("info.crc", contains: "0xCFE1A03E")
        waitForText("info.latest", contains: "0.1.1.8")
        XCTAssertTrue(text("info.latest").contains("可升级"))
    }

    /// UI-11 原始数据展开后列出 3 个配置档块的十六进制内容。
    func testRawDataShowsAllProfileBlocks() {
        launch()
        waitForText("info.mode", contains: "有线")
        let toggle = wait(for: "info.raw.toggle")
        XCTAssertTrue(text(of: toggle).contains("已收起"))
        reveal(toggle)
        toggle.click()
        waitUntil("原始数据应展开") { self.text(of: toggle).contains("已展开") }
        wait(for: "info.raw.content")
        waitForAnything(containing: "0x1A 电量")
        for n in 1...3 {
            waitForAnything(containing: "0x05 配置档 \(n)")
        }
        waitForAnything(containing: "0x1D 设备信息")
    }

    /// UI-12 工具栏刷新（⌘R）重新读取后数据保持一致。
    func testRefreshRereadsDevice() {
        launch()
        waitForText("info.crc", contains: "0xCFE1A03E")
        element("info.refresh").click()
        waitForText("info.crc", contains: "0xCFE1A03E")
        app.typeKey("r", modifierFlags: .command)
        waitForText("info.activeProfile", contains: "配置 2")
    }

    /// UI-13 无线连接：工作模式显示无线，低电量，固件区提示需要有线。
    func testWirelessScenarioShowsWirelessModeAndLowBattery() {
        launch("wireless")
        waitForText("info.mode", contains: "无线")
        XCTAssertTrue(text("info.battery").contains("15") || text("info.battery").contains("0.15"))
        XCTAssertTrue(text("info.connection").contains("Bluetooth"))
    }
}
