import Foundation

extension KeyboardInspector {
    public func vendorSnapshot(of keyboard: KeyboardSummary) async throws -> VendorSnapshot {
        try await diagnostics.measure(.snapshot) { try await vendorSnapshotImpl(of: keyboard) }
    }
    public func battery(of keyboard: KeyboardSummary) async throws -> BatteryStatus {
        try await diagnostics.measure(.battery) { try await batteryImpl(of: keyboard) }
    }
    public func firmwareStatus(of keyboard: KeyboardSummary) async throws -> DeviceFirmwareStatus {
        try await diagnostics.measure(.firmwareStatus, origin: .firmware) { try await firmwareStatusImpl(of: keyboard) }
    }
}

extension KeyboardConfigurator {
    public func configuration(of keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        try await diagnostics.measure(.configurationRead, origin: .configuration) { try await configurationImpl(of: keyboard) }
    }
    public func activateProfile(_ n: Int, on keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        try await diagnostics.measure(.profileActivate, origin: .configuration, metrics: .init(profile: n)) { try await activateProfileImpl(n, on: keyboard) }
    }
    public func update(profile n: Int, on keyboard: KeyboardSummary, patch: ProfilePatch) async throws -> ProfileConfig {
        try await diagnostics.measure(.configurationWrite, origin: .configuration, metrics: .init(profile: n)) { try await updateImpl(profile: n, on: keyboard, patch: patch) }
    }
}

extension FirmwareUpdateService {
    public func download(_ release: FirmwareRelease) async throws -> FirmwarePackage {
        try await diagnostics.measure(.firmwareDownload, origin: .firmware) { try await downloadImpl(release) }
    }
    public func deviceFirmware(keyboard: KeyboardID, package: FirmwarePackage) async throws -> DeviceFirmwareStatus {
        try await diagnostics.measure(.firmwareStatus, origin: .firmware) { try await deviceFirmwareImpl(keyboard: keyboard, package: package) }
    }
    public func flash(keyboard: KeyboardSummary, package: FirmwarePackage, progress: @Sendable (FlashProgress) async -> Void) async throws -> FlashOutcome {
        let span = diagnostics.begin(.firmwareFlash, origin: .firmware)
        do {
            let value = try await TraceContext.$current.withValue(span.context) { try await flashImpl(keyboard: keyboard, package: package, progress: progress) }
            span.finish(DiagnosticOutcome(value))
            return value
        } catch { span.finish(error: error); throw error }
    }
    public func verifyAfterFlash(keyboard: KeyboardID, package: FirmwarePackage, timeout: Duration = .seconds(60), pollInterval: Duration = .seconds(1)) async throws -> DeviceFirmwareStatus {
        try await diagnostics.measure(.reconnectionVerify, origin: .firmware) {
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
