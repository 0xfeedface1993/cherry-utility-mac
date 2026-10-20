import CherryControl
import CherryControlService
import CherryCore
import CherrySimulation
import Foundation
import Logging
import MCP
import Synchronization
import Testing
@testable import CherryCLI

extension Value {
    /// 测试用：按键名逐层取对象成员。
    func at(_ keys: String...) -> Value? {
        keys.reduce(Optional(self)) { $0?.objectValue?[$1] }
    }
}

/// 让 `@Sendable` 闭包共享的可变状态（`Mutex` 不能被逃逸闭包直接捕获）。
final class Locked<T: Sendable>: Sendable {
    private let state: Mutex<T>
    init(_ value: T) { state = Mutex(value) }
    var value: T { state.withLock { $0 } }
    func update(_ body: (inout T) -> Void) { state.withLock { body(&$0) } }
}

extension CallTool.Result {
    var texts: [String] {
        content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
    }
}

@Suite("cherry mcp：工具目录与参数")
struct CherryMCPToolTests {
    @Test func catalogListsNineToolsWithHonestAnnotations() {
        let tools = CherryTool.allCases.map(\.definition)
        #expect(tools.map(\.name) == [
            "list_keyboards", "get_status", "get_battery", "list_lighting_effects", "list_presets",
            "switch_profile", "set_lighting", "set_sleep_timers", "apply_preset",
        ])
        #expect(!tools.contains { $0.name.contains("firmware") || $0.name.contains("flash") || $0.name.contains("update") })
        for tool in tools {
            let a = tool.annotations
            #expect(tool.title != nil && tool.description?.isEmpty == false && a.openWorldHint == false, "\(tool.name)")
            switch tool.name {
            case "list_keyboards", "get_status", "get_battery", "list_lighting_effects", "list_presets":
                #expect(a.readOnlyHint == true && a.idempotentHint == true && a.destructiveHint == false, "\(tool.name)")
            case "switch_profile", "set_lighting", "set_sleep_timers":
                #expect(a.readOnlyHint == false && a.idempotentHint == true && a.destructiveHint == false, "\(tool.name)")
            default:
                #expect(tool.name == "apply_preset" && a.readOnlyHint == false && a.destructiveHint == true, "\(tool.name)")
            }
        }
    }

    @Test func schemasAreClosedObjectsWithoutTopLevelCombinators() throws {
        for tool in CherryTool.allCases.map(\.definition) {
            let schema = try #require(tool.inputSchema.objectValue)
            #expect(schema["type"] == "object" && schema["additionalProperties"] == false, "\(tool.name)")
            // Claude 的工具 schema 不接受顶层 anyOf / oneOf / allOf。
            #expect(schema["anyOf"] == nil && schema["oneOf"] == nil && schema["allOf"] == nil, "\(tool.name)")
            #expect(schema["properties"]?.objectValue != nil, "\(tool.name)")
        }
        let required = Dictionary(uniqueKeysWithValues: CherryTool.allCases.map { ($0.rawValue, $0.inputSchema.at("required")) })
        #expect(required["switch_profile"] == ["profile"] && required["apply_preset"] == ["preset"])
        #expect(required["set_lighting"] == .some(nil) && required["get_status"] == .some(nil))
        #expect(CherryTool.listKeyboards.inputSchema.at("properties") == [:])

        let lighting = CherryTool.setLighting.inputSchema
        #expect(lighting.at("properties", "profile") == ["type": "integer", "minimum": 1, "maximum": 3, "description": "配置档编号，1 起。不填时为当前配置档。"])
        #expect(lighting.at("properties", "brightness", "minimum") == 0 && lighting.at("properties", "brightness", "maximum") == 4)
        #expect(lighting.at("properties", "speed", "minimum") == 1 && lighting.at("properties", "speed", "maximum") == 5)
        #expect(lighting.at("properties", "color", "pattern") == "^#[0-9A-Fa-f]{6}$|^random$")
        let sleep = CherryTool.setSleepTimers.inputSchema.at("properties")?.objectValue?.keys.sorted()
        #expect(sleep == ["deep_sleep_minutes", "keyboard", "profile", "sleep_seconds"])
    }

    /// 命令行不依赖 CherryCore，灯效名单独写了一份；新增型号带来新灯效时这里会提醒同步。
    @Test func effectEnumMatchesTheModelCatalog() throws {
        let catalog = KeyboardModel.allLightingEffects
        #expect(LightingEffectNames.all.map(\.english) == catalog.map(\.englishName))
        #expect(LightingEffectNames.all.map(\.chinese) == catalog.map(\.name))
        let values = try #require(CherryTool.setLighting.inputSchema.at("properties", "effect", "enum")?.arrayValue)
        #expect(values.compactMap(\.stringValue) == catalog.map(\.englishName) && values.count == 16)
        let description = try #require(CherryTool.setLighting.inputSchema.at("properties", "effect", "description")?.stringValue)
        #expect(description.contains("Breathing=呼吸") && description.contains("Rainbow Rain=彩虹雨"))
    }

    @Test func argumentsBecomeControlParams() throws {
        #expect(try CherryTool.setLighting.params(from: [
            "effect": "Breathing", "brightness": 2, "speed": .double(5), "color": "#FF7200", "profile": "3", "keyboard": "046A:01E2@03100000",
        ]) == ControlParams(keyboard: "046A:01E2@03100000", profile: 3, effect: "Breathing", brightness: 2, speed: 5, color: "#FF7200"))
        #expect(try CherryTool.setSleepTimers.params(from: ["sleep_seconds": 0, "deep_sleep_minutes": .null])
            == ControlParams(sleepSeconds: 0))
        #expect(try CherryTool.switchProfile.params(from: ["profile": 1]) == ControlParams(profile: 1))
        #expect(try CherryTool.applyPreset.params(from: ["preset": "办公"]) == ControlParams(preset: "办公"))
        #expect(try CherryTool.getStatus.params(from: nil) == ControlParams())
        #expect(CherryTool.setSleepTimers.method == .update && CherryTool.switchProfile.method == .activateProfile)
    }

    @Test func badArgumentsAreExplained() {
        let cases: [(CherryTool, [String: Value], String)] = [
            (.setLighting, ["profile": 2], "至少指定一项：effect、brightness、speed 或 color"),
            (.setSleepTimers, [:], "至少指定一项：sleep_seconds 或 deep_sleep_minutes"),
            (.switchProfile, [:], "缺少参数 profile"),
            (.applyPreset, ["profile": 1], "缺少参数 preset"),
            (.setLighting, ["brightness": "高"], "参数 brightness 应为整数"),
            (.setLighting, ["speed": .double(2.5)], "参数 speed 应为整数"),
            (.setLighting, ["effect": 3], "参数 effect 应为字符串"),
            (.setSleepTimers, ["sleepSeconds": 0], "未知参数 sleepSeconds；可用的参数：sleep_seconds、deep_sleep_minutes、profile、keyboard"),
            (.listPresets, ["keyboard": "x"], "未知参数 keyboard；这个工具没有参数"),
            // 超长字符串在 MCP 层就说明，不会因超出控制协议的一行而变成「App 没有运行」。
            (.applyPreset, ["preset": .string(String(repeating: "x", count: 70_000))], "参数 preset 过长（70000 个字符，最多 256 个）"),
            (.setLighting, ["effect": .string(String(repeating: "x", count: 65))], "参数 effect 过长（65 个字符，最多 64 个）"),
            (.getStatus, ["keyboard": .string(String(repeating: "0", count: 65))], "参数 keyboard 过长（65 个字符，最多 64 个）"),
        ]
        for (tool, arguments, message) in cases {
            #expect(throws: ToolInputError(message), "\(tool.rawValue) \(arguments)") { try tool.params(from: arguments) }
        }
    }

    @Test func resultsCarryChineseTextAndStructuredJSON() async throws {
        let keyboard = ControlKeyboard(id: "046A:01E2@03100000", name: "CHERRY MX PIXIU 75", model: "MX PIXIU 75", transport: "USB", firmware: "0.1.1.7", configurable: true)
        let calls = Locked<[ControlParams]>([])
        let backend = MCPBackend { method, params in
            calls.update { $0.append(params) }
            switch method {
            case .keyboards: return ControlResult(keyboards: [keyboard])
            case .activateProfile: return ControlResult(message: "已切换到配置 1（放射 · 亮度 全亮）", profile: ControlProfile(profile: 1, brightness: 4))
            case .battery: throw CLIError.rejected(ControlFailure(code: "noBattery", message: "MX 3.0S 是有线键盘，没有电池"))
            default: throw CLIError.appUnavailable("CHERRY Utility 没有运行")
            }
        }

        let listed = try await CherryMCP.call(CallTool.Parameters(name: "list_keyboards"), backend: backend)
        #expect(listed.isError == nil && listed.texts == [
            "046A:01E2@03100000  CHERRY MX PIXIU 75  USB  固件 0.1.1.7",
            #"{"keyboards":[{"configurable":true,"firmware":"0.1.1.7","id":"046A:01E2@03100000","model":"MX PIXIU 75","name":"CHERRY MX PIXIU 75","transport":"USB"}]}"#,
        ])
        #expect(listed.structuredContent?.at("keyboards")?.arrayValue?.first?.at("id") == "046A:01E2@03100000")

        let switched = try await CherryMCP.call(CallTool.Parameters(name: "switch_profile", arguments: ["profile": 1]), backend: backend)
        #expect(switched.texts.first == "已切换到配置 1（放射 · 亮度 全亮）" && switched.structuredContent?.at("profile", "profile") == 1)

        let rejected = try await CherryMCP.call(CallTool.Parameters(name: "get_battery"), backend: backend)
        #expect(rejected.isError == true && rejected.texts.first == "MX 3.0S 是有线键盘，没有电池")
        #expect(rejected.structuredContent == ["error": ["code": "noBattery", "message": "MX 3.0S 是有线键盘，没有电池"]])

        let unavailable = try await CherryMCP.call(CallTool.Parameters(name: "get_status"), backend: backend)
        #expect(unavailable.isError == true && unavailable.structuredContent?.at("error", "code") == "appUnavailable")

        let invalid = try await CherryMCP.call(CallTool.Parameters(name: "switch_profile", arguments: ["profile": "二"]), backend: backend)
        #expect(invalid.isError == true && invalid.structuredContent?.at("error", "code") == "invalidArgument")
        #expect(calls.value.count == 4, "参数不合要求时不调用 App")

        await #expect(throws: MCPError.invalidParams("未知工具 flash_firmware")) {
            try await CherryMCP.call(CallTool.Parameters(name: "flash_firmware"), backend: backend)
        }
    }

    @Test func offloadReturnsPromptlyWhenCancelled() async throws {
        let finished = Locked(false)
        let call = Task {
            try await offload {
                usleep(400_000)
                finished.update { $0 = true }
                return 1
            }
        }
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(20))
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - start < .milliseconds(300))
        #expect(!finished.value, "阻塞调用仍在 GCD 线程上运行，结果被丢弃")

        #expect(try await offload { 42 } == 42)
        await #expect(throws: CLIError.failed("x")) { try await offload { () throws -> Int in throw CLIError.failed("x") } }
        let cancelledFirst = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await offload { 7 }
        }
        await #expect(throws: CancellationError.self) { try await cancelledFirst.value }
    }

    @Test func mcpSubcommandParsesConnectionOptions() throws {
        let command = try #require(try Cherry.parseAsRoot(["mcp", "--no-launch", "--socket", "/tmp/x.sock"]) as? MCPCommand)
        #expect(command.connection.socket == "/tmp/x.sock" && command.connection.noLaunch)
        #expect(throws: (any Error).self) { try Cherry.parseAsRoot(["mcp", "--json"]) }
    }

    @Test func versionComesFromTheEnclosingApp() throws {
        let directory = URL(fileURLWithPath: "/tmp/cherry-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appending(path: "CHERRY Utility.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "online.odeployer.CherryUtility.test", "CFBundleShortVersionString": "9.8.7"], format: .xml, options: 0
        )
        try plist.write(to: contents.appending(path: "Info.plist"))
        #expect(CherryMCP.version(executable: contents.appending(path: "MacOS/cherry")) == "9.8.7")
        #expect(CherryMCP.version(executable: URL(fileURLWithPath: "/tmp/build/debug/cherry")) == "dev")
    }
}

