import CherryCore
import ComposableArchitecture
import Foundation

/// What the custom-firmware page needs; the composition root maps it onto `CustomFirmwareService` (no `liveValue`).
@DependencyClient
public struct CustomFirmwareClient: Sendable {
    public var loadDefinitions: @Sendable () async throws -> DefinitionCatalog
    /// Downloads the official updater carrying the definition's stock image and checks it byte for byte.
    public var stockPackage: @Sendable (_ definition: FirmwareDefinition) async throws -> FirmwarePackage
    /// The same check for an updater file the user picked.
    public var importStock: @Sendable (_ definition: FirmwareDefinition, _ url: URL) async throws -> FirmwarePackage
    public var variants: @Sendable () async throws -> [FirmwareVariant]
    public var flashRecords: @Sendable () async throws -> [FirmwareFlashRecord]
    public var createVariant: @Sendable (_ name: String, _ definition: FirmwareDefinition, _ copying: FirmwareVariant?) async throws -> FirmwareVariant
    public var saveVariant: @Sendable (_ variant: FirmwareVariant, _ definition: FirmwareDefinition, _ stock: FirmwarePackage?) async throws -> FirmwareVariant
    public var deleteVariant: @Sendable (_ id: UUID) async throws -> Void
    /// Builds `variant`, or prepares the stock image when `variant` is nil.
    public var prepareInstall: @Sendable (_ variant: FirmwareVariant?, _ definition: FirmwareDefinition, _ stock: FirmwarePackage) async throws -> CustomFirmwareInstall
    public var deviceFirmware: @Sendable (_ keyboard: KeyboardSummary) async throws -> DeviceFirmwareStatus
    public var flash: @Sendable (
        _ install: CustomFirmwareInstall,
        _ keyboard: KeyboardSummary,
        _ progress: @escaping @Sendable (FlashProgress) async -> Void
    ) async throws -> FlashOutcome
    /// Waits for the reboot and checks the read-back CRC; records the flash on success.
    public var verify: @Sendable (_ install: CustomFirmwareInstall, _ keyboard: KeyboardID) async throws -> DeviceFirmwareStatus
}

extension CustomFirmwareClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self()
}

extension DependencyValues {
    public var customFirmwareClient: CustomFirmwareClient {
        get { self[CustomFirmwareClient.self] }
        set { self[CustomFirmwareClient.self] = newValue }
    }
}
