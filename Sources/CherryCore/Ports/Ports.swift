import Foundation

// Driven ports: what the core needs from the outside world. Adapters (IOKit, URLSession, disk)
// implement them; tests implement them with in-memory fakes.

/// Raw report I/O on one HID interface of a keyboard.
public protocol HIDReportChannel: Sendable {
    /// Output report length including the report-ID byte.
    var outputReportLength: Int { get }
    /// Report IDs of the input reports that belong to this channel's collection.
    var inputReportIDs: Set<UInt8> { get }

    func send(_ report: [UInt8]) async throws
    /// Next input report, or nil when `timeout` elapses. Throws `CherryError.disconnected` once the device is gone.
    func receive(timeout: Duration) async throws -> [UInt8]?
    /// Drops input reports that arrived before now.
    func discardPending() async
    func close() async
}

public protocol KeyboardDiscoveryPort: Sendable {
    func keyboards() async -> [KeyboardSummary]
    /// Emits the full list on every attach/detach; the first element is the current list.
    func keyboardUpdates() -> AsyncStream<[KeyboardSummary]>
}

public protocol ReportChannelProvider: Sendable {
    /// Opens the interface of `keyboard` that exposes `usagePage`, for reports with `reportID`.
    func openChannel(keyboard: KeyboardID, usagePage: UInt16, reportID: UInt8) async throws -> any HIDReportChannel
}

public protocol KeyEventSource: Sendable {
    /// Key down/up events of `keyboard`'s keyboard + consumer collections; finishes on disconnect.
    func keyEvents(keyboard: KeyboardID) -> AsyncThrowingStream<KeyEvent, any Error>
}

public protocol InputMonitoringPort: Sendable {
    func status() -> InputMonitoringStatus
    /// Triggers the system prompt; returns true when access is granted.
    func request() async -> Bool
}

public protocol FirmwareCatalogPort: Sendable {
    func releases() async throws -> [FirmwareRelease]
}

public protocol FirmwareDownloadPort: Sendable {
    /// Raw updater bytes for `release` (adapters may serve a cached copy).
    func download(_ release: FirmwareRelease) async throws -> Data
}

/// Local library of saved profile presets.
public protocol ProfilePresetStore: Sendable {
    /// Newest first.
    func presets() async throws -> [ProfilePreset]
    func save(_ preset: ProfilePreset) async throws
    func delete(id: UUID) async throws
}
