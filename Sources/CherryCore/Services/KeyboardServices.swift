import CryptoKit
import Foundation

/// Opens a channel, runs `body`, and always closes the channel again.
func withChannel<T: Sendable>(
    _ provider: any ReportChannelProvider,
    keyboard: KeyboardID,
    usagePage: UInt16,
    reportID: UInt8,
    _ body: (any HIDReportChannel) async throws -> T
) async throws -> T {
    let channel = try await provider.openChannel(keyboard: keyboard, usagePage: usagePage, reportID: reportID)
    do {
        let value = try await body(channel)
        await channel.close()
        return value
    } catch {
        await channel.close()
        throw error
    }
}

/// Application service behind the "device info" screen and the menu-bar status.
public struct KeyboardInspector: Sendable {
    let channels: any ReportChannelProvider

    public init(channels: any ReportChannelProvider) {
        self.channels = channels
    }

    public func vendorSnapshot(of keyboard: KeyboardSummary) async throws -> VendorSnapshot {
        let model = try supportedModel(keyboard)
        return try await withChannel(channels, keyboard: keyboard.id, usagePage: model.vendorUsagePage, reportID: model.vendorReportID) {
            try await VendorSession(channel: $0, reportID: model.vendorReportID).snapshot(profileCount: model.profileCount)
        }
    }

    public func battery(of keyboard: KeyboardSummary) async throws -> BatteryStatus {
        let model = try supportedModel(keyboard)
        return try await withChannel(channels, keyboard: keyboard.id, usagePage: model.vendorUsagePage, reportID: model.vendorReportID) {
            try await VendorSession(channel: $0, reportID: model.vendorReportID).battery()
        }
    }

    public func firmwareStatus(of keyboard: KeyboardSummary) async throws -> DeviceFirmwareStatus {
        let model = try supportedModel(keyboard)
        return try await withChannel(channels, keyboard: keyboard.id, usagePage: model.otaUsagePage, reportID: model.otaReportID) {
            try await FirmwareFlasher(channel: $0, reportID: model.otaReportID).readFirmwareStatus()
        }
    }
}

func supportedModel(_ keyboard: KeyboardSummary) throws -> KeyboardModel {
    guard let model = keyboard.model else { throw CherryError.unsupportedModel }
    return model
}

/// Application service for changing the keyboard's onboard configuration: profile selection, lighting and sleep.
public struct KeyboardConfigurator: Sendable {
    let channels: any ReportChannelProvider

    public init(channels: any ReportChannelProvider) {
        self.channels = channels
    }

    public func configuration(of keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        let model = try supportedModel(keyboard)
        return try await session(keyboard, model) { try await $0.configuration(profileCount: model.profileCount) }
    }

    /// Activates profile `n` and returns the configuration read back from the keyboard.
    public func activateProfile(_ n: Int, on keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        let model = try supportedModel(keyboard)
        try Self.validate(profile: n, model: model)
        return try await session(keyboard, model) { session in
            try await session.activateProfile(n)
            let configuration = try await session.configuration(profileCount: model.profileCount)
            guard configuration.activeProfile == n else {
                throw CherryError.writeNotApplied("键盘仍停留在配置 \(configuration.activeProfile + 1)")
            }
            return configuration
        }
    }

    /// Changes only the patched fields of profile `n` and returns the block read back from the keyboard.
    public func update(profile n: Int, on keyboard: KeyboardSummary, patch: ProfilePatch) async throws -> ProfileConfig {
        let model = try supportedModel(keyboard)
        try Self.validate(profile: n, model: model)
        if patch.fields.contains(.effect), let effect = patch.values?.effect, model.effect(effect) == nil {
            throw CherryError.unsupportedSetting(String(format: "%@ 不支持灯效值 0x%02X", model.name, effect))
        }
        guard !patch.isEmpty else { return try await session(keyboard, model) { try await $0.profile(n) } }
        return try await session(keyboard, model) { session in
            let updated = try await session.update(profile: n, with: patch)
            let expected = patch.applied(to: updated.settings)
            guard ProfileField.differences(between: expected, and: updated.settings).isDisjoint(with: patch.fields) else {
                throw CherryError.writeNotApplied("读回的配置与写入不一致")
            }
            return updated
        }
    }

    static func validate(profile n: Int, model: KeyboardModel) throws {
        guard (0..<model.profileCount).contains(n) else {
            throw CherryError.unsupportedSetting("\(model.name) 只有 \(model.profileCount) 个配置档")
        }
    }

    private func session<T: Sendable>(
        _ keyboard: KeyboardSummary, _ model: KeyboardModel, _ body: (VendorSession) async throws -> T
    ) async throws -> T {
        try await withChannel(channels, keyboard: keyboard.id, usagePage: model.vendorUsagePage, reportID: model.vendorReportID) {
            try await body(VendorSession(channel: $0, reportID: model.vendorReportID))
        }
    }
}

/// Application service for the local preset library ("load profile").
public struct PresetLibrary: Sendable {
    let store: any ProfilePresetStore
    let now: @Sendable () -> Date

    public init(store: any ProfilePresetStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func presets() async throws -> [ProfilePreset] {
        try await store.presets()
    }

    public func save(name: String, settings: ProfileSettings, from keyboard: KeyboardSummary) async throws -> ProfilePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = ProfilePreset(
            name: trimmed.isEmpty ? "预设 \(now().formatted(date: .numeric, time: .shortened))" : trimmed,
            createdAt: now(), productID: keyboard.id.productID, settings: settings.normalized
        )
        try await store.save(preset)
        return preset
    }

