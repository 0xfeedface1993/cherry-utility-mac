import Foundation

/// What the app and the `cherry` command share, and where: the control socket, per-keyboard lock files, the automation
/// activity record and presets, plus the preferences domain and the namespace of cross-process signals. Both
/// composition roots resolve it from the same environment, so they always agree.
///
/// Real runs use `~/Library/Application Support/CherryUtility` and the app's own preferences domain. Simulated runs
/// (`CHERRY_SIMULATION`) never touch either: everything lives under `CHERRY_DATA_DIR`, or under a fresh temporary
/// directory when it is not set, so tests can run the app and `cherry` against one simulated keyboard without ever
/// reaching the real app.
public struct SharedLocations: Hashable, Sendable {
    public static let simulationKey = "CHERRY_SIMULATION"
    public static let dataDirectoryKey = "CHERRY_DATA_DIR"
    public static let simulationStateKey = "CHERRY_SIMULATION_STATE"
    public static let presetDirectoryKey = "CHERRY_PRESET_DIR"

    /// The simulated scenario (`pixiu75`, `slow` …), nil for a real keyboard.
    public let simulation: String?
    public let dataDirectory: URL
    /// The socket named by `CHERRY_CONTROL_SOCKET` (or `--socket`). A client never connects directly to the keyboard
    /// instead of an explicitly named socket.
    public let explicitSocket: String?
    private let configuredDataDirectory: Bool
    private let presetOverride: URL?
    private let stateOverride: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, explicitSocket: String? = nil) {
        func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        simulation = value(Self.simulationKey)
        let configured = value(Self.dataDirectoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        configuredDataDirectory = configured != nil
        if simulation != nil {
            dataDirectory = configured ?? Self.processScratch
            presetOverride = value(Self.presetDirectoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            stateOverride = value(Self.simulationStateKey).map { URL(fileURLWithPath: $0) }
        } else {
            dataDirectory = URL.applicationSupportDirectory.appending(path: "CherryUtility", directoryHint: .isDirectory)
            presetOverride = nil
            stateOverride = nil
        }
        self.explicitSocket = explicitSocket ?? value(ControlProtocol.socketEnvironmentKey)
    }

    /// One temporary data directory per process for simulated runs without `CHERRY_DATA_DIR`.
    private static let processScratch = FileManager.default.temporaryDirectory
        .appending(path: "CherryUtility-Simulation-\(UUID().uuidString)", directoryHint: .isDirectory)

    public var isSimulated: Bool { simulation != nil }

    /// The socket clients try first and the app listens on. A simulated run without `CHERRY_DATA_DIR` opens no socket
    /// unless one is named explicitly.
    public var socket: String? {
        if let explicitSocket { return explicitSocket }
        guard !isSimulated || configuredDataDirectory else { return nil }
        return dataDirectory.appending(path: "control.sock").path(percentEncoded: false)
    }

    public var locks: URL { dataDirectory.appending(path: "Locks", directoryHint: .isDirectory) }
    public var activity: URL { dataDirectory.appending(path: "automation-activity.json") }
    public var presets: URL { presetOverride ?? dataDirectory.appending(path: "Presets", directoryHint: .isDirectory) }

    /// File shared by every process simulating the same keyboard; nil unless simulated with a data directory or an
    /// explicit `CHERRY_SIMULATION_STATE`.
    public var simulationState: URL? {
        guard isSimulated else { return nil }
        return stateOverride ?? (configuredDataDirectory ? dataDirectory.appending(path: "simulated-keyboard.bin") : nil)
    }

    public var preferencesDomain: String {
        isSimulated ? ControlProtocol.bundleIdentifier + ".simulation" : ControlProtocol.bundleIdentifier
    }

    /// Simulated runs get a namespace of their own (derived from the data directory), so their signals never reach the
    /// real app or another test run.
    public var signalNamespace: String {
        guard isSimulated else { return ControlProtocol.bundleIdentifier }
        return ControlProtocol.bundleIdentifier + ".simulation." + Self.fingerprint(dataDirectory.standardizedFileURL.path)
    }

    /// FNV-1a: stable across processes and launches, unlike `hashValue`.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
