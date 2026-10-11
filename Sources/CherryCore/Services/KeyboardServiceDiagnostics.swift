import Foundation

// 服务只命名操作；origin 由驱动侧通过父 trace 或 `DiagnosticOrigin.current` 提供。
extension KeyboardInspector {
    public func vendorSnapshot(of keyboard: KeyboardSummary) async throws -> VendorSnapshot {
        try await diagnostics.measure(.snapshot) { try await vendorSnapshotImpl(of: keyboard) }
    }
    public func battery(of keyboard: KeyboardSummary) async throws -> BatteryStatus {
        try await diagnostics.measure(.battery) { try await batteryImpl(of: keyboard) }
    }
    public func firmwareStatus(of keyboard: KeyboardSummary) async throws -> DeviceFirmwareStatus {
        try await diagnostics.measure(.firmwareStatus) { try await firmwareStatusImpl(of: keyboard) }
    }
}

extension KeyboardConfigurator {
    public func configuration(of keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        try await diagnostics.measure(.configurationRead) { try await configurationImpl(of: keyboard) }
    }
    public func activateProfile(_ n: Int, on keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        try await diagnostics.measure(.profileActivate, metrics: .init(profile: n)) { try await activateProfileImpl(n, on: keyboard) }
    }
    public func update(profile n: Int, on keyboard: KeyboardSummary, patch: ProfilePatch) async throws -> ProfileConfig {
        try await diagnostics.measure(.configurationWrite, metrics: .init(profile: n), outcome: { $0.written ? .success : .noChange }) {
            try await updateImpl(profile: n, on: keyboard, patch: patch)
        }.config
    }
}

extension FirmwareUpdateService {
    public func download(_ release: FirmwareRelease) async throws -> FirmwarePackage {
        try await diagnostics.measure(.firmwareDownload) { try await downloadImpl(release) }
    }
    public func deviceFirmware(keyboard: KeyboardID, package: FirmwarePackage) async throws -> DeviceFirmwareStatus {
        try await diagnostics.measure(.firmwareStatus) { try await deviceFirmwareImpl(keyboard: keyboard, package: package) }
    }
    public func flash(keyboard: KeyboardSummary, package: FirmwarePackage, progress: @Sendable (FlashProgress) async -> Void) async throws -> FlashOutcome {
        try await diagnostics.measure(.firmwareFlash, outcome: DiagnosticOutcome.init) {
            try await flashImpl(keyboard: keyboard, package: package, progress: progress)
        }
    }
    public func verifyAfterFlash(keyboard: KeyboardID, package: FirmwarePackage, timeout: Duration = .seconds(60), pollInterval: Duration = .seconds(1)) async throws -> DeviceFirmwareStatus {
        try await diagnostics.measure(.reconnectionVerify) {
            try await verifyAfterFlashImpl(keyboard: keyboard, package: package, timeout: timeout, pollInterval: pollInterval)
        }
    }
}

extension DiagnosticOutcome {
    init(_ outcome: FlashOutcome) {
        switch outcome {
        case .confirmed: self = .success
        case .unconfirmed: self = .unconfirmed
        case .deviceRebooted: self = .deviceRebooted
        }
    }
}
