import ArgumentParser
import CherryAdapters
import CherryControl
import CherryControlService
import CherryCore
import CherrySimulation
import Foundation
import Testing
@testable import CherryCLI

/// 路由只在模拟环境里测：`CHERRY_SIMULATION` 加独立的 `CHERRY_DATA_DIR`，默认 socket、锁、调用记录和模拟键盘的
/// 共享状态都在这个临时目录里，绝不碰真 App 的 socket 或真键盘。
@Suite("cherry 命令行：经由 App 与直连的路由", .serialized)
struct CherryRoutingTests {
    struct Sandbox {
        let directory: URL
        var environment: [String: String] { ["CHERRY_SIMULATION": "pixiu75", "CHERRY_DATA_DIR": directory.path(percentEncoded: false)] }
        var locations: SharedLocations { SharedLocations(environment: environment) }

        init() throws {
            // socket 在这个目录里：`sun_path` 只有 104 字节，放在 /tmp。
            directory = URL(fileURLWithPath: "/tmp/cherry-route-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// 模拟的「App」：与直连共用同一个模拟键盘状态文件、锁目录和调用记录，在数据目录的默认 socket 上应答。
        func startApp() throws -> ControlSocketServer {
            let locations = locations
            var scenario = SimulatedKeyboardHub.Scenario.named("pixiu75")
            scenario.sharedState = locations.simulationState
            let hub = SimulatedKeyboardHub(scenario: scenario)
            let lock = FileDeviceLock(directory: locations.locks)
            let services = CoreServices(discovery: hub, channels: hub, catalog: SimulatedFirmwareCatalog(), downloader: SimulatedFirmwareCatalog(), lock: lock)
            let automation = services.automation(
                presets: PresetLibrary(store: FileProfilePresetStore(directory: locations.presets)),
                timing: .init(discoveryTimeout: .milliseconds(50), settle: .zero, poll: .milliseconds(10))
            )
            let entries = AutomationEntries(
                preferences: InMemoryAutomationPreferences(), activity: FileAutomationActivityStore(file: locations.activity),
                signals: ProcessLocalSignals(), installer: NoCommandLineToolInstaller(), registry: NoMCPClientRegistry(), route: .viaApp
            )
            let service = ControlService(automation: automation, entries: entries, appVersion: "9.9.9", build: "99")
            let server = ControlSocketServer(path: try #require(locations.socket)) { request, reply in await service.handle(request, reply: reply) }
            try server.start()
            return server
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// 指定的 socket 连不上时报「没有运行」，绝不改为直连。
    @Test func anExplicitSocketIsNeverReplacedByADirectConnection() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let missing = sandbox.directory.appending(path: "none.sock").path(percentEncoded: false)
        #expect(throws: CLIError.appUnavailable("CHERRY Utility 没有运行（socket：\(missing)）")) {
            _ = try Session.open(socket: missing, environment: sandbox.environment)
        }
        var environment = sandbox.environment
        environment["CHERRY_CONTROL_SOCKET"] = missing
        #expect(throws: CLIError.appUnavailable("CHERRY Utility 没有运行（socket：\(missing)）")) {
            _ = try Session.open(socket: nil, environment: environment)
        }
    }

    /// 没有 App 应答时直连；App 在时经由它；两条路对同一把（共享状态的）键盘读到同样的状态。
    @Test func withoutAnAppTheCommandConnectsDirectlyAndSeesTheSameKeyboard() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let direct = try Session.open(socket: nil, environment: sandbox.environment)
        #expect(direct.isDirect)
        let written = try direct.call(.update, ControlParams(profile: 3, effect: "呼吸", brightness: 1))
        #expect(written.message == "已更新配置 3：灯效 呼吸，亮度 低")
        let directStatus = try #require(try direct.call(.status).status)
        #expect(try direct.call(.version).version?.app != "9.9.9", "直连时报告的是 cherry 自己的版本")

        let app = try sandbox.startApp()
        defer { app.stop() }
        let viaApp = try Session.open(socket: nil, environment: sandbox.environment)
        #expect(!viaApp.isDirect)
        #expect(try viaApp.call(.version).version?.app == "9.9.9")
        #expect(try viaApp.call(.status).status == directStatus, "App 读到命令行直连时写入的值")

        // 调用记录共用：直连与经由 App 的调用都在同一份记录里（version 不计入）。
        let activity = FileAutomationActivityStore(file: sandbox.locations.activity).load()
        #expect(activity.commandLine.count == 3 && activity.commandLine.lastCall?.route == .viaApp, "\(activity)")
    }

    @Test func noLaunchAndViaAppDoNotFallBackToADirectConnection() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        #expect(throws: CLIError.appUnavailable("CHERRY Utility 没有运行")) {
            _ = try Session.open(socket: nil, noLaunch: true, environment: sandbox.environment)
        }
        // 模拟运行里启动的会是真机模式的 App，所以 --via-app 直接报错。
        #expect(throws: CLIError.failed("模拟模式下不启动 CHERRY Utility")) {
            _ = try Session.open(socket: nil, viaApp: true, environment: sandbox.environment)
        }
        #expect(try Session.open(socket: nil, direct: true, environment: sandbox.environment).isDirect)
        #expect(throws: (any Error).self) { try ConnectionOptions.parse(["--direct", "--via-app"]) }
    }

    /// App 里关掉 MCP，直连的 MCP 调用同样被拒绝（开关存在共享偏好里）；命令行照常。
    @Test func directCallsHonourTheSharedSwitches() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let preferences = SharedAutomationPreferences(domain: sandbox.locations.preferencesDomain)
        preferences.setEnabled(.mcp, false)
        defer { preferences.setEnabled(.mcp, true) }
        let mcp = try Session.open(socket: nil, client: ControlClientKind.mcp, environment: sandbox.environment)
        #expect(throws: CLIError.rejected(ControlFailure(code: "automationDisabled", message: "MCP 控制已在 CHERRY Utility 的「设置 › 自动化」里关闭"))) {
            _ = try mcp.call(.status)
        }
        #expect(try Session.open(socket: nil, environment: sandbox.environment).call(.status).status != nil)
        let activity = FileAutomationActivityStore(file: sandbox.locations.activity).load()
        #expect(activity.mcp.lastCall?.succeeded == false && activity.mcp.lastCall?.route == .direct)
    }

    /// 模拟运行的位置都在数据目录里，偏好与通知命名空间与真 App 分开。
    @Test func simulatedLocationsStayInsideTheDataDirectory() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let locations = sandbox.locations
        let root = sandbox.directory.path(percentEncoded: false)
        #expect(locations.socket?.hasPrefix(root) == true && locations.locks.path.hasPrefix(root.dropLast().description))
        #expect(locations.simulationState?.path.hasPrefix(root.dropLast().description) == true)
        #expect(locations.preferencesDomain == "online.odeployer.CherryUtility.simulation")
        #expect(locations.signalNamespace.hasPrefix("online.odeployer.CherryUtility.simulation."))
        #expect(locations.signalNamespace == SharedLocations(environment: sandbox.environment).signalNamespace)
        let real = SharedLocations(environment: [:])
        #expect(real.socket == ControlProtocol.defaultSocketPath && real.signalNamespace == "online.odeployer.CherryUtility")
        #expect(SharedLocations(environment: ["CHERRY_SIMULATION": "pixiu75"]).socket == nil, "没有数据目录的模拟运行不开 socket")
    }
}
