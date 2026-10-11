import CherryCore
import ComposableArchitecture
import Foundation

// Feature-facing clients. They only declare *what* the UI needs; the app's composition root builds the
// live values from CherryCore services + CherryAdapters and installs them with `withDependencies`.
// There is deliberately no `liveValue` here, so the feature layer never reaches for an adapter itself.

@DependencyClient
public struct KeyboardClient: Sendable {
    public var keyboards: @Sendable () async -> [KeyboardSummary] = { [] }
    public var updates: @Sendable () -> AsyncStream<[KeyboardSummary]> = { .finished }
    public var vendorSnapshot: @Sendable (_ keyboard: KeyboardSummary) async throws -> VendorSnapshot
    public var battery: @Sendable (_ keyboard: KeyboardSummary) async throws -> BatteryStatus
    public var firmwareStatus: @Sendable (_ keyboard: KeyboardSummary) async throws -> DeviceFirmwareStatus
}

@DependencyClient
public struct KeyTestClient: Sendable {
    public var accessStatus: @Sendable () -> InputMonitoringStatus = { .undetermined }
    public var requestAccess: @Sendable () async -> Bool = { false }
    public var openAccessSettings: @Sendable () async -> Void
    public var keyEvents: @Sendable (_ keyboard: KeyboardID) -> AsyncThrowingStream<Traced<KeyEvent>, any Error> = { _ in .finished() }
    /// Swallows key events inside the app (so Cmd-Q etc. don't fire while testing) until cancelled.
    public var suppressAppKeyEvents: @Sendable () async -> Void
}

@DependencyClient
public struct FirmwareClient: Sendable {
    public var latestRelease: @Sendable (_ model: KeyboardModel) async throws -> FirmwareRelease?
    public var download: @Sendable (_ release: FirmwareRelease) async throws -> FirmwarePackage
    public var loadLocal: @Sendable (_ url: URL) async throws -> FirmwarePackage
    public var deviceFirmware: @Sendable (_ keyboard: KeyboardID, _ package: FirmwarePackage) async throws -> DeviceFirmwareStatus
    public var flash: @Sendable (
        _ keyboard: KeyboardSummary,
        _ package: FirmwarePackage,
        _ progress: @escaping @Sendable (FlashProgress) async -> Void
    ) async throws -> FlashOutcome
    public var verifyAfterFlash: @Sendable (_ keyboard: KeyboardID, _ package: FirmwarePackage) async throws -> DeviceFirmwareStatus
}

extension KeyboardClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(
        keyboards: { [.preview] },
        updates: { AsyncStream { $0.yield([.preview]) } },
        vendorSnapshot: { _ in .preview },
        battery: { _ in VendorSnapshot.preview.battery },
        firmwareStatus: { _ in DeviceFirmwareStatus(version: 0, crc: 0xCFE1_A03E) }
    )
}

extension KeyTestClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(
        accessStatus: { .granted },
        requestAccess: { true },
        openAccessSettings: {},
        keyEvents: { _ in AsyncThrowingStream { _ in } },
        suppressAppKeyEvents: {}
    )
}

extension FirmwareClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self()
}

extension DependencyValues {
    public var keyboardClient: KeyboardClient {
        get { self[KeyboardClient.self] }
        set { self[KeyboardClient.self] = newValue }
    }

    public var keyTestClient: KeyTestClient {
        get { self[KeyTestClient.self] }
        set { self[KeyTestClient.self] = newValue }
    }

    public var firmwareClient: FirmwareClient {
        get { self[FirmwareClient.self] }
        set { self[FirmwareClient.self] = newValue }
    }
}

// MARK: - Preview fixtures (values captured from a real PIXIU 75)

extension KeyboardSummary {
    public static let preview = KeyboardSummary(
        id: KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0310_0000),
        product: "PIXIU 75",
        manufacturer: "CHERRY",
        serialNumber: nil,
        transport: "USB",
        releaseNumber: 0x0117,
        interfaces: [
            HIDInterfaceSummary(id: 1, usages: [HIDUsage(page: 0x01, usage: 0x06)], maxInputReportSize: 8, maxOutputReportSize: 1, maxFeatureReportSize: 64, collections: []),
            HIDInterfaceSummary(id: 2, usages: [HIDUsage(page: 0x01, usage: 0x06), HIDUsage(page: 0x0C, usage: 0x01), HIDUsage(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: []),
            HIDInterfaceSummary(id: 3, usages: [HIDUsage(page: 0xFFEF, usage: 0x00)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 64, collections: []),
        ]
    )
}

extension VendorSnapshot {
    public static let preview: VendorSnapshot = {
        var status = [UInt8](repeating: 0, count: 56)
        status.replaceSubrange(0..<14, with: [0xAA, 0x55, 0, 0, 0x6A, 0x04, 0xE2, 0x01, 1, 0, 1, 0, 1, 0])
        return VendorSnapshot(
            battery: try! BatteryStatus(raw: [0x5F, 0x01, 0, 0, 0, 0]),
            status: try! DeviceStatusBlock(raw: status),
            configuration: .preview
        )
    }()
}
