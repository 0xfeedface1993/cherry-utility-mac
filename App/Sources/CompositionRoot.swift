import AppKit
import CherryAdapters
import CherryControl
import CherryControlService
import CherryCore
import CherryFeatures
import CherrySimulation
import ComposableArchitecture
import Foundation
import OSLog
import Synchronization

/// The only place that knows about concrete adapters: builds them once, hands them to `CoreServices`
/// (the shared Core assembly) and plugs the services into the feature clients. No use-case logic lives here.
///
/// Launched with `CHERRY_SIMULATION=<scenario>` (UI tests, demos) every driven adapter is replaced by the in-memory
/// simulated keyboard, so the full core stack runs without hardware or Input Monitoring.
struct CompositionRoot {
    private let discovery: any KeyboardDiscoveryPort
    private let keySource: any KeyEventSource
    private let access: any InputMonitoringPort
    private let services: CoreServices
    private let presets: PresetLibrary
    private let customFirmware: CustomFirmwareService
    /// 正在刷写固件的键盘；刷写期间自动化入口拒绝写入，并持有跨进程租约，命令行直连也会被拒绝。
    private let firmwareActivity: FirmwareActivity
    /// 快捷指令 / Spotlight 意图使用的用例服务，由 App 启动时注册给 App Intents。
    let automation: KeyboardAutomation
    /// 命令行与 MCP 两个入口的开关、调用记录、socket 状态与安装 / 注册（「设置 › 自动化」）。
    private let entries: AutomationEntries
    /// 命令行与 MCP 连接的本地 socket（`SharedLocations.socket`）；模拟模式只在指定 socket 或数据目录时开启，不碰正式 App 的 socket。
    private let controlServer: ControlSocketServer?
    /// 收到其他进程（命令行直连）写入的信号时重读配置；退出时取消。
    private let relay = SupervisedTask()
    /// Set in simulation mode only.
    let simulation: SimulationControls?
    let diagnosticRuntime: DiagnosticsRuntime
    /// Simulation only: where the diagnostic save panel opens, so UI tests never type into the system panel.
    private let diagnosticSaveDirectory: URL?
    /// Backing store of the `@Shared(.appStorage)` preferences. Simulation uses its own suite, reset on every launch,
    /// so UI tests never change the real app's settings (both run under the same bundle identifier).
    let preferences: UserDefaults

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let support = URL.applicationSupportDirectory.appending(path: "CherryUtility", directoryHint: .isDirectory)
        let runtime = DiagnosticsComposition.make(support: support, environment: environment)
        diagnosticRuntime = runtime
        let diagnostics = runtime.port
        let catalog: any FirmwareCatalogPort & FirmwareDownloadPort
        let channelBase: any ReportChannelProvider
        // App 与命令行共用的位置：预设、socket、设备锁、调用记录、偏好域与跨进程信号的命名空间。
        let locations = SharedLocations(environment: environment)
        let presetDirectory = locations.presets
        let definitions: any FirmwareDefinitionSource
        var customDirectory = support.appending(path: "CustomFirmware", directoryHint: .isDirectory)

