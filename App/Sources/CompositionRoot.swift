import AppKit
import CherryAdapters
import CherryCore
import CherryFeatures
import CherrySimulation
import ComposableArchitecture
import Foundation

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
    /// Set in simulation mode only.
    let simulation: SimulationControls?
    let diagnosticRuntime: DiagnosticsRuntime

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
            catalog = SimulatedStockCatalog()
            presetDirectory = environment["CHERRY_PRESET_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appending(path: "CherryUtility-Simulation-\(UUID().uuidString)", directoryHint: .isDirectory)
            definitions = SimulatedFirmwareDefinitions()
            customDirectory = environment["CHERRY_CUSTOM_FIRMWARE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appending(path: "CherryUtility-SimulationFirmware-\(UUID().uuidString)", directoryHint: .isDirectory)
            simulation = SimulationControls(hub: hub)
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
        }

        services = CoreServices(
            discovery: discovery, channels: channelBase, catalog: CachedFirmwareCatalog(base: catalog), downloader: catalog,
            diagnostics: diagnostics
        )
        presets = PresetLibrary(store: FileProfilePresetStore(directory: presetDirectory, diagnostics: diagnostics))
        customFirmware = services.customFirmware(
            definitions: definitions,
            variants: FileFirmwareVariantStore(directory: customDirectory.appending(path: "Variants", directoryHint: .isDirectory), diagnostics: diagnostics),
            flashLog: FileFirmwareFlashLog(file: customDirectory.appending(path: "flash-history.json"), diagnostics: diagnostics)
        )
    }

    func install(into dependencies: inout DependencyValues) {
        DiagnosticsComposition.install(diagnosticRuntime, into: &dependencies)
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
            save: { try await presets.save(name: $0, settings: $1, from: $2) },
            delete: { try await presets.delete(id: $0) },
            importFile: { try await presets.importPreset(try await LocalFile.read($0)) }
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
            flash: { try await firmware.flash(keyboard: $0, package: $1, progress: $2) },
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
            flash: { try await custom.flash($0, on: $1, progress: $2) },
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