/// MCP 客户端 → `cherry mcp` 的服务（InMemoryTransport）→ 控制 socket → `ControlService` → 模拟键盘，全程走真实代码。
@Suite("cherry mcp：经 socket 的端到端", .serialized)
struct CherryMCPIntegrationTests {
    final class MemoryPresets: ProfilePresetStore, Sendable {
        private let items = Mutex<[ProfilePreset]>([])
        func presets() async throws -> [ProfilePreset] { items.withLock { $0 } }
        func save(_ preset: ProfilePreset) async throws { items.withLock { $0.insert(preset, at: 0) } }
        func delete(id: UUID) async throws { items.withLock { $0.removeAll { $0.id == id } } }
    }

    @Test func initializeListAndCallToolsOverTheSocket() async throws {
        let hub = SimulatedKeyboardHub(scenario: .named("pixiu75"))
        let services = CoreServices(discovery: hub, channels: hub, catalog: SimulatedFirmwareCatalog(), downloader: SimulatedFirmwareCatalog())
        let presets = PresetLibrary(store: MemoryPresets())
        let automation = services.automation(presets: presets, timing: .init(discoveryTimeout: .milliseconds(50), settle: .zero, poll: .milliseconds(10)))
        let service = ControlService(automation: automation, appVersion: "1.2.0", build: "4")

        // socket 放在 /tmp 下的独立目录：`sun_path` 只有 104 字节，`$TMPDIR` 又会被定期清理。
        let directory = URL(fileURLWithPath: "/tmp/cherry-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "c.sock").path(percentEncoded: false)
        let socketServer = ControlSocketServer(path: path) { request, reply in await service.handle(request, reply: reply) }
        try socketServer.start()
        defer { socketServer.stop() }

        let server = await CherryMCP.server(version: "1.2.0", backend: .routed(try ConnectionOptions.parse(["--socket", path]), environment: [:]))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "cherry-tests", version: "1")
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.serverInfo.name == "cherry-utility" && initialized.serverInfo.version == "1.2.0")
        #expect(initialized.capabilities.tools != nil && initialized.instructions?.contains("不提供固件操作") == true)

