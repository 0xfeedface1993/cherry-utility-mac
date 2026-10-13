import CherryFeatures
import Foundation
import Observation
import ServiceManagement
import Sparkle

/// Sparkle adapter. Updates run only in builds with a valid signed feed (Info.plist `SUFeedURL` + `SUPublicEDKey`),
/// outside simulation mode, and — unless `CHERRY_ENABLE_UPDATER=1` — only in Release builds, so development runs
/// never offer to replace themselves.
@MainActor
@Observable
final class UpdateController {
    private let controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let enabled = Self.isConfigured(bundle) && environment["CHERRY_SIMULATION"] == nil
            && (Self.isRelease || environment["CHERRY_ENABLE_UPDATER"] == "1")
        controller = enabled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var snapshot: AppUpdateSnapshot {
        let version = Self.versionString
        guard let updater = controller?.updater else {
            return AppUpdateSnapshot(isAvailable: false, automaticallyChecks: false, automaticallyDownloads: false, canCheckNow: false, lastCheck: nil, version: version)
        }
        return AppUpdateSnapshot(
            isAvailable: true,
            automaticallyChecks: updater.automaticallyChecksForUpdates,
            automaticallyDownloads: updater.automaticallyDownloadsUpdates,
            canCheckNow: updater.canCheckForUpdates,
            lastCheck: updater.lastUpdateCheckDate,
            version: version
        )
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var isRelease: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    private static func isConfigured(_ bundle: Bundle) -> Bool {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.contains("$("),
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.contains("$("),
              let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return true
    }
}

/// "Open at login" through the main-app login item.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
