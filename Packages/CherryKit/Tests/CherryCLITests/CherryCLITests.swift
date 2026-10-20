import ArgumentParser
import CherryControl
import Foundation
import Testing
@testable import CherryCLI

@Suite("cherry 命令行：参数与输出")
struct CherryCLITests {
    @Test func setTranslatesOptionsIntoParams() throws {
        let command = try #require(try Cherry.parseAsRoot(
            ["set", "--profile", "3", "--effect", "呼吸", "--brightness", "高", "--speed", "4", "--color", "#FF7200", "--sleep", "0", "--deep-sleep", "60", "-k", "046A:01E2@03100000"]
        ) as? SetCommand)
        #expect(command.params == ControlParams(keyboard: "046A:01E2@03100000", profile: 3, effect: "呼吸", brightness: 3, speed: 4, color: "#FF7200",
                                                sleepSeconds: 0, deepSleepMinutes: 60))
        #expect((try Cherry.parseAsRoot(["set", "--brightness", "0"]) as? SetCommand)?.params.brightness == 0)
        #expect((try Cherry.parseAsRoot(["set", "--brightness", "全亮"]) as? SetCommand)?.params.brightness == 4)
    }

    @Test func usageErrorsMapToExitCodeTwo() {
        for arguments in [["set"], ["set", "--brightness", "5"], ["set", "--brightness", "很亮"], ["profile"], ["profile", "二"], ["fly"]] {
            #expect(throws: (any Error).self, "\(arguments)") { try Cherry.parseAsRoot(arguments) }
            do {
                _ = try Cherry.parseAsRoot(arguments)
            } catch {
                #expect(Cherry.exitCode(for: error) == .validationFailure, "\(arguments)")
            }
        }
    }

    @Test func overlongArgumentsAreUsageErrors() {
        let long = String(repeating: "x", count: 65)
        for arguments in [["set", "--effect", long], ["set", "--color", long], ["status", "-k", long],
                          ["preset", "apply", String(repeating: "预", count: 257)]] {
            do {
                _ = try Cherry.parseAsRoot(arguments)
                Issue.record("应拒绝 \(arguments.prefix(2))")
            } catch {
                #expect(Cherry.exitCode(for: error) == .validationFailure, "\(arguments.prefix(2))")
                #expect(Cherry.fullMessage(for: error).contains("过长"), "\(arguments.prefix(2))")
            }
        }
        #expect(throws: Never.self) { _ = try Cherry.parseAsRoot(["preset", "apply", String(repeating: "预", count: 256)]) }
    }

    @Test func jsonErrorsCarryTheStableCode() throws {
        let unavailable = Output.json(ErrorOutput(error: CLIError.appUnavailable("CHERRY Utility 没有运行（socket：/tmp/x）").failure))
        #expect(unavailable.contains(#""code" : "appUnavailable""#) && unavailable.contains("没有运行"))
        let failure = ControlFailure(code: "ambiguousKeyboard", message: "连接了多把键盘", candidates: [
            ControlKeyboard(id: "046A:01E2@03100000", name: "CHERRY MX PIXIU 75", model: "MX PIXIU 75", transport: "USB", firmware: "0.1.1.7", configurable: true),
        ])
        let rejected = try JSONDecoder().decode([String: ControlFailure].self, from: Data(Output.json(ErrorOutput(error: CLIError.rejected(failure).failure)).utf8))
        #expect(rejected["error"] == failure)
        #expect(CLIError.failed("超时").failure.code == "clientError")
        // watch --json 的错误与事件一样是一行。
        let line = Output.jsonLine(ErrorOutput(error: CLIError.appUnavailable("CHERRY Utility 关闭了连接（可能已退出）").failure))
        #expect(!line.contains("\n") && line.hasPrefix(#"{"error":{"code":"appUnavailable""#))
    }

    @Test func subcommandsParse() throws {
        #expect((try Cherry.parseAsRoot(["profile", "2", "--json"]) as? ProfileCommand)?.profile == 2)
        #expect((try Cherry.parseAsRoot(["preset", "apply", "办公", "-p", "1"]) as? PresetCommand.Apply)?.preset == "办公")
        #expect((try Cherry.parseAsRoot(["status", "--no-launch", "--socket", "/tmp/x.sock"]) as? StatusCommand)?.connection.socket == "/tmp/x.sock")
        for name in ["keyboards", "battery", "effects", "presets", "watch", "version"] {
            #expect(throws: Never.self, "\(name)") { _ = try Cherry.parseAsRoot([name]) }
        }
    }

    @Test func findsTheEnclosingAppBundle() {
        let inside = URL(fileURLWithPath: "/Applications/CHERRY Utility.app/Contents/MacOS/cherry")
        #expect(Session.enclosingAppBundle(executable: inside)?.lastPathComponent == "CHERRY Utility.app")
        #expect(Session.enclosingAppBundle(executable: URL(fileURLWithPath: "/usr/local/bin/cherry")) == nil)
        #expect(Session.enclosingAppBundle(executable: URL(fileURLWithPath: "/tmp/build/debug/cherry")) == nil)
    }

    @Test func errorsMapToExitCodesAndCandidates() {
        #expect(CLIError(ControlClientError.unavailable).exitCode == 3)
        #expect(CLIError(ControlClientError.timeout).exitCode == 1)
        let ambiguous = CLIError.rejected(ControlFailure(code: "ambiguousKeyboard", message: "连接了多把键盘", candidates: [
            ControlKeyboard(id: "046A:01E2@03100000", name: "CHERRY MX PIXIU 75", model: "MX PIXIU 75", transport: "USB", firmware: "0.1.1.7", configurable: true),
        ]))
        #expect(ambiguous.exitCode == 4)
        #expect(ambiguous.message == "连接了多把键盘\n  046A:01E2@03100000  CHERRY MX PIXIU 75")
    }

    @Test func statusOutputMarksTheActiveProfileAndHidesMissingFields() {
        let keyboard = ControlKeyboard(id: "046A:01E2@03100000", name: "CHERRY MX PIXIU 75", model: "MX PIXIU 75", transport: "USB", firmware: "0.1.1.7", configurable: true)
        let status = ControlStatus(
            keyboard: keyboard, battery: ControlBattery(percent: 95, charging: true), connection: "有线 USB", activeProfile: 2,
            profiles: [
                ControlProfile(profile: 1, effect: "放射", brightness: 4, speed: 3, color: "#33FF33", randomColor: false, sleepSeconds: 300, deepSleepMinutes: 30),
                ControlProfile(profile: 2, effect: "波纹", brightness: 4, speed: 2, color: "#FFFFFF", randomColor: true, sleepSeconds: 0, deepSleepMinutes: 0),
                ControlProfile(profile: 3),
            ],
            summary: "CHERRY MX PIXIU 75 · 电量 95%（充电中） · 有线 USB · 固件 0.1.1.7 · 配置 2 · 波纹 · 亮度 全亮"
        )
        #expect(Output.status(ControlResult(status: status)) == """
        CHERRY MX PIXIU 75 · 电量 95%（充电中） · 有线 USB · 固件 0.1.1.7 · 配置 2 · 波纹 · 亮度 全亮

          配置 1：放射 · 亮度 4/4 · 速度 3/5 · 颜色 #33FF33 · 休眠 300 秒 · 深度休眠 30 分钟
        * 配置 2：波纹 · 亮度 4/4 · 速度 2/5 · 随机颜色 · 不休眠 · 不深度休眠
          配置 3：无背光
        """)
        #expect(Output.keyboards(ControlResult(keyboards: [])) == "没有连接受支持的 CHERRY 键盘")
        #expect(Output.keyboards(ControlResult(keyboards: [keyboard])) == "046A:01E2@03100000  CHERRY MX PIXIU 75  USB  固件 0.1.1.7")
        #expect(Output.presets(ControlResult(presets: [])) == "还没有保存灯光预设")
        #expect(Output.effects(ControlResult(keyboard: keyboard, effects: [ControlEffect(name: "呼吸", englishName: "Breathing")]))
            == "CHERRY MX PIXIU 75 的灯效：\n  呼吸（Breathing）")
    }

    @Test func jsonOutputIsSortedAndStable() {
        let json = Output.json(ControlResult(message: "已切换到配置 1", profile: ControlProfile(profile: 1, brightness: 4)))
        #expect(json == """
        {
          "message" : "已切换到配置 1",
          "profile" : {
            "brightness" : 4,
            "profile" : 1
          }
        }
        """)
        #expect(Output.jsonLine(ControlChange(keyboard: "k", activeProfile: 2, profiles: [])) == #"{"activeProfile":2,"keyboard":"k","profiles":[]}"#)
    }
}
