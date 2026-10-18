import CherryControl
import CherryCore
import CherrySimulation
import Foundation
import Synchronization
import Testing
@testable import CherryControlService

@Suite("控制服务：模拟键盘集成", .serialized)
struct ControlServiceTests {
    final class MemoryPresets: ProfilePresetStore, Sendable {
        private let items = Mutex<[ProfilePreset]>([])
        func presets() async throws -> [ProfilePreset] { items.withLock { $0 } }
        func save(_ preset: ProfilePreset) async throws { items.withLock { $0.insert(preset, at: 0) } }
        func delete(id: UUID) async throws { items.withLock { $0.removeAll { $0.id == id } } }
    }

    struct Stack {
        let service: ControlService
        let automation: KeyboardAutomation
        let presets: PresetLibrary
        let hub: SimulatedKeyboardHub
    }

    static func stack(_ scenario: String = "pixiu75") -> Stack {
        let hub = SimulatedKeyboardHub(scenario: .named(scenario))
        let services = CoreServices(discovery: hub, channels: hub, catalog: SimulatedFirmwareCatalog(), downloader: SimulatedFirmwareCatalog())
        let presets = PresetLibrary(store: MemoryPresets())
        let automation = services.automation(presets: presets, timing: .init(discoveryTimeout: .milliseconds(50), settle: .zero, poll: .milliseconds(10)))
        return Stack(service: ControlService(automation: automation, appVersion: "1.2.0", build: "4"), automation: automation, presets: presets, hub: hub)
    }

    /// 调用一次并取回唯一的响应。
    static func call(_ service: ControlService, _ method: ControlMethod, _ params: ControlParams? = nil) async -> ControlResponse {
        let responses = Mutex<[ControlResponse]>([])
        let collect: @Sendable (ControlResponse) -> Void = { response in responses.withLock { $0.append(response) } }
        await service.handle(ControlRequest(id: 1, method: method, params: params), reply: collect)
        let collected = responses.withLock { $0 }
        #expect(collected.count == 1)
        return collected[0]
    }

