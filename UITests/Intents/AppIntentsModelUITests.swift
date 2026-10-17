import AppIntentsTesting
import XCTest

/// UI-128…UI-136：各型号的能力限制、权限、双键盘、键盘 ID 回退、预设实体。
@available(macOS 27.0, *)
@MainActor
final class AppIntentsModelUITests: IntentsTestCase {
    /// UI-128 无背光型号：只能切换配置档；灯光、颜色、休眠、电量都给出中文说明，状态里不支持的字段为空。
    func testNoBacklightBoard() async throws {
        start("nbl")
        try await intent { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(3)) }
        let s = try await status()
        XCTAssertEqual(try s.activeProfile as Int, 3)
        for property in ["effect", "brightness", "speed", "color", "sleepSeconds", "batteryPercent"] {
            XCTAssertTrue(isMissing(s, property), "\(property) 应为空")
        }
        XCTAssertTrue((try s.summary as String).contains("无背光"))
        let model = "MX BOARD 3.0S FL NBL"
        await expectFailure(containing: "\(model) 没有背光，不能设置灯效") { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Wave")) }
        await expectFailure(containing: "\(model) 没有背光，不能设置亮度") { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low")) }
        await expectFailure(containing: "\(model) 没有背光，不能设置亮度") { $0.intents["TurnOffBacklightIntent"].makeIntent() }
        await expectFailure(containing: "\(model) 没有背光，不能设置速度") { $0.intents["SetLightingSpeedIntent"].makeIntent(speed: $0.speed(3)) }
        await expectFailure(containing: "\(model) 不支持设置颜色") { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("red")) }
        await expectFailure(containing: "\(model) 不支持休眠设置") { $0.intents["SetSleepTimersIntent"].makeIntent(sleepSeconds: 60) }
        await expectFailure(containing: "\(model) 是有线键盘，没有电量") { $0.intents["GetBatteryIntent"].makeIntent() }
        openSection("灯光与配置档")
        wait(for: "profile.current.2")
    }

    /// UI-129 有线 RGB：没有电量和休眠，颜色可写。
    func testWiredRGBBoard() async throws {
        start("mx30s")
        await expectFailure(containing: "MX BOARD 3.0S FL RGB 是有线键盘，没有电量") { $0.intents["GetBatteryIntent"].makeIntent() }
        await expectFailure(containing: "不支持休眠设置") { $0.intents["SetSleepTimersIntent"].makeIntent(sleepSeconds: 0) }
        try await intent { $0.intents["SetLightingColorIntent"].makeIntent(color: $0.color("blue")) }
        let s = try await status()
        XCTAssertEqual(try s.color as String, "#3153FF")
        XCTAssertTrue(isMissing(s, "batteryPercent") && isMissing(s, "isCharging") && isMissing(s, "sleepSeconds"))
        XCTAssertEqual(try s.connection as String, "USB")
        XCTAssertEqual(try s.firmware as String, "0.1.3.6")
    }

    /// UI-130 PIXIU 98 的 B 型灯效表：彩虹雨 = 5、自定义 = 4；没有「对战」。
    func testTypeBEffectTable() async throws {
        start("pixiu98")
        openMenuBarPanel()
        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Rainbow Rain")) }
        let value6 = try await status()
        XCTAssertEqual(try value6.effect as String, "彩虹雨")
        waitUntil("彩虹雨选中") { self.text("menubar.effect.5").contains("已选中") }
        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Custom")) }
        waitUntil("自定义选中") { self.text("menubar.effect.4").contains("已选中") }
        await expectFailure(containing: "MX PIXIU 98 没有「对战」灯效") { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Battle")) }
    }

    /// UI-131 2.4G 接收器：无线、电量 64、休眠可写。
    func testReceiver() async throws {
        start("receiver")
        let s = try await status()
        XCTAssertEqual(try s.model as String, "MX PIXIU 75 Receiver")
        XCTAssertEqual(try s.batteryPercent as Int, 64)
        XCTAssertEqual(try s.isCharging as Bool, false)
        XCTAssertTrue((try s.connection as String).contains("无线"))
        try await intent { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(1)) }
        try await intent { $0.intents["SetSleepTimersIntent"].makeIntent(sleepSeconds: 60) }
        let after = try await status()
        XCTAssertEqual(try after.activeProfile as Int, 1)
        XCTAssertEqual(try after.sleepSeconds as Int, 60)
    }

