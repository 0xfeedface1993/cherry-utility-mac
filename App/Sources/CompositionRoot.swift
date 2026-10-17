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
    /// 正在刷写固件的键盘；刷写期间自动化入口拒绝写入。
    private let firmwareActivity = FirmwareActivity()
    /// 快捷指令 / Spotlight 意图使用的用例服务，由 App 启动时注册给 App Intents。
    let automation: KeyboardAutomation
    /// 命令行（之后的 MCP）连接的本地 socket；模拟模式只在指定 `CHERRY_CONTROL_SOCKET` 时开启，不碰正式 App 的 socket。
    private let controlServer: ControlSocketServer?
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
        var presetDirectory = support.appending(path: "Presets", directoryHint: .isDirectory)
        let definitions: any FirmwareDefinitionSource
        var customDirectory = support.appending(path: "CustomFirmware", directoryHint: .isDirectory)

        if let scenario = environment["CHERRY_SIMULATION"] {
            let hub = SimulatedKeyboardHub(scenario: .named(scenario), diagnostics: diagnostics)
            discovery = hub
            keySource = hub
            access = hub
            channelBase = hub
            catalog = SimulatedStockCatalog(base: SimulatedFirmwareCatalog(model: hub.scenario.model))
            presetDirectory = environment["CHERRY_PRESET_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appending(path: "CherryUtility-Simulation-\(UUID().uuidString)", directoryHint: .isDirectory)
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

        services = CoreServices(
            discovery: discovery, channels: channelBase, catalog: CachedFirmwareCatalog(base: catalog), downloader: catalog,
            diagnostics: diagnostics
        )
        presets = PresetLibrary(store: FileProfilePresetStore(directory: presetDirectory, diagnostics: diagnostics))
        automation = services.automation(presets: presets, activity: firmwareActivity)
        let socketPath = environment[ControlProtocol.socketEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
            ?? (simulation == nil ? ControlProtocol.defaultSocketPath : nil)
        let info = Bundle.main.infoDictionary
        let control = ControlService(
            automation: automation, appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?"
        )
        controlServer = socketPath.map { ControlSocketServer(path: $0) { request, reply in await control.handle(request, reply: reply) } }
        customFirmware = services.customFirmware(
            definitions: definitions,
            variants: FileFirmwareVariantStore(directory: customDirectory.appending(path: "Variants", directoryHint: .isDirectory), diagnostics: diagnostics),
            flashLog: FileFirmwareFlashLog(file: customDirectory.appending(path: "flash-history.json"), diagnostics: diagnostics)
        )
    }

    private static let controlLog = Logger(subsystem: "online.odeployer.CherryUtility", category: "control")

    /// 开始接受命令行连接。另一个实例已在应答时不重复监听；失败只记录，不影响界面。
    func startControlServer() {
        guard let controlServer else { return }
        do {
            try controlServer.start()
        } catch .alreadyRunning {
            Self.controlLog.notice("control socket already served by another instance")
        } catch {
            Self.controlLog.error("control socket unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// 退出时删除 socket 文件，命令行据此判断 App 已不在运行。
    var stopControlServer: @Sendable () -> Void {
        let server = controlServer
        return {
            server?.stop()
            Self.controlLog.notice("control socket closed")
        }
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