        if let scenario = environment["CHERRY_SIMULATION"] {
            var named = SimulatedKeyboardHub.Scenario.named(scenario)
            // 指定数据目录时，模拟键盘的配置存在共享文件里，同一目录下直连的 cherry 看到的是同一把键盘。
            named.sharedState = locations.simulationState
            let hub = SimulatedKeyboardHub(scenario: named, diagnostics: diagnostics)
            discovery = hub
            keySource = hub
            access = hub
            channelBase = hub
            catalog = SimulatedStockCatalog(base: SimulatedFirmwareCatalog(model: hub.scenario.model))
            definitions = SimulatedFirmwareDefinitions()
            customDirectory = environment["CHERRY_CUSTOM_FIRMWARE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appending(path: "CherryUtility-SimulationFirmware-\(UUID().uuidString)", directoryHint: .isDirectory)
            simulation = SimulationControls(hub: hub)
            diagnosticSaveDirectory = environment["CHERRY_DIAGNOSTIC_SAVE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            preferences = Self.simulationPreferences(experimental: environment["CHERRY_EXPERIMENTAL"])
        } else {
            let hid = IOKitHIDService(loop: HIDEventLoop(diagnostics: diagnostics))
            discovery = hid
            keySource = hid
            access = InputMonitoringAccess(diagnostics: diagnostics)
            channelBase = hid
            catalog = CherryFirmwareCatalog(cacheDirectory: support.appending(path: "Firmware", directoryHint: .isDirectory), diagnostics: diagnostics)
            // Bundled *.cherryfw sit flat in the app's Resources; files the user adds override them by ID.
            definitions = DirectoryFirmwareDefinitionSource(directories: [
                (Bundle.main.resourceURL ?? Bundle.main.bundleURL, .bundled),
                (customDirectory.appending(path: "Definitions", directoryHint: .isDirectory), .user),
            ], diagnostics: diagnostics)
            simulation = nil
            diagnosticSaveDirectory = nil
            preferences = .standard
        }

        let lock = FileDeviceLock(directory: locations.locks)
        let signals = DarwinNotifySignal(namespace: locations.signalNamespace)
        firmwareActivity = FirmwareActivity(lock: lock)
        services = CoreServices(
            discovery: discovery, channels: channelBase, catalog: CachedFirmwareCatalog(base: catalog), downloader: catalog,
            lock: lock, diagnostics: diagnostics
        )
        presets = PresetLibrary(store: FileProfilePresetStore(directory: presetDirectory, diagnostics: diagnostics))
        automation = services.automation(presets: presets, activity: firmwareActivity, signals: signals)
        entries = AutomationEntries(
            preferences: SharedAutomationPreferences(domain: locations.preferencesDomain),
            activity: FileAutomationActivityStore(file: locations.activity), signals: signals,
            installer: Self.installer(locations, environment: environment), registry: Self.registry(locations, environment: environment),
            route: .viaApp
        )
        let info = Bundle.main.infoDictionary
        let control = ControlService(
            automation: automation, entries: entries, appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?"
        )
        controlServer = locations.socket.map { ControlSocketServer(path: $0) { request, reply in await control.handle(request, reply: reply) } }
        customFirmware = services.customFirmware(
            definitions: definitions,
            variants: FileFirmwareVariantStore(directory: customDirectory.appending(path: "Variants", directoryHint: .isDirectory), diagnostics: diagnostics),
            flashLog: FileFirmwareFlashLog(file: customDirectory.appending(path: "flash-history.json"), diagnostics: diagnostics)
        )
    }

    private static let controlLog = Logger(subsystem: "online.odeployer.CherryUtility", category: "control")

    /// 开始接受命令行连接，并开始接收命令行直连写入的信号。另一个实例已在应答时不重复监听；失败只记录，不影响界面。
    /// 结果报给 `AutomationEntries`，「设置 › 自动化」据此显示。
    func startControlServer() {
        let automation = automation
        relay.start { await automation.relayChangesFromOtherProcesses() }
        guard let controlServer else {
            entries.endpointChanged(.off)
            return
        }
        do {
            try controlServer.start()
            entries.endpointChanged(.listening(path: controlServer.path))
        } catch .alreadyRunning {
            Self.controlLog.notice("control socket already served by another instance")
            entries.endpointChanged(.servedByAnotherInstance(path: controlServer.path))
        } catch {
            Self.controlLog.error("control socket unavailable: \(String(describing: error), privacy: .public)")
            entries.endpointChanged(.unavailable(path: controlServer.path, reason: String(describing: error)))
        }
    }

    /// 退出时删除 socket 文件，命令行据此判断 App 已不在运行。
    var stopControlServer: @Sendable () -> Void {
        let server = controlServer
        let relay = relay
        return {
            relay.cancel()
            server?.stop()
            Self.controlLog.notice("control socket closed")
        }
    }

    /// 把 App 包内的 cherry 链接进 PATH。模拟模式装进数据目录（或 `CHERRY_CLI_INSTALL_DIR`），不弹管理员授权。
    private static func installer(_ locations: SharedLocations, environment: [String: String]) -> SymlinkCommandLineToolInstaller {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/MacOS/cherry")
        let bundledTool = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled.path(percentEncoded: false) : nil
        guard locations.isSimulated else {
            return SymlinkCommandLineToolInstaller(
                bundledTool: bundledTool, installDirectory: URL(fileURLWithPath: "/usr/local/bin"),
                searchDirectories: SymlinkCommandLineToolInstaller.standardSearchDirectories(), allowsAuthorization: true
            )
        }
        let directory = environment["CHERRY_CLI_INSTALL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? locations.dataDirectory.appending(path: "bin", directoryHint: .isDirectory)
        return SymlinkCommandLineToolInstaller(bundledTool: bundledTool, installDirectory: directory, searchDirectories: [], allowsAuthorization: false)
    }

    /// Claude Desktop / Claude Code 的配置。模拟模式用数据目录里的副本（或环境变量指定的文件），不碰真实配置。
    private static func registry(_ locations: SharedLocations, environment: [String: String]) -> ClaudeMCPClientRegistry {
        guard locations.isSimulated else { return .standard() }
        let sandbox = locations.dataDirectory
        return ClaudeMCPClientRegistry(
            desktopConfig: environment["CHERRY_CLAUDE_DESKTOP_CONFIG"].map { URL(fileURLWithPath: $0) }
                ?? sandbox.appending(path: "Claude/claude_desktop_config.json"),
            codeConfig: environment["CHERRY_CLAUDE_CODE_CONFIG"].map { URL(fileURLWithPath: $0) } ?? sandbox.appending(path: "claude.json")
        )
    }

    private static func simulationPreferences(experimental: String?) -> UserDefaults {
        let suite = "online.odeployer.CherryUtility.simulation"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        // `CHERRY_EXPERIMENTAL=customFirmware` turns the experimental section on for UI tests that exercise it.
        let flags = Set((experimental ?? "").split(separator: ",").map(String.init))
        defaults.set(flags.contains("customFirmware"), forKey: "experimentalCustomFirmware")
        return defaults
    }

    func install(into dependencies: inout DependencyValues, updates: UpdateController) {
        DiagnosticsComposition.install(diagnosticRuntime, saveDirectory: diagnosticSaveDirectory, into: &dependencies)
        dependencies.defaultAppStorage = preferences
        dependencies.appUpdateClient = AppUpdateClient(
            snapshot: { await updates.snapshot },
            setAutomaticallyChecks: { enabled in await updates.setAutomaticallyChecks(enabled) },
            setAutomaticallyDownloads: { enabled in await updates.setAutomaticallyDownloads(enabled) },
            checkForUpdates: { await updates.checkForUpdates() }
        )
        if simulation == nil {
            dependencies.loginItemClient = LoginItemClient(
                isEnabled: { await MainActor.run { LoginItem.isEnabled } },
                setEnabled: { enabled in try await MainActor.run { try LoginItem.setEnabled(enabled) } }
            )
        } else {
            // Never register the real login item from a UI test.
            let state = LockIsolated(false)
            dependencies.loginItemClient = LoginItemClient(isEnabled: { state.value }, setEnabled: { enabled in state.setValue(enabled) })
        }
        let discovery = discovery
        let keySource = keySource
        let access = access
        let services = services
        let inspector = services.inspector
        let configurator = services.configurator
        let writer = services.writer
        let firmware = services.firmware
        let presets = presets
        let simulation = simulation
        let activity = firmwareActivity
        let automation = automation
        // 预设变化后刷新快捷指令里「预设」参数的候选；模拟模式的临时预设不进入系统。
        let refreshesShortcuts = simulation == nil
        let presetsChanged: @Sendable () -> Void = {
            if refreshesShortcuts { CherryShortcuts.updateAppShortcutParameters() }
        }

        dependencies.keyboardClient = KeyboardClient(
            keyboards: { await discovery.keyboards() },
            updates: { services.keyboardUpdates() },
            vendorSnapshot: { try await inspector.vendorSnapshot(of: $0) },
            battery: { try await inspector.battery(of: $0) },
            firmwareStatus: { try await inspector.firmwareStatus(of: $0) }
        )
        dependencies.configurationClient = ConfigurationClient(
            configuration: { try await configurator.configuration(of: $0) },
            activateProfile: { try await writer.apply(.activate($0), on: $1) },
            updateProfile: { try await writer.update(profile: $0, patch: $2, on: $1) },
            applyIntent: { try await writer.apply($0, on: $1) }
        )
        dependencies.presetClient = PresetClient(
            presets: { try await presets.presets() },
            save: { name, settings, keyboard in
                defer { presetsChanged() }
                return try await presets.save(name: name, settings: settings, from: keyboard)
            },
            delete: { id in
                defer { presetsChanged() }
                try await presets.delete(id: id)
            },
            importFile: { url in
                defer { presetsChanged() }
                return try await presets.importPreset(try await LocalFile.read(url))
            }
        )
        dependencies.configurationChangeClient = ConfigurationChangeClient(changes: { automation.changes() })
        let entries = entries
        dependencies.automationEntriesClient = AutomationEntriesClient(
            snapshot: { await entries.snapshot() },
            activityUpdates: { entries.activityUpdates() },
            setEnabled: { entries.setEnabled($0, $1) },
            installCommandLineTool: { try await entries.installCommandLineTool() },
            uninstallCommandLineTool: { try await entries.uninstallCommandLineTool() },
            registerMCP: { try await entries.registerMCP(in: $0) }
        )
        dependencies.keyTestClient = KeyTestClient(
            accessStatus: { access.status() },
            requestAccess: { await access.request() },
            openAccessSettings: {
                if simulation == nil { await SystemSettings.openInputMonitoring() }
            },
            keyEvents: { keySource.keyEvents(keyboard: $0) },
            suppressAppKeyEvents: {
                if let simulation {
                    await simulation.keyInput.suppressUntilCancelled()
                } else {
                    await LocalKeySuppressor.suppressUntilCancelled()
                }
            }
        )
        dependencies.firmwareClient = FirmwareClient(
            latestRelease: { try await firmware.latestRelease(for: $0) },
            download: { try await firmware.download($0) },
            loadLocal: { url in try firmware.loadLocal(try await LocalFile.read(url), from: url) },
            deviceFirmware: { try await firmware.deviceFirmware(keyboard: $0, package: $1) },
            flash: { keyboard, package, progress in
                try await activity.during(keyboard.id) { try await firmware.flash(keyboard: keyboard, package: package, progress: progress) }
            },
            verifyAfterFlash: { try await firmware.verifyAfterFlash(keyboard: $0, package: $1) }
        )
        let custom = customFirmware
        dependencies.customFirmwareClient = CustomFirmwareClient(
            loadDefinitions: { try await custom.loadDefinitions() },
            stockPackage: { try await custom.stockPackage(for: $0) },
            importStock: { definition, url in try custom.stockPackage(for: definition, localData: try await LocalFile.read(url), url: url) },
            variants: { try await custom.variants() },
            flashRecords: { try await custom.flashRecords() },
            createVariant: { try await custom.createVariant(named: $0, for: $1, copying: $2) },
            saveVariant: { try await custom.save($0, definition: $1, stock: $2) },
            deleteVariant: { try await custom.deleteVariant(id: $0) },
            prepareInstall: { try custom.prepareInstall($0, definition: $1, stock: $2) },
            deviceFirmware: { try await inspector.firmwareStatus(of: $0) },
            flash: { install, keyboard, progress in
                try await activity.during(keyboard.id) { try await custom.flash(install, on: keyboard, progress: progress) }
            },
            verify: { try await custom.verify($0, on: $1) }
        )
    }
}

// MARK: - Small AppKit adapters

@MainActor
enum LocalKeySuppressor {
    /// Swallows key events delivered to this app (so ⌘Q, ⌘W… don't fire while testing keys)
    /// until the calling task is cancelled. System-wide shortcuts are unaffected.
    static func suppressUntilCancelled() async {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in nil }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

@MainActor
enum SystemSettings {
    static func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LocalFile {
    /// Reads a file the user picked in an open panel.
    static func read(_ url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CherryError.storage(error.localizedDescription)
        }
    }
}

/// 一个由持有者负责取消的长期任务（组合根里只有跨进程信号的转发）。
final class SupervisedTask: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// 新任务在锁外创建，锁内只交换引用；被替换的旧任务在锁外取消。
    func start(_ body: @escaping @Sendable () async -> Void) {
        let started = Task { await body() }
        let previous = task.withLock { current -> Task<Void, Never>? in
            defer { current = started }
            return current
        }
        previous?.cancel()
    }

    func cancel() {
        task.withLock { current in defer { current = nil }; return current }?.cancel()
    }
}
