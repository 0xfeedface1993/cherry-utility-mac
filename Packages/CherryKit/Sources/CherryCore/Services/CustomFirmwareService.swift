import CryptoKit
import Foundation

/// Definitions that loaded, plus the files that were rejected (shown to the user, never fatal).
public struct DefinitionCatalog: Equatable, Sendable {
    public let definitions: [FirmwareDefinition]
    public let rejected: [CustomFirmwareError]

    public init(definitions: [FirmwareDefinition], rejected: [CustomFirmwareError]) {
        self.definitions = definitions
        self.rejected = rejected
    }

    public func definitions(for model: KeyboardModel) -> [FirmwareDefinition] {
        definitions.filter { $0.applies(to: model) }.sorted { $0.firmware.versionCode > $1.firmware.versionCode }
    }
}

/// An image ready to be flashed by the custom-firmware page: a variant's build, or the stock image to restore.
public struct CustomFirmwareInstall: Equatable, Sendable {
    public let definitionID: String
    public let package: FirmwarePackage
    /// nil when restoring the stock image.
    public let variant: FirmwareVariant?

    public init(definitionID: String, package: FirmwarePackage, variant: FirmwareVariant?) {
        self.definitionID = definitionID
        self.package = package
        self.variant = variant
    }

    public var expectedCRC: UInt32 { package.image.embeddedCRC }
}

/// Application service behind the custom-firmware page. Flashing and the reboot check reuse `FirmwareUpdateService`,
/// so a custom image goes through exactly the same OTA, compatibility check and read-back as an official one.
public struct CustomFirmwareService: Sendable {
    let firmware: FirmwareUpdateService
    let definitionSource: any FirmwareDefinitionSource
    let variantStore: any FirmwareVariantStore
    let flashLog: any FirmwareFlashLog
    let now: @Sendable () -> Date

    public init(
        firmware: FirmwareUpdateService,
        definitions: any FirmwareDefinitionSource,
        variants: any FirmwareVariantStore,
        flashLog: any FirmwareFlashLog,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.firmware = firmware
        definitionSource = definitions
        variantStore = variants
        self.flashLog = flashLog
        self.now = now
    }

    // MARK: Definitions and stock image

    /// A user definition replaces a bundled one with the same ID; invalid files are reported, not thrown.
    public func loadDefinitions() async throws -> DefinitionCatalog {
        let documents = try await definitionSource.documents()
        var byID: [String: (definition: FirmwareDefinition, origin: FirmwareDefinitionDocument.Origin)] = [:]
        var order: [String] = []
        var rejected: [CustomFirmwareError] = []
        for document in documents.sorted(by: { ($0.origin == .bundled ? 0 : 1, $0.name) < ($1.origin == .bundled ? 0 : 1, $1.name) }) {
            do {
                let definition = try FirmwareDefinition.decode(document.data, source: document.name)
                if let existing = byID[definition.id], existing.origin == document.origin {
                    rejected.append(.invalidDefinition(source: document.name, issues: [.duplicateID(definition.id)]))
                    continue
                }
                if byID[definition.id] == nil { order.append(definition.id) }
                byID[definition.id] = (definition, document.origin)
            } catch let error as CustomFirmwareError {
                rejected.append(error)
            }
        }
        return DefinitionCatalog(definitions: order.compactMap { byID[$0]?.definition }, rejected: rejected)
    }

    /// Downloads the official updater carrying the definition's stock image (MD5- and CRC-checked) and confirms it is
    /// byte-for-byte the image the definition was written for.
    public func stockPackage(for definition: FirmwareDefinition) async throws -> FirmwarePackage {
        let releases = try await firmware.catalog.releases()
        guard let release = releases.first(where: { $0.name.caseInsensitiveCompare(definition.firmware.catalogName) == .orderedSame }) else {
            throw CustomFirmwareError.stockNotInCatalog(definition.firmware.catalogName)
        }
        let package = try await firmware.download(release)
        try Self.verifyStock(package, for: definition)
        return package
    }

    /// The same check for an updater file the user picked.
    public func stockPackage(for definition: FirmwareDefinition, localData data: Data, url: URL) throws -> FirmwarePackage {
        let package = try firmware.loadLocal(data, from: url)
        try Self.verifyStock(package, for: definition)
        return package
    }

    static func verifyStock(_ package: FirmwarePackage, for definition: FirmwareDefinition) throws {
        guard definition.firmware.matches(package.image) else {
            throw CustomFirmwareError.stockMismatch(expectedCRC: definition.firmware.crc, actualCRC: package.image.embeddedCRC)
        }
        let mismatches = FirmwarePatcher.mismatches(of: definition, in: package.image)
        guard mismatches.isEmpty else { throw CustomFirmwareError.invalidDefinition(source: definition.id, issues: mismatches) }
    }

    // MARK: Variants

