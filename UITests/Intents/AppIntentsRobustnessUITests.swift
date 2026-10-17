import AppIntentsTesting
import XCTest

/// UI-137…UI-140、UI-142：慢设备上的并发、与菜单栏写入共用队列、拔插、固件刷写期间。
@available(macOS 27.0, *)
@MainActor
final class AppIntentsRobustnessUITests: IntentsTestCase {
    /// UI-137 慢设备上意图与菜单栏同时写入不同字段：经同一个合并队列，两项都生效，面板实时更新。
    func testIntentAndMenuBarWritesShareTheQueue() async throws {
        start("slow")
        let panel = openMenuBarPanel()
        waitForText("menubar.summary", contains: "配置 2 · 波纹")
        let pending = Task { try await Intents.run { $0.intents["SetLightingSpeedIntent"].makeIntent(speed: $0.speed(5)) } }
        panel.radioGroups["menubar.brightness"].radioButtons["中"].click()
        _ = try await pending.value
        waitForText("menubar.summary", contains: "亮度 中", timeout: 15)
        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Breathing")) }
        waitForText("menubar.summary", contains: "呼吸", timeout: 15)
        XCTAssertTrue(element("menubar.panel").exists, "面板全程保持打开")
        let s = try await status()
        XCTAssertEqual(try s.speed as Int, 5)
        XCTAssertEqual(try s.brightness as Int, 2)
    }

    /// UI-138 慢设备上的耗时与并发：读取 < 5 秒、写入 < 10 秒；三个意图同时写不同字段，15 秒内全部完成且都生效。
    func testConcurrentIntentsOnASlowKeyboard() async throws {
        start("slow")
        let clock = ContinuousClock()
        var read = Duration.zero
        read = try await clock.measure { _ = try await status() }
        XCTAssertLessThan(read, .seconds(5), "读取耗时 \(read)")
        let write = try await clock.measure { try await intent { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low")) } }
        XCTAssertLessThan(write, .seconds(10), "写入耗时 \(write)")
        let together = try await clock.measure {
            async let brightness = Intents.run { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("high")) }
            async let speed = Intents.run { $0.intents["SetLightingSpeedIntent"].makeIntent(speed: $0.speed(2)) }
            async let color = Intents.run { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("green")) }
            _ = try await (brightness, speed, color)
        }
        XCTAssertLessThan(together, .seconds(15), "并发写入耗时 \(together)")
        let s = try await status()
        XCTAssertEqual(try s.brightness as Int, 3)
        XCTAssertEqual(try s.speed as Int, 2)
        XCTAssertEqual(try s.color as String, "#00D70F")
        print("UI-138 读取 \(read)，写入 \(write)，三个并发 \(together)")
    }

    /// UI-139 写入进行中拔出键盘：意图报错而不挂起；拔出期间立即报没有键盘（不再冷启动等待）；插回后正常。
    func testUnplugDuringAnIntent() async throws {
        start("slow")
        let pending = Task { try await Intents.run(within: 15) { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Breathing")) } }
        try await Task.sleep(for: .milliseconds(500))
        choose(menu: "模拟设备", item: "拔出键盘")
        do {
            _ = try await pending.value
            XCTFail("拔出键盘后进行中的写入应失败")
        } catch {
            let text = describe(error)
            XCTAssertFalse(error is IntentTimeout, "意图挂起：\(text)")
            XCTAssertTrue(["断开", "未找到设备", "没有连接受支持"].contains { text.contains($0) }, text)
        }
        let clock = ContinuousClock()
        let missing = await clock.measure {
            await expectFailure(containing: "没有连接受支持的 CHERRY 键盘") { $0.intents["GetKeyboardStatusIntent"].makeIntent() }
        }
        XCTAssertLessThan(missing, .seconds(2), "拔出期间不应再等 3 秒冷启动发现")
        choose(menu: "模拟设备", item: "插入键盘")
        openSection("灯光与配置档")
        wait(for: "profile.current.1", timeout: 15)
        try await intent { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(1)) }
        wait(for: "profile.current.0", timeout: 15)
    }

    /// UI-140 两把同型号键盘拔掉一把后，按它的 ID 执行意图：报未找到，不改到另一把（B3）。
    func testUnpluggedTwinIsNotRetargeted() async throws {
        start("dual")
        let value1 = try await status(keyboard: Self.pixiu75)
        XCTAssertEqual(try value1.batteryPercent as Int, 95)
        choose(menu: "模拟设备", item: "拔出键盘")
        await expectFailure(containing: "未找到设备 046A:01E2@03100000") {
            $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low"), keyboard: $0.keyboard(Self.pixiu75))
        }
        let value2 = try await status(keyboard: Self.second)
        XCTAssertEqual(try value2.brightness as Int, 4, "另一把不应被改动")
    }

    /// UI-142 刷写固件期间：自动化的写入和读取都拒绝；刷写完成后恢复。
    func testFirmwareFlashBlocksIntents() async throws {
        start("slowflash")   // OTA 应答放慢，刷写约 5 秒；普通场景下不到 1 秒就刷完
        openSection("固件升级")
        element("firmware.download").click()
        let flash = element("firmware.flash")
        waitUntil("可以开始升级", timeout: 20) { flash.exists && flash.isEnabled }
        flash.click()
        alertButton("开始升级").click()
        waitUntil("开始传输", timeout: 10) { self.text("firmware.phase").contains("传输") }
        let failures = await withTaskGroup(of: String.self) { group in
            group.addTask { await Self.failureText { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low")) } }
            group.addTask { await Self.failureText { $0.intents["GetKeyboardStatusIntent"].makeIntent() } }
            var texts: [String] = []
            for await text in group { texts.append(text) }
            return texts
        }
        XCTAssertEqual(failures.count, 2)
        for text in failures {
            XCTAssertTrue(text.contains("这把键盘正在升级固件，请完成后再试"), "刷写期间应拒绝，实际：\(text.isEmpty ? "成功" : text)")
        }
        waitForText("firmware.phase", contains: "升级完成", timeout: 60)
        try await intent { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low")) }
        let value3 = try await status()
        XCTAssertEqual(try value3.brightness as Int, 1)
    }
}