    public func delete(id: UUID) async throws {
        try await store.delete(id: id)
    }

    /// Adds a preset file exported earlier (gets a fresh identity so it never overwrites an existing one).
    public func importPreset(_ data: Data) async throws -> ProfilePreset {
        var preset = try ProfilePreset.decode(data)
        preset.id = UUID()
        preset.settings = preset.settings.normalized
        try await store.save(preset)
        return preset
    }
}

/// Application service behind the firmware screen.
public struct FirmwareUpdateService: Sendable {
    let catalog: any FirmwareCatalogPort
    let downloader: any FirmwareDownloadPort
    let channels: any ReportChannelProvider
    let discovery: any KeyboardDiscoveryPort
    let timeouts: FirmwareFlasher.Timeouts

    public init(
        catalog: any FirmwareCatalogPort,
        downloader: any FirmwareDownloadPort,
        channels: any ReportChannelProvider,
        discovery: any KeyboardDiscoveryPort,
        timeouts: FirmwareFlasher.Timeouts = .init()
    ) {
        self.catalog = catalog
        self.downloader = downloader
        self.channels = channels
        self.discovery = discovery
        self.timeouts = timeouts
    }

    /// Newest catalog entry for the keyboard itself (excludes `_DONGLE` / `_POKEMON` siblings).
    public func latestRelease(for model: KeyboardModel) async throws -> FirmwareRelease? {
        Self.latestRelease(for: model, in: try await catalog.releases())
    }

    public static func latestRelease(for model: KeyboardModel, in releases: [FirmwareRelease]) -> FirmwareRelease? {
        let prefix = model.catalogName + "_"
        return releases
            .filter { $0.name.hasPrefix(prefix) && $0.name.dropFirst(prefix.count).allSatisfy(\.isNumber) }
            .max { ($0.version ?? FirmwareVersion(code: 0)) < ($1.version ?? FirmwareVersion(code: 0)) }
    }

    public func download(_ release: FirmwareRelease) async throws -> FirmwarePackage {
        let data = try await downloader.download(release)
        return try Self.makePackage(data: data, source: .catalog(release), expectedMD5: release.md5)
    }

    /// Verifies the file hash (when known), extracts the image and checks its CRC.
    public static func makePackage(data: Data, source: FirmwarePackage.Source, expectedMD5: String? = nil) throws -> FirmwarePackage {
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
        if let expectedMD5, md5 != expectedMD5.uppercased() {
            throw CherryError.checksumMismatch("文件 MD5 \(md5) ≠ 目录值 \(expectedMD5.uppercased())")
        }
        let image = try UpdaterImage(updaterExe: data)
        try image.validate()
        return FirmwarePackage(source: source, fileMD5: md5, image: image)
    }

    /// Reasons the package must not be flashed onto `keyboard` (empty = compatible).
    public static func incompatibilities(of package: FirmwarePackage, with keyboard: KeyboardSummary) -> [String] {
        var problems: [String] = []
        let image = package.image
        if image.vendorID != keyboard.id.vendorID || image.productID != keyboard.id.productID {
            problems.append(String(
                format: "升级包目标 %04X:%04X，设备为 %04X:%04X", image.vendorID, image.productID,
                keyboard.id.vendorID, keyboard.id.productID
            ))
        }
        if !keyboard.hasInterface(usagePage: image.usagePage) {
            problems.append(String(format: "设备未暴露 OTA 接口 UsagePage 0x%04X（请切换到有线模式并用 USB 线连接）", image.usagePage))
        }
        return problems
    }

    public func deviceFirmware(keyboard: KeyboardID, package: FirmwarePackage) async throws -> DeviceFirmwareStatus {
        let image = package.image
        return try await withChannel(channels, keyboard: keyboard, usagePage: image.usagePage, reportID: image.reportID) {
            try await FirmwareFlasher(channel: $0, reportID: image.reportID, timeouts: timeouts).readFirmwareStatus()
        }
    }

    public func flash(
        keyboard: KeyboardSummary,
        package: FirmwarePackage,
        progress: @Sendable (FlashProgress) async -> Void
    ) async throws -> FlashOutcome {
        let problems = Self.incompatibilities(of: package, with: keyboard)
        guard problems.isEmpty else { throw CherryError.incompatibleFirmware(problems.joined(separator: "；")) }
        let image = package.image
        let timeouts = self.timeouts
        return try await withChannel(channels, keyboard: keyboard.id, usagePage: image.usagePage, reportID: image.reportID) {
            try await FirmwareFlasher(channel: $0, reportID: image.reportID, timeouts: timeouts).flash(image, progress: progress)
        }
    }

    /// Waits for the keyboard to come back after the OTA reboot and reads its firmware CRC.
    public func verifyAfterFlash(
        keyboard: KeyboardID,
        package: FirmwarePackage,
        timeout: Duration = .seconds(60),
        pollInterval: Duration = .seconds(1)
    ) async throws -> DeviceFirmwareStatus {
        let deadline = ContinuousClock.now + timeout
        var lastError: any Error = CherryError.timeout("设备未重新连接")
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            let present = await discovery.keyboards().contains {
                $0.id == keyboard && $0.hasInterface(usagePage: package.image.usagePage)
            }
            guard present else { continue }
            do {
                return try await deviceFirmware(keyboard: keyboard, package: package)
            } catch {
                // Cancellation must end the wait; any other failure is retried until the deadline.
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}
