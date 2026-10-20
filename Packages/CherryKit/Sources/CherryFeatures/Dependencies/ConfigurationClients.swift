import CherryCore
import ComposableArchitecture
import Foundation

/// Onboard configuration of a keyboard: profiles, lighting, sleep.
@DependencyClient
public struct ConfigurationClient: Sendable {
    public var configuration: @Sendable (_ keyboard: KeyboardSummary) async throws -> KeyboardConfiguration
    /// Activates a profile and returns the configuration read back from the keyboard.
    public var activateProfile: @Sendable (_ profile: Int, _ keyboard: KeyboardSummary) async throws -> KeyboardConfiguration
    /// Writes only the patched fields of a profile and returns the block read back from the keyboard.
    public var updateProfile: @Sendable (_ profile: Int, _ keyboard: KeyboardSummary, _ patch: ProfilePatch) async throws -> ProfileConfig
    /// Core 按设备串行、合并尚未执行的意图，返回经过校验的整批配置。
    public var applyIntent: @Sendable (_ intent: ConfigurationIntent, _ keyboard: KeyboardSummary) async throws -> KeyboardConfiguration
}

/// Local preset library.
@DependencyClient
public struct PresetClient: Sendable {
    public var presets: @Sendable () async throws -> [ProfilePreset]
    public var save: @Sendable (_ name: String, _ settings: ProfileSettings, _ keyboard: KeyboardSummary) async throws -> ProfilePreset
    public var delete: @Sendable (_ id: UUID) async throws -> Void
    /// Adds a preset from an exported file.
    public var importFile: @Sendable (_ url: URL) async throws -> ProfilePreset
}

extension ConfigurationClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(
        configuration: { _ in .preview },
        activateProfile: { n, _ in try KeyboardConfiguration(activeProfile: n, profiles: KeyboardConfiguration.preview.profiles) },
        updateProfile: { n, _, patch in
            let current = KeyboardConfiguration.preview.profile(n) ?? KeyboardConfiguration.preview.active
            return try ProfileConfig(profile: n, raw: current.applying(patch))
        },
        applyIntent: { intent, _ in intent.applied(to: .preview) }
    )
}

extension PresetClient: TestDependencyKey {
    public static let testValue = Self()
    public static let previewValue = Self(
        presets: { [.preview] },
        save: { name, settings, keyboard in
            ProfilePreset(name: name, createdAt: Date(), productID: keyboard.id.productID, settings: settings)
        },
        delete: { _ in },
        importFile: { _ in .preview }
    )
}

extension DependencyValues {
    public var configurationClient: ConfigurationClient {
        get { self[ConfigurationClient.self] }
        set { self[ConfigurationClient.self] = newValue }
    }

    public var presetClient: PresetClient {
        get { self[PresetClient.self] }
        set { self[PresetClient.self] = newValue }
    }
}

// MARK: - Preview fixtures (profile blocks captured from a real PIXIU 75, 2026-10-11)

extension KeyboardConfiguration {
    public static let preview: KeyboardConfiguration = {
        func block(_ head: [UInt8], extra: [Int: UInt8] = [:]) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 64)
            b.replaceSubrange(0..<head.count, with: head)
            b[0x19] = 0xFF
            b.replaceSubrange(0x22..<0x26, with: [0x2C, 0x01, 0x1E, 0x00])
            for (k, v) in extra { b[k] = v }
            return b
        }
        return try! KeyboardConfiguration(activeProfile: 1, profiles: [
            ProfileConfig(profile: 0, raw: block([0x01, 0x12, 0x04, 0x02, 0x00, 0x00, 0x33, 0xFF, 0x33], extra: [0x14: 1])),
            ProfileConfig(profile: 1, raw: block([0x01, 0x00, 0x04, 0x03, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])),
            ProfileConfig(profile: 2, raw: block([0x00, 0x03, 0x04, 0x02, 0x00, 0xFF, 0x00, 0x00, 0xFF])),
        ])
    }()
}

extension ProfilePreset {
    public static let preview = ProfilePreset(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!,
        name: "夜间蓝光",
        createdAt: Date(timeIntervalSince1970: 1_791_000_000),
        productID: 0x01E2,
        settings: ProfileSettings(
            effect: 2, brightness: 1, speed: 1, randomColor: false, color: LEDColor(r: 0x00, g: 0x99, b: 0xFF),
            sleepSeconds: 120, deepSleepMinutes: 30
        )
    )
}
