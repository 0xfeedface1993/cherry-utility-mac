import XCTest

/// UI-110…UI-113：其它型号（按官方驱动推断的能力）。模拟场景 `mx30s`、`nbl`、`pixiu98`、`receiver`。
@MainActor
final class MultiModelUITests: CherryUITestCase {
    /// UI-110 有线 RGB 键盘（MX BOARD 3.0S FL RGB）：没有电量和休眠，固件页说明需用官方升级程序。
    func testWiredBoardHidesBatterySleepAndFlashing() {
        launch("mx30s")
        waitForText("info.model", contains: "MX BOARD 3.0S FL RGB")
        XCTAssertEqual(text("info.vidpid"), "0x046A / 0x0079")
        XCTAssertTrue(text("info.support").contains("未经真机验证"))
        XCTAssertTrue(text("info.kind").contains("有线键盘"))
        wait(for: "info.power")
        XCTAssertFalse(element("info.battery").exists, "有线键盘不显示电量")
        XCTAssertFalse(element("info.mode").exists, "有线键盘不读工作模式")
        waitForText("info.firmwareFamily", contains: "Sonix")

        openSection("灯光与配置档")
        wait(for: "config.effect.0")
        XCTAssertFalse(element("config.sleep").exists, "有线键盘没有休眠设置")

        openSection("固件升级")
        waitForText("firmware.unsupported", contains: "Sonix")
        XCTAssertFalse(element("firmware.download").exists, "不能刷写的型号不提供下载升级包")
    }

    /// UI-111 无背光键盘（MX BOARD 3.0S FL NBL）：只能切换配置档，没有灯效与预设。
    func testNoBacklightBoardOnlySwitchesProfiles() {
        launch("nbl")
        waitForText("info.effect", contains: "无背光")
        openSection("灯光与配置档")
        wait(for: "profile.card.0")
        waitForText("profile.summary.0", contains: "无背光")
        XCTAssertFalse(element("config.effect.0").exists, "无背光键盘不显示灯效")
        XCTAssertFalse(element("config.brightness").exists)
        element("profile.activate.2").click()
        waitUntil("配置 3 应成为使用中") { !self.element("profile.activate.2").exists }
    }

    /// UI-112 PIXIU 98：B 型灯效表（彩虹雨 = 5），选择后可写入并读回。
    func testTypeBEffectTable() {
        launch("pixiu98")
        openSection("灯光与配置档")
        let rainbow = wait(for: "config.effect.5")
        XCTAssertTrue(text(of: rainbow).contains("彩虹雨"))
        reveal(rainbow)
        rainbow.click()
        wait(for: "config.effect.dirty")
        app.typeKey("s", modifierFlags: .command)
        waitUntil("写入后不再有未写入的修改", timeout: 10) { !self.element("config.effect.dirty").exists }
        XCTAssertTrue(text("config.effect.5").contains("已选中"))
    }

    /// UI-113 PIXIU 75 2.4G 接收器：显示为接收器，工作模式为无线，有电量，没有 OTA。
    func testReceiverShowsWirelessModeAndBattery() {
        launch("receiver")
        waitForText("info.model", contains: "Receiver")
        XCTAssertTrue(text("info.kind").contains("2.4G 接收器"))
        waitForText("info.mode", contains: "无线")
        XCTAssertTrue(text("info.battery").contains("64"))
        XCTAssertFalse(element("info.crc").exists, "接收器没有 OTA 接口，不读固件 CRC")
    }
}
