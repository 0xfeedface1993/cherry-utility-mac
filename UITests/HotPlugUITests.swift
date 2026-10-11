import XCTest

/// UI-70…UI-71：热插拔（「模拟设备」菜单只在模拟模式出现）。
@MainActor
final class HotPlugUITests: CherryUITestCase {
    /// UI-70 拔出后详情页提示断开、菜单栏变为未连接；插回后自动恢复并重新读取。
    func testUnplugAndReplugRecovers() {
        launch()
        waitForText("info.mode", contains: "有线")
        choose(menu: "模拟设备", item: "拔出键盘")
        wait(for: "detail.disconnected")
        openMenuBarPanel()
        wait(for: "menubar.empty")
        closeMenuBarPanel()

        choose(menu: "模拟设备", item: "插入键盘")
        waitForDisappearance(element("detail.disconnected"))
        waitForText("info.crc", contains: "0xCFE1A03E")
        openMenuBarPanel()
        waitForText("menubar.device", contains: "CHERRY MX PIXIU 75")
    }

    /// UI-71 按键测试过程中拔出：监听结束并提示；插回后自动恢复监听。
    func testKeyCaptureStopsOnUnplugAndResumes() {
        launch()
        openSection("按键测试")
        waitForText("keytest.state", contains: "正在监听")
        choose(menu: "模拟设备", item: "拔出键盘")
        waitForText("keytest.state", contains: "未监听")
        choose(menu: "模拟设备", item: "插入键盘")
        waitForText("keytest.state", contains: "正在监听")
        app.typeKey("z", modifierFlags: [])
        waitUntil("Z 应标记为已测") { self.text("key.85").contains("已测") }
    }
}
