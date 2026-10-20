import ComposableArchitecture
import Foundation

/// What the settings screen shows about in-app updates. `isAvailable` is false in builds without a signed feed
/// (simulation, debug builds without a key), where the controls are shown disabled.
public struct AppUpdateSnapshot: Equatable, Sendable {
    public var isAvailable: Bool
    public var automaticallyChecks: Bool
    public var automaticallyDownloads: Bool
    public var canCheckNow: Bool
    public var lastCheck: Date?
    public var version: String

    public init(isAvailable: Bool, automaticallyChecks: Bool, automaticallyDownloads: Bool, canCheckNow: Bool, lastCheck: Date?, version: String) {
        self.isAvailable = isAvailable
        self.automaticallyChecks = automaticallyChecks
        self.automaticallyDownloads = automaticallyDownloads
        self.canCheckNow = canCheckNow
        self.lastCheck = lastCheck
        self.version = version
    }

    public static let unavailable = Self(isAvailable: false, automaticallyChecks: false, automaticallyDownloads: false, canCheckNow: false, lastCheck: nil, version: "—")
}

/// In-app updates (Sparkle in the app target).
@DependencyClient
public struct AppUpdateClient: Sendable {
    public var snapshot: @Sendable () async -> AppUpdateSnapshot = { .unavailable }
    public var setAutomaticallyChecks: @Sendable (_ enabled: Bool) async -> Void
    public var setAutomaticallyDownloads: @Sendable (_ enabled: Bool) async -> Void
    public var checkForUpdates: @Sendable () async -> Void
}

/// "Open at login" (SMAppService in the app target).
@DependencyClient
public struct LoginItemClient: Sendable {
    public var isEnabled: @Sendable () async -> Bool = { false }
    public var setEnabled: @Sendable (_ enabled: Bool) async throws -> Void
}

extension AppUpdateClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(
        snapshot: { AppUpdateSnapshot(isAvailable: true, automaticallyChecks: true, automaticallyDownloads: false, canCheckNow: true, lastCheck: nil, version: "1.0.0 (1)") },
        setAutomaticallyChecks: { _ in },
        setAutomaticallyDownloads: { _ in },
        checkForUpdates: {}
    )
}

extension LoginItemClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(isEnabled: { false }, setEnabled: { _ in })
}

extension DependencyValues {
    public var appUpdateClient: AppUpdateClient {
        get { self[AppUpdateClient.self] }
        set { self[AppUpdateClient.self] = newValue }
    }

    public var loginItemClient: LoginItemClient {
        get { self[LoginItemClient.self] }
        set { self[LoginItemClient.self] = newValue }
    }
}

// MARK: - Preferences

/// Preference keys shared between the settings screen, the main window and the menu bar.
/// They live in `defaultAppStorage`, which the composition root points at a throwaway suite in simulation mode.
extension SharedKey where Self == AppStorageKey<Bool>.Default {
    /// Shows the experimental "自定义固件" section. Off by default; turning it on requires acknowledging the risk.
    public static var customFirmwareEnabled: Self {
        Self[.appStorage("experimentalCustomFirmware"), default: false]
    }

    public static var showMainWindowAtLaunch: Self {
        Self[.appStorage("showMainWindowAtLaunch"), default: true]
    }

    public static var showBatteryInMenuBar: Self {
        Self[.appStorage("showBatteryInMenuBar"), default: true]
    }
}
