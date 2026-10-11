import AppKit
import CherryAdapters
import CherryCore
import CherryFeatures
import ComposableArchitecture
import Foundation

/// The only place that knows about concrete adapters: builds them once and plugs core services
/// into the feature clients.
struct CompositionRoot {
    private let hid: IOKitHIDService
    private let access = InputMonitoringAccess()
    private let inspector: KeyboardInspector
    private let configurator: KeyboardConfigurator
    private let presets: PresetLibrary
    private let firmware: FirmwareUpdateService

    init() {
        let loop = HIDEventLoop()
        let hid = IOKitHIDService(loop: loop)
        // One queue per keyboard interface: the status item, the open screens and the firmware tab take turns
        // instead of failing with "interface busy".
        let channels = ExclusiveChannelProvider(base: hid)
        let support = URL.applicationSupportDirectory.appending(path: "CherryUtility", directoryHint: .isDirectory)
        let catalog = CherryFirmwareCatalog(cacheDirectory: support.appending(path: "Firmware", directoryHint: .isDirectory))
        self.hid = hid
        inspector = KeyboardInspector(channels: channels)
        configurator = KeyboardConfigurator(channels: channels)
        presets = PresetLibrary(store: FileProfilePresetStore(directory: support.appending(path: "Presets", directoryHint: .isDirectory)))
        firmware = FirmwareUpdateService(catalog: catalog, downloader: catalog, channels: channels, discovery: hid)
    }

    func install(into dependencies: inout DependencyValues) {
        let hid = hid
        let access = access
        let inspector = inspector
        let configurator = configurator
        let presets = presets
        let firmware = firmware

        dependencies.keyboardClient = KeyboardClient(
            keyboards: { await hid.keyboards() },
            updates: { hid.keyboardUpdates() },
            vendorSnapshot: { try await inspector.vendorSnapshot(of: $0) },
            battery: { try await inspector.battery(of: $0) },
            firmwareStatus: { try await inspector.firmwareStatus(of: $0) }
        )
        dependencies.configurationClient = ConfigurationClient(
            configuration: { try await configurator.configuration(of: $0) },
            activateProfile: { try await configurator.activateProfile($0, on: $1) },
            updateProfile: { try await configurator.update(profile: $0, on: $1, patch: $2) }
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
            openAccessSettings: { await SystemSettings.openInputMonitoring() },
            keyEvents: { hid.keyEvents(keyboard: $0) },
            suppressAppKeyEvents: { await LocalKeySuppressor.suppressUntilCancelled() }
        )
        dependencies.firmwareClient = FirmwareClient(
            latestRelease: { try await firmware.latestRelease(for: $0) },
            download: { try await firmware.download($0) },
            loadLocal: { try await LocalUpdaterFile.package(at: $0) },
            deviceFirmware: { try await firmware.deviceFirmware(keyboard: $0, package: $1) },
            flash: { try await firmware.flash(keyboard: $0, package: $1, progress: $2) },
            verifyAfterFlash: { try await firmware.verifyAfterFlash(keyboard: $0, package: $1) }
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

enum LocalUpdaterFile {
    static func package(at url: URL) async throws -> FirmwarePackage {
        try FirmwareUpdateService.makePackage(data: try await LocalFile.read(url), source: .localFile(url))
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
