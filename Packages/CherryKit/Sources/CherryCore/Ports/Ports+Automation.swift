import Foundation

// Driven ports for running the core in more than one process: the app and the standalone `cherry` command can both
// talk to a keyboard. They coordinate through a per-keyboard lease and content-free cross-process signals, and share
// the automation switches and the activity record.

/// What a lease is held for. A firmware update keeps its lease for the whole flash; other processes are refused at once
/// instead of waiting for it.
public enum DeviceLockPurpose: Sendable {
    case session
    case firmwareUpdate
}

/// Released exactly once; releasing again does nothing.
public protocol DeviceLease: Sendable {
    func release()
}

/// Cross-process ownership of one keyboard. Within a process `ExclusiveChannelProvider` already queues sessions; this
/// lease keeps another process from interleaving its transactions with ours.
public protocol DeviceLockPort: Sendable {
    /// Throws `CherryError.deviceBusy(.updatingFirmware)` right away while another process is flashing the keyboard, and
    /// `.deviceBusy(.inUse)` when another process keeps it longer than the adapter's wait limit.
    func acquire(_ keyboard: KeyboardID, purpose: DeviceLockPurpose) async throws -> any DeviceLease
}

/// Single-process stand-in: no other process can reach the keyboard (tests, profiling, simulation without shared state).
public struct ProcessLocalDeviceLock: DeviceLockPort {
    public init() {}

    public func acquire(_ keyboard: KeyboardID, purpose: DeviceLockPurpose) async throws -> any DeviceLease {
        Released()
    }

    private struct Released: DeviceLease {
        func release() {}
    }
}

/// Content-free notifications between the app and `cherry` processes.
public enum CrossProcessSignal: String, CaseIterable, Sendable {
    /// An automation entry wrote a keyboard's configuration; other processes read it again.
    case configurationChanged
    /// The shared automation activity record changed.
    case automationActivityChanged
}

public protocol CrossProcessSignalPort: Sendable {
    func post(_ signal: CrossProcessSignal)
    /// Signals posted by other processes (never our own), until the stream is dropped.
    func signals(_ signal: CrossProcessSignal) -> AsyncStream<Void>
}

/// Single-process stand-in: posts go nowhere and no signal ever arrives.
public struct ProcessLocalSignals: CrossProcessSignalPort {
    public init() {}

    public func post(_ signal: CrossProcessSignal) {}

    public func signals(_ signal: CrossProcessSignal) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// The switches in Settings › 自动化, shared by the app and the command line.
public protocol AutomationPreferencesPort: Sendable {
    func isEnabled(_ entry: AutomationEntry) -> Bool
    func setEnabled(_ entry: AutomationEntry, _ enabled: Bool)
}

/// Activity record shared by the app and the command line.
public protocol AutomationActivityStore: Sendable {
    func load() -> AutomationActivity
    /// Adds `call` atomically with respect to other processes recording at the same time, and returns the record as
    /// written (so callers need not read it back).
    @discardableResult
    func record(_ call: AutomationCall) throws -> AutomationActivity
}

/// Puts the app's bundled `cherry` on the PATH.
public protocol CommandLineToolInstallerPort: Sendable {
    /// `cherry` inside this app's bundle; nil in a process that is not the app.
    var bundledTool: String? { get }
    func status() async -> CommandLineToolStatus
    /// Links the bundled tool into the install directory; never replaces a standalone installation.
    func install() async throws
    /// Removes the link only when it points into a `CherryUtility.app`.
    func uninstall() async throws
}

/// MCP client configurations (Claude Desktop, Claude Code).
public protocol MCPClientRegistryPort: Sendable {
    func registration(in client: MCPClient) async -> MCPClientRegistration
    /// Adds or updates the `cherry` server in `client`'s configuration, keeping every other server.
    func register(_ launch: MCPServerLaunch, in client: MCPClient) async throws
}

/// For a process that is not the app (the standalone `cherry` command): nothing bundled to install.
public struct NoCommandLineToolInstaller: CommandLineToolInstallerPort {
    public init() {}
    public var bundledTool: String? { nil }
    public func status() async -> CommandLineToolStatus { .notInstalled }
    public func install() async throws { throw AutomationSetupError.noCommandLineTool }
    public func uninstall() async throws {}
}

/// For a process that does not edit MCP client configurations (the standalone `cherry` command).
public struct NoMCPClientRegistry: MCPClientRegistryPort {
    public init() {}
    public func registration(in client: MCPClient) async -> MCPClientRegistration { .notRegistered }
    public func register(_ launch: MCPServerLaunch, in client: MCPClient) async throws { throw AutomationSetupError.managedByClient(client) }
}