    /// UI-132 没有「输入监控」权限：每个意图都提示去授权，键盘仍可选。
    func testInputMonitoringDenied() async throws {
        start("denied")
        await expectFailure(containing: "输入监控") { $0.intents["GetKeyboardStatusIntent"].makeIntent() }
        await expectFailure(containing: "输入监控") { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(1)) }
        await expectFailure(containing: "输入监控") { $0.intents["GetBatteryIntent"].makeIntent() }
        let suggested = try await Intents.query { try await $0.entities["KeyboardEntity"].suggestedEntities().count }
        XCTAssertEqual(suggested, 1)
    }

    /// UI-133 两把键盘：不指定时报歧义并列出两把；指定 B 只改 B；在线的两把同型号时，没见过的 ID 报未找到。
    func testDualKeyboardsStayIsolated() async throws {
        start("dual")
        let ambiguous = await expectFailure(containing: "连接了多把键盘") { $0.intents["GetBatteryIntent"].makeIntent() }
        XCTAssertTrue(ambiguous.contains("· 03100000") && ambiguous.contains("· 03200000"), ambiguous)
        try await intent { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low"), keyboard: $0.keyboard(Self.second)) }
        let value7 = try await status(keyboard: Self.second)
        XCTAssertEqual(try value7.brightness as Int, 1)
        let value8 = try await status(keyboard: Self.pixiu75)
        XCTAssertEqual(try value8.brightness as Int, 4)
        openMenuBarPanel()
        waitForText("menubar.summary", contains: "亮度 全亮")
        await expectFailure(containing: "未找到设备 046A:01E2@03990000") {
            $0.intents["GetKeyboardStatusIntent"].makeIntent(keyboard: $0.keyboard("046A:01E2@03990000"))
        }
        let resolved = try await Intents.query { try await $0.entities["KeyboardEntity"].entities(identifiers: ["046A:01E2@03990000"]).count }
        XCTAssertEqual(resolved, 1, "保存过的快捷指令引用的离线键盘仍显示为一个实体")
    }

    /// UI-134 保存过的快捷指令里的键盘换了 USB 口（这次运行没见过的 ID）：回退到唯一的同型号键盘。
    func testUnseenKeyboardIDFallsBackToTheOnlyOne() async throws {
        start()
        try await intent { $0.intents["SwitchProfileIntent"].makeIntent(profile: $0.profile(1), keyboard: $0.keyboard("046A:01E2@03990000")) }
        let value9 = try await status()
        XCTAssertEqual(try value9.activeProfile as Int, 1)
    }

    /// UI-135 预设实体：名称查询不区分大小写、重名、按 ID 解析；载入到指定配置档；已删除的预设不写入。
    func testPresetEntitiesAndStalePresets() async throws {
        let directory = try presetDirectory([
            ("A1A1A1A1-0000-4000-8000-000000000001", "Office 曲线", 482, 12, 3, "2026-01-01T00:00:00Z"),
            ("A1A1A1A1-0000-4000-8000-000000000002", "Office 曲线", 482, 12, 2, "2026-01-02T00:00:00Z"),
            ("A1A1A1A1-0000-4000-8000-000000000003", "呼吸低", 482, 2, 1, "2026-01-03T00:00:00Z"),
        ])
        start(environment: ["CHERRY_PRESET_DIR": directory.path])
        func count(_ query: String) async throws -> Int {
            try await Intents.query { try await $0.entities["PresetEntity"].entities(matching: query).count }
        }
        let value10 = try await count("office")
        XCTAssertEqual(value10, 2)
        let value11 = try await count("曲线")
        XCTAssertEqual(value11, 2)
        let value12 = try await count("不存在")
        XCTAssertEqual(value12, 0)
        let value13 = try await Intents.query { try await $0.entities["PresetEntity"].allEntities().count }
        XCTAssertEqual(value13, 3)
        let second = "A1A1A1A1-0000-4000-8000-000000000002"
        let value14 = try await Intents.query { try await $0.entities["PresetEntity"].entities(identifiers: [UUID(uuidString: second)!]).count }
        XCTAssertEqual(value14, 1)

        try await intent { $0.intents["ApplyPresetIntent"].makeIntent(preset: $0.preset(second), profile: $0.profile(1)) }
        let value15 = try await status()
        XCTAssertEqual(try value15.activeProfile as Int, 2)
        openSection("灯光与配置档")
        waitForText("profile.summary.0", contains: "曲线 · 中")

        // 已删除的预设解析不到实体，系统改为向用户要一个新的预设（快捷指令里弹出选择），测试的自动确认代理不支持，
        // 以参数 preset 的错误结束；不会写入。
        try FileManager.default.removeItem(at: directory.appending(path: "A1A1A1A1-0000-4000-8000-000000000003.cherryprofile"))
        await expectFailure(containing: "parameter 'preset'") {
            $0.intents["ApplyPresetIntent"].makeIntent(preset: $0.preset("A1A1A1A1-0000-4000-8000-000000000003"), profile: $0.profile(3))
        }
        waitForText("profile.summary.2", contains: "常亮")
    }

    /// UI-136 其他型号的预设被拒绝，不写入。
    func testPresetFromAnotherModelIsRefused() async throws {
        let directory = try presetDirectory([("B2B2B2B2-0000-4000-8000-000000000001", "98 专用", 486, 5, 4, "2026-01-01T00:00:00Z")])
        start(environment: ["CHERRY_PRESET_DIR": directory.path])
        await expectFailure(containing: "预设「98 专用」来自其他型号") {
            $0.intents["ApplyPresetIntent"].makeIntent(preset: $0.preset("B2B2B2B2-0000-4000-8000-000000000001"))
        }
        let value16 = try await status()
        XCTAssertEqual(try value16.effect as String, "波纹")
    }

    /// 在 runner 自己的临时目录（沙盒内可写）按 `.cherryprofile` 格式写入预设；App 不在沙盒里，可以读取。
    private func presetDirectory(_ presets: [(id: String, name: String, productID: Int, effect: Int, brightness: Int, createdAt: String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cherry-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for preset in presets {
            let object: [String: Any] = [
                "id": preset.id, "name": preset.name, "createdAt": preset.createdAt, "productID": preset.productID,
                "settings": ["effect": preset.effect, "brightness": preset.brightness, "speed": 2, "randomColor": false,
                             "color": ["r": 255, "g": 114, "b": 0], "sleepSeconds": 300, "deepSleepMinutes": 30],
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appending(path: "\(preset.id).cherryprofile"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