        let tools = try await client.listTools().tools
        #expect(tools.count == 9 && tools.first { $0.name == "apply_preset" }?.annotations.destructiveHint == true)

        func call(_ name: String, _ arguments: [String: Value]? = nil) async throws -> CallTool.Result {
            try await client.send(CallTool.request(.init(name: name, arguments: arguments))).value
        }

        let status = try await call("get_status")
        #expect(status.isError == nil && status.texts.first?.contains("* 配置 2：波纹") == true)
        #expect(status.structuredContent?.at("status", "activeProfile") == 2 && status.structuredContent?.at("message") != nil)

        let switched = try await call("switch_profile", ["profile": 1])
        #expect(switched.texts.first == "已切换到配置 1（放射 · 亮度 全亮）")
        #expect(try await automation.status(of: nil).snapshot?.configuration.activeProfile == 0)

        let lighting = try await call("set_lighting", ["effect": "Breathing", "brightness": 2])
        #expect(lighting.texts.first == "已更新配置 1：灯效 呼吸，亮度 中")
        #expect(lighting.structuredContent?.at("profile", "effectEnglishName") == "Breathing")

        let sleep = try await call("set_sleep_timers", ["profile": 3, "sleep_seconds": 0])
        #expect(sleep.isError == nil && sleep.structuredContent?.at("profile", "sleepSeconds") == 0)

