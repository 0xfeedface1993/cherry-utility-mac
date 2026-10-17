import AppIntentsTesting
import XCTest

/// XF-03 命令行写入实时更新主窗口；意图写入与命令行写入出现在同一个 watch 里。由 `Scripts/verify-cross.sh` 驱动，
/// 没有 `CHERRY_E2E_SOCKET`（`TEST_RUNNER_CHERRY_E2E_SOCKET`）时跳过。
/// 脚本：开 watch → `cherry profile 1`（信号）→ 等 watch 以 3 结束（用例结束时 App 退出），核对 3 个事件。
@available(macOS 27.0, *)
@MainActor
final class IntentFeedUITests: IntentsTestCase {
    func testIntentWritesReachTheCommandLineFeed() async throws {
        guard let socket = ProcessInfo.processInfo.environment["CHERRY_E2E_SOCKET"], !socket.isEmpty else {
            throw XCTSkip("只由 Scripts/verify-cross.sh 运行")
        }
        start(environment: ["CHERRY_CONTROL_SOCKET": socket])
        openSection("灯光与配置档")
        wait(for: "profile.current.0", timeout: 90)
        try await intent { $0.intents["SetLightingEffectIntent"].makeIntent(effect: $0.effect("Curve"), profile: $0.profile(3)) }
        try await intent { $0.intents["SetBrightnessIntent"].makeIntent(brightness: $0.brightness("low")) }
        waitForText("profile.summary.2", contains: "曲线")
        let status = try await status()
        XCTAssertEqual(try status.activeProfile as Int, 1)
        XCTAssertEqual(try status.brightness as Int, 1)
    }
}