    @Test func statusUsesInterfaceUnits() async throws {
        let s = Self.stack()
        let response = await Self.call(s.service, .status)
        let status = try #require(response.result?.status)
        #expect(response.ok && response.result?.message == status.summary)
        #expect(status.keyboard.id == "046A:01E2@03100000" && status.keyboard.name == "CHERRY MX PIXIU 75" && status.keyboard.configurable)
        #expect(status.battery == ControlBattery(percent: 95, charging: true))
        #expect(status.activeProfile == 2 && status.connection == "有线 USB")
        let profiles = try #require(status.profiles)
        #expect(profiles.map(\.profile) == [1, 2, 3])
        #expect(profiles[1] == ControlProfile(profile: 2, effect: "波纹", effectEnglishName: "Wave", brightness: 4, speed: 2, color: "#FFFFFF",
                                               randomColor: true, sleepSeconds: 300, deepSleepMinutes: 30))
    }

    @Test func writesTranslateProfileAndSpeedNumbers() async throws {
        let s = Self.stack()
        let activated = await Self.call(s.service, .activateProfile, ControlParams(profile: 1))
        #expect(activated.result?.message == "已切换到配置 1（放射 · 亮度 全亮）")
        #expect(activated.result?.profile?.profile == 1)
        let updated = await Self.call(s.service, .update, ControlParams(effect: "Breathing", brightness: 2, speed: 5, color: "#00D70F"))
        #expect(updated.result?.message == "已更新配置 1：灯效 呼吸，亮度 中，速度 5 / 5，颜色 #00D70F")
        #expect(updated.result?.profile == ControlProfile(profile: 1, effect: "呼吸", effectEnglishName: "Breathing", brightness: 2, speed: 5,
                                                          color: "#00D70F", randomColor: false, sleepSeconds: 300, deepSleepMinutes: 30))
        let random = await Self.call(s.service, .update, ControlParams(profile: 3, color: "random"))
        #expect(random.result?.profile?.profile == 3 && random.result?.profile?.randomColor == true)
        #expect(try await s.automation.status(of: nil).snapshot?.configuration.activeProfile == 0)
    }

    @Test func failuresCarryStableCodesAndChineseMessages() async throws {
        let s = Self.stack()
        let badID = await Self.call(s.service, .status, ControlParams(keyboard: "PIXIU"))
        #expect(badID.error?.code == "invalidArgument" && badID.error?.message.contains("046A:01E2@03100000") == true)
        let missing = await Self.call(s.service, .activateProfile)
        #expect(missing.error == ControlFailure(code: "invalidArgument", message: "缺少参数 profile"))
        let range = await Self.call(s.service, .activateProfile, ControlParams(profile: 4))
        #expect(range.error == ControlFailure(code: "invalidArgument", message: "MX PIXIU 75 只有 3 个配置档，没有配置 4"))
        let speed = await Self.call(s.service, .update, ControlParams(speed: 0))
        #expect(speed.error?.message == "速度须为 1–5，收到 0")
        let color = await Self.call(s.service, .update, ControlParams(color: "orange"))
        #expect(color.error?.code == "invalidArgument" && color.error?.message.contains("#RRGGBB") == true)
        let effect = await Self.call(s.service, .update, ControlParams(effect: "彩虹雨"))
        #expect(effect.error?.code == "unknownEffect")
        let nothing = await Self.call(s.service, .update, ControlParams())
        #expect(nothing.error?.code == "nothingToChange")
        let stranger = await Self.call(s.service, .status, ControlParams(keyboard: "046A:0079@00000001"))
        #expect(stranger.error?.code == "keyboardNotFound")

        let dual = await Self.call(Self.stack("dual").service, .activateProfile, ControlParams(profile: 1))
        #expect(dual.error?.code == "ambiguousKeyboard")
        #expect(dual.error?.candidates?.map(\.id) == ["046A:01E2@03100000", "046A:01E2@03200000"])
        let nbl = await Self.call(Self.stack("nbl").service, .update, ControlParams(brightness: 1))
        #expect(nbl.error == ControlFailure(code: "unsupportedSetting", message: "MX BOARD 3.0S FL NBL 没有背光，不能设置亮度"))
        let wired = await Self.call(Self.stack("mx30s").service, .battery)
        #expect(wired.error?.code == "noBattery")
        let none = await Self.call(Self.stack("empty").service, .status)
        #expect(none.error == ControlFailure(code: "noKeyboard", message: "没有连接受支持的 CHERRY 键盘"))
        let denied = await Self.call(Self.stack("denied").service, .status)
        #expect(denied.error?.code == "accessDenied")
    }

    /// 线上的极端值不能让 App 在减 1 时溢出崩溃。
    @Test func extremeNumbersAreRejectedWithoutCrashing() async throws {
        let s = Self.stack()
        for params in [ControlParams(profile: Int.min), ControlParams(speed: Int.min), ControlParams(profile: Int.min, speed: Int.min)] {
            let method: ControlMethod = params.speed == nil ? .activateProfile : .update
            let response = await Self.call(s.service, method, params)
            #expect(response.error?.code == "invalidArgument", "\(params)")
            #expect(response.error?.message.contains("-9223372036854775808") == true, "\(params)")
        }
        let preset = await Self.call(s.service, .applyPreset, ControlParams(profile: Int.min, preset: "x"))
        #expect(preset.error?.code == "presetNotFound" || preset.error?.code == "invalidArgument")
        let huge = await Self.call(s.service, .activateProfile, ControlParams(profile: Int.max))
        #expect(huge.error == ControlFailure(code: "invalidArgument", message: "MX PIXIU 75 只有 3 个配置档，没有配置 9223372036854775807"))
        let fast = await Self.call(s.service, .update, ControlParams(speed: Int.max))
        #expect(fast.error?.message == "速度须为 1–5，收到 9223372036854775807")
        #expect(await Self.call(s.service, .status).ok)
    }

    @Test func modelCapabilitiesShapeTheProfiles() async throws {
        let nbl = try #require(await Self.call(Self.stack("nbl").service, .status).result?.status?.profiles?.first)
        #expect(nbl == ControlProfile(profile: 1))
        let wired = try #require(await Self.call(Self.stack("mx30s").service, .status).result?.status)
        #expect(wired.battery == nil && wired.profiles?.first?.sleepSeconds == nil && wired.profiles?.first?.color != nil)
        let effects = await Self.call(Self.stack("pixiu98").service, .effects)
        #expect(effects.result?.effects?.contains(ControlEffect(name: "彩虹雨", englishName: "Rainbow Rain")) == true)
        #expect(effects.result?.keyboard?.model == "MX PIXIU 98")
    }

    @Test func presetsAreFoundByNameOrID() async throws {
        let s = Self.stack()
        let keyboard = try await s.automation.keyboard(nil)
        let settings = ProfileSettings(effect: 12, brightness: 3, speed: 1, randomColor: false, color: .white, sleepSeconds: 60, deepSleepMinutes: 30)
        let office = try await s.presets.save(name: "办公", settings: settings, from: keyboard)
        let listed = await Self.call(s.service, .presets)
        #expect(listed.result?.presets?.map(\.name) == ["办公"] && listed.result?.presets?.first?.model == "MX PIXIU 75")
        let byName = await Self.call(s.service, .applyPreset, ControlParams(profile: 3, preset: "办公"))
        #expect(byName.result?.message == "已把预设「办公」载入配置 3（曲线 · 亮度 高）")
        let byID = await Self.call(s.service, .applyPreset, ControlParams(preset: office.id.uuidString))
        #expect(byID.result?.profile?.profile == 2)
        let missing = await Self.call(s.service, .applyPreset, ControlParams(preset: "游戏"))
        #expect(missing.error == ControlFailure(code: "presetNotFound", message: "没有名为「游戏」的预设"))
        _ = try await s.presets.save(name: "办公", settings: settings, from: keyboard)
        let twice = await Self.call(s.service, .applyPreset, ControlParams(preset: "办公"))
        #expect(twice.error?.code == "ambiguousPreset")
    }

    @Test func versionKeyboardsAndPing() async throws {
        let s = Self.stack("dual")
        #expect(await Self.call(s.service, .ping).result?.message == "pong")
        #expect(await Self.call(s.service, .version).result?.version == ControlVersion(app: "1.2.0", build: "4", protocolVersion: 1))
        #expect(await Self.call(s.service, .keyboards).result?.keyboards?.count == 2)
    }

    /// 「设置 › 自动化」的开关：被关掉的入口拒绝（ping / version 除外），另一个入口照常；每次调用都记下来。
    @Test func entrySwitchesGateRequestsAndCallsAreRecorded() async throws {
        let s = Self.stack()
        let preferences = InMemoryAutomationPreferences()
        let activity = InMemoryAutomationActivity()
        let entries = AutomationEntries(
            preferences: preferences, activity: activity, signals: ProcessLocalSignals(),
            installer: NoCommandLineToolInstaller(), registry: NoMCPClientRegistry(), route: .viaApp
        )
        let service = ControlService(automation: s.automation, entries: entries, appVersion: "1.2.0", build: "4")
        func call(_ method: ControlMethod, _ client: String?) async -> ControlResponse {
            let responses = Mutex<[ControlResponse]>([])
            await service.handle(ControlRequest(id: 1, method: method, client: client)) { response in responses.withLock { $0.append(response) } }
            return responses.withLock { $0[0] }
        }
        preferences.setEnabled(.mcp, false)
        let refused = await call(.status, ControlClientKind.mcp)
        #expect(refused.ok == false && refused.error?.code == "automationDisabled")
        #expect(refused.error?.message == "MCP 控制已在 CHERRY Utility 的「设置 › 自动化」里关闭")
        #expect(await call(.ping, ControlClientKind.mcp).ok)
        #expect(await call(.version, ControlClientKind.mcp).ok)
        #expect(await call(.status, ControlClientKind.commandLine).ok)
        #expect(await call(.status, nil).ok, "旧版 cherry 不带来源，按命令行处理")
        preferences.setEnabled(.commandLine, false)
        #expect(await call(.keyboards, nil).error?.message == "命令行控制已在 CHERRY Utility 的「设置 › 自动化」里关闭")

        let recorded = activity.load()
        #expect(recorded.mcp.count == 1 && recorded.mcp.lastCall?.succeeded == false && recorded.mcp.lastCall?.operation == "status")
        #expect(recorded.commandLine.count == 3 && recorded.commandLine.lastCall?.operation == "keyboards")
        #expect(recorded.commandLine.lastCall?.route == .viaApp)
    }

    /// 监听中途关掉入口：下一个事件前回一条失败并结束。
    @Test func watchEndsWhenItsEntryIsSwitchedOff() async throws {
        let s = Self.stack()
        let preferences = InMemoryAutomationPreferences()
        let entries = AutomationEntries(
            preferences: preferences, activity: InMemoryAutomationActivity(), signals: ProcessLocalSignals(),
            installer: NoCommandLineToolInstaller(), registry: NoMCPClientRegistry(), route: .viaApp
        )
        let service = ControlService(automation: s.automation, entries: entries, appVersion: "1.2.0", build: "4")
        let (events, continuation) = AsyncStream.makeStream(of: ControlResponse.self)
        let watcher = Task {
            await service.handle(ControlRequest(id: 9, method: .watch, client: ControlClientKind.mcp)) { continuation.yield($0) }
            continuation.finish()
        }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next()?.result?.message?.hasPrefix("开始监听") == true)
        _ = try await s.automation.activate(profile: 0, on: nil)
        #expect(await iterator.next()?.result?.change != nil)
        preferences.setEnabled(.mcp, false)
        _ = try await s.automation.activate(profile: 1, on: nil)
        #expect(await iterator.next()?.error?.code == "automationDisabled")
        #expect(await iterator.next() == nil)
        await watcher.value
    }

    @Test func watchStreamsAutomationWritesUntilCancelled() async throws {
        let s = Self.stack()
        let (events, continuation) = AsyncStream.makeStream(of: ControlResponse.self)
        let watcher = Task {
            await s.service.handle(ControlRequest(id: 9, method: .watch)) { continuation.yield($0) }
            continuation.finish()
        }
        var iterator = events.makeAsyncIterator()
        let ack = try #require(await iterator.next())
        #expect(ack.id == 9 && ack.ok && ack.result?.change == nil)
        _ = await Self.call(s.service, .activateProfile, ControlParams(profile: 3))
        let change = try #require(await iterator.next()?.result?.change)
        #expect(change.keyboard == "046A:01E2@03100000" && change.activeProfile == 3 && change.profiles.count == 3)
        watcher.cancel()
        #expect(await iterator.next() == nil)
    }

    @Test func endToEndOverTheSocket() async throws {
        let s = Self.stack()
        let directory = URL(fileURLWithPath: "/tmp/cherry-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "c.sock").path(percentEncoded: false)
        let service = s.service
        let server = ControlSocketServer(path: path) { request, reply in await service.handle(request, reply: reply) }
        try server.start()
        defer { server.stop() }
        let (status, switched) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    let client = try ControlClient.connect(path: path)
                    return (try client.call(.status), try client.call(.activateProfile, ControlParams(profile: 1)))
                })
            }
        }
        #expect(status.result?.status?.activeProfile == 2)
        #expect(switched.ok && switched.result?.message?.hasPrefix("已切换到配置 1") == true)
        #expect(try await s.automation.status(of: nil).snapshot?.configuration.activeProfile == 0)
    }
}
