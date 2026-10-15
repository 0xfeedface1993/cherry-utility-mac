import AppKit
import CherryFeatures
import Foundation
import Observation
import ServiceManagement
import Sparkle

/// Sparkle adapter. Updates run only in builds with a valid signed feed (Info.plist `SUFeedURL` + `SUPublicEDKey`):
/// in Release builds outside simulation mode, or wherever `CHERRY_ENABLE_UPDATER=1` asks for them, so development
/// runs and UI tests never offer to replace themselves by accident.
///
/// Debug builds also honour `CHERRY_UPDATE_FEED=<url>` (UI tests point it at a local appcast). Such a run shares the
/// real app's defaults domain and per-bundle folders, so when it quits normally (⌘Q, not a kill) it puts every `SU*`
/// preference back the way it found it and removes the cache / WebKit folders that Sparkle's release-notes view created.
@MainActor
@Observable
final class UpdateController {
    private let controller: SPUStandardUpdaterController?
    private let feedOverride: FeedOverride?
    private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let requested = environment["CHERRY_ENABLE_UPDATER"] == "1"
        let enabled = Self.isConfigured(bundle) && (requested || (Self.isRelease && environment["CHERRY_SIMULATION"] == nil))
        feedOverride = enabled && !Self.isRelease ? environment["CHERRY_UPDATE_FEED"].map { FeedOverride(feed: $0) } : nil
        controller = enabled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feedOverride, userDriverDelegate: nil) : nil
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
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

    /// Debug-only feed redirection for UI tests, plus the bookkeeping that keeps their checks out of the real
    /// preferences: the `SU*` keys present at launch are restored (and new ones removed) when the app terminates.
    private final class FeedOverride: NSObject, SPUUpdaterDelegate, @unchecked Sendable { // immutable after init
        private let feed: String
        private let defaults = UserDefaults.standard
        private let saved: [String: Any]
        /// Per-bundle folders that did not exist at launch (WebKit creates them for the release notes).
        private let newFolders: [URL]
        private var termination: NSObjectProtocol?

        init(feed: String) {
            self.feed = feed
            saved = Self.sparkleKeys(in: defaults)
            let id = Bundle.main.bundleIdentifier ?? ""
            let library = URL.libraryDirectory
            newFolders = [library.appending(path: "Caches/\(id)"), library.appending(path: "WebKit/\(id)"),
                          library.appending(path: "HTTPStorages/\(id)"), library.appending(path: "HTTPStorages/\(id).binarycookies")]
                .filter { !FileManager.default.fileExists(atPath: $0.path) }
            super.init()
            termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            }
        }

        func feedURLString(for updater: SPUUpdater) -> String? { feed }

        private func restore() {
            for key in Self.sparkleKeys(in: defaults).keys where saved[key] == nil {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in saved {
                defaults.set(value, forKey: key)
            }
            defaults.synchronize()
            for folder in newFolders { try? FileManager.default.removeItem(at: folder) }
        }

        private static func sparkleKeys(in defaults: UserDefaults) -> [String: Any] {
            guard let domain = Bundle.main.bundleIdentifier, let all = defaults.persistentDomain(forName: domain) else { return [:] }
            return all.filter { $0.key.hasPrefix("SU") }
        }
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