        let unknownEffect = try await call("set_lighting", ["effect": "Rainbow Rain"])
        #expect(unknownEffect.isError == true && unknownEffect.structuredContent?.at("error", "code") == "unknownEffect")
        let outOfRange = try await call("switch_profile", ["profile": 4])
        #expect(outOfRange.isError == true && outOfRange.texts.first == "MX PIXIU 75 只有 3 个配置档，没有配置 4")

        let battery = try await call("get_battery")
        #expect(battery.structuredContent?.at("battery", "percent") == 95)
        let effects = try await call("list_lighting_effects")
        #expect(effects.texts.first?.hasPrefix("CHERRY MX PIXIU 75 的灯效：") == true && effects.structuredContent?.at("effects")?.arrayValue?.count == 11)
        let keyboards = try await call("list_keyboards")
        #expect(keyboards.structuredContent?.at("keyboards")?.arrayValue?.count == 1)

        #expect(try await call("list_presets").texts.first == "还没有保存灯光预设")
        let missing = try await call("apply_preset", ["preset": "办公"])
        #expect(missing.isError == true && missing.texts.first == "没有名为「办公」的预设")
        let settings = ProfileSettings(effect: 12, brightness: 3, speed: 1, randomColor: false, color: .white, sleepSeconds: 60, deepSleepMinutes: 30)
        _ = try await presets.save(name: "办公", settings: settings, from: try await automation.keyboard(nil))
        let applied = try await call("apply_preset", ["preset": "办公", "profile": 3])
        #expect(applied.texts.first == "已把预设「办公」载入配置 3（曲线 · 亮度 高）")