    /// Oldest first, so new variants appear at the end of the list.
    public func variants() async throws -> [FirmwareVariant] {
        try await variantStore.variants().sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// A new variant with stock choices, or a copy of `source`.
    public func createVariant(named name: String, for definition: FirmwareDefinition, copying source: FirmwareVariant? = nil) async throws -> FirmwareVariant {
        if let source, source.definitionID != definition.id {
            throw CustomFirmwareError.variantDefinitionMismatch(variant: source.name, definition: definition.id)
        }
        let date = now()
        let variant = FirmwareVariant(
            name: try Self.validName(name), definitionID: definition.id, selections: source?.selections ?? [:],
            createdAt: date, builtCRC: source?.builtCRC
        )
        try await variantStore.save(variant)
        return variant
    }

    /// Normalizes the selections and stores the variant. With the stock image at hand the build CRC is refreshed, so
    /// the variant is recognised on a keyboard later; otherwise a stale CRC is dropped.
    public func save(_ variant: FirmwareVariant, definition: FirmwareDefinition, stock: FirmwarePackage?) async throws -> FirmwareVariant {
        guard variant.definitionID == definition.id else {
            throw CustomFirmwareError.variantDefinitionMismatch(variant: variant.name, definition: definition.id)
        }
        var saved = variant
        saved.name = try Self.validName(variant.name)
        saved.selections = definition.normalized(variant.selections)
        saved.updatedAt = now()
        if let stock {
            saved.builtCRC = try build(saved.selections, definition: definition, stock: stock).crc
        } else {
            let stored = try await variantStore.variants().first { $0.id == variant.id }
            saved.builtCRC = stored?.selections == saved.selections ? stored?.builtCRC : nil
        }
        try await variantStore.save(saved)
        return saved
    }

    public func deleteVariant(id: UUID) async throws {
        try await variantStore.delete(id: id)
    }

    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomFirmwareError.invalidVariant("name") }
        return trimmed
    }

    // MARK: Build, flash, verify

    /// Builds a saved variant. Selections the definition does not know block the build.
    public func install(variant: FirmwareVariant, definition: FirmwareDefinition, stock: FirmwarePackage) throws -> CustomFirmwareInstall {
        guard variant.definitionID == definition.id else {
            throw CustomFirmwareError.variantDefinitionMismatch(variant: variant.name, definition: definition.id)
        }
        try Self.verifyStock(stock, for: definition)
        let build = try build(variant.selections, definition: definition, stock: stock)
        let md5 = Insecure.MD5.hash(data: Data(build.image.firmware)).map { String(format: "%02X", $0) }.joined()
        let package = FirmwarePackage(source: .customBuild(variantID: variant.id, name: variant.name), fileMD5: md5, image: build.image)
        return CustomFirmwareInstall(definitionID: definition.id, package: package, variant: variant)
    }

    /// Restores the definition's stock image.
    public func restoreStock(definition: FirmwareDefinition, stock: FirmwarePackage) throws -> CustomFirmwareInstall {
        try Self.verifyStock(stock, for: definition)
        return CustomFirmwareInstall(definitionID: definition.id, package: stock, variant: nil)
    }

    /// `variant`'s build, or the stock image when `variant` is nil.
    public func prepareInstall(_ variant: FirmwareVariant?, definition: FirmwareDefinition, stock: FirmwarePackage) throws -> CustomFirmwareInstall {
        if let variant { return try install(variant: variant, definition: definition, stock: stock) }
        return try restoreStock(definition: definition, stock: stock)
    }

    private func build(_ selections: [String: String], definition: FirmwareDefinition, stock: FirmwarePackage) throws -> CustomFirmwareBuild {
        try firmware.diagnostics.measure(.customFirmwareBuild, metrics: .init(bytes: UInt64(stock.image.firmware.count))) {
            try FirmwarePatcher.build(selections, definition: definition, stock: stock.image)
        }
    }

    public func flash(
        _ install: CustomFirmwareInstall,
        on keyboard: KeyboardSummary,
        progress: @Sendable (FlashProgress) async -> Void
    ) async throws -> FlashOutcome {
        try await firmware.flash(keyboard: keyboard, package: install.package, progress: progress)
    }

    /// Waits for the reboot, reads the image CRC back and, when it is the expected image, records the flash and
    /// refreshes the variant's build CRC.
    public func verify(
        _ install: CustomFirmwareInstall, on keyboard: KeyboardID, timeout: Duration = .seconds(60), pollInterval: Duration = .seconds(1)
    ) async throws -> DeviceFirmwareStatus {
        let status = try await firmware.verifyAfterFlash(keyboard: keyboard, package: install.package, timeout: timeout, pollInterval: pollInterval)
        guard status.crc == install.expectedCRC else {
            throw CustomFirmwareError.verificationMismatch(expectedCRC: install.expectedCRC, actualCRC: status.crc)
        }
        try await flashLog.append(FirmwareFlashRecord(
            date: now(), keyboard: keyboard, definitionID: install.definitionID, crc: status.crc,
            variantID: install.variant?.id, variantName: install.variant?.name, selections: install.variant?.selections ?? [:]
        ))
        if var variant = install.variant, variant.builtCRC != status.crc,
           let current = try await variantStore.variants().first(where: { $0.id == variant.id }),
           current.selections == variant.selections {
            variant = current
            variant.builtCRC = status.crc
            try await variantStore.save(variant)
        }
        return status
    }

    public func flashRecords() async throws -> [FirmwareFlashRecord] {
        try await flashLog.records()
    }
}

extension CoreServices {
    /// The custom-firmware service on top of this assembly's firmware service (same channel queue, catalog cache and
    /// observation).
    public func customFirmware(
        definitions: any FirmwareDefinitionSource,
        variants: any FirmwareVariantStore,
        flashLog: any FirmwareFlashLog,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> CustomFirmwareService {
        CustomFirmwareService(firmware: firmware, definitions: definitions, variants: variants, flashLog: flashLog, now: now)
    }
}