        await client.disconnect()
        await server.stop()
    }
}


/// 测试用传输：消息由测试喂入，`finish()` 模拟标准输入 EOF；记录服务端发出的每条消息。
actor ScriptedTransport: Transport {
    nonisolated let logger = Logger(label: "cherry.tests.transport")
    private let (incoming, feed) = AsyncThrowingStream.makeStream(of: Data.self)
    private(set) var sent: [Data] = []

    func connect() async throws {}
    func disconnect() async { feed.finish() }
    func send(_ data: Data) async throws { sent.append(data) }
    func receive() -> AsyncThrowingStream<Data, any Error> { incoming }

    func deliver(_ json: String) { feed.yield(Data(json.utf8)) }
    func finish() { feed.finish() }

    func sentIDs() -> [Int] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? Int }
    }
}

@Suite("cherry mcp：标准输入关闭时的进行中请求")
struct CherryMCPDrainTests {
    /// 客户端写完请求就关闭输入（管道调用）：`waitUntilCompleted()` 返回时，进行中工具调用的响应必须已经发出。
    @Test func responsesInFlightAtEOFAreStillSent() async throws {
        let backend = MCPBackend { _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return ControlResult(message: "ok")
        }
        let server = await CherryMCP.server(version: "test", backend: backend)
        let transport = ScriptedTransport()
        let draining = DrainingTransport(transport, logger: transport.logger)
        try await server.start(transport: draining)
        await transport.deliver(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#)
        await transport.finish()
        await server.waitUntilCompleted()
        #expect(await transport.sentIDs().contains(2))
        #expect(await draining.pendingRequests == 0)
        await server.stop()
    }

    /// 缺少工具名的 `tools/call` 得到 -32602，而不是 SDK 的 -32603 和系统本地化的解码说明；之后照常服务。
    @Test func toolCallsWithoutANameAreInvalidParams() async throws {
        let server = await CherryMCP.server(version: "test", backend: MCPBackend { _, _ in ControlResult(message: "ok") })
        let transport = ScriptedTransport()
        try await server.start(transport: DrainingTransport(transport, logger: transport.logger))
        await transport.deliver(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","id":"three","method":"tools/call","params":{"name":5}}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#)
        await transport.finish()
        await server.waitUntilCompleted()
        let responses = await transport.sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        func error(_ id: AnyHashable) -> [String: Any]? {
            responses.first { ($0["id"] as? AnyHashable) == id }?["error"] as? [String: Any]
        }
        #expect(error(2)?["code"] as? Int == -32602 && (error(2)?["message"] as? String)?.contains("缺少工具名") == true)
        #expect(error("three")?["code"] as? Int == -32602)
        #expect(responses.contains { $0["id"] as? Int == 4 && $0["result"] != nil })
        #expect(DrainingTransport.rejection(for: Data(#"[{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}]"#.utf8)) == nil)
        await server.stop()
    }

    /// 客户端取消的请求 SDK 不再回应，EOF 后不等它。
    @Test func cancelledRequestsDoNotHoldTheExit() async throws {
        let backend = MCPBackend { _, _ in
            try await Task.sleep(for: .seconds(30))
            return ControlResult(message: "late")
        }
        let server = await CherryMCP.server(version: "test", backend: backend)
        let transport = ScriptedTransport()
        let draining = DrainingTransport(transport, logger: transport.logger, drainLimit: .seconds(20))
        try await server.start(transport: draining)
        await transport.deliver(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#)
        await transport.deliver(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#)
        await transport.finish()
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await server.waitUntilCompleted() }
        #expect(elapsed < .seconds(5))
        await server.stop()
    }
}
