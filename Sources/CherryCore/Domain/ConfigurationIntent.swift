import Foundation

/// 尚未执行的配置意图。不同配置档分别保留，同字段与激活目标采用最后值。
public struct ConfigurationIntent: Equatable, Sendable {
    public private(set) var patches: [Int: ProfilePatch]
    public private(set) var activeProfile: Int?

    public init(patches: [Int: ProfilePatch] = [:], activeProfile: Int? = nil) {
        self.patches = patches.filter { !$0.value.isEmpty }
        self.activeProfile = activeProfile
    }

    public static func activate(_ profile: Int) -> Self { .init(activeProfile: profile) }
    public static func update(_ profile: Int, patch: ProfilePatch) -> Self { .init(patches: [profile: patch]) }
    public var isEmpty: Bool { patches.isEmpty && activeProfile == nil }

    public func merging(_ newer: Self) -> Self {
        var patches = self.patches
        for (profile, patch) in newer.patches {
            patches[profile] = patches[profile].map { $0.merging(patch) } ?? patch
        }
        return .init(patches: patches, activeProfile: newer.activeProfile ?? activeProfile)
    }

    /// 即时预览用户意图；调用方仍保留已读回的配置作为权威基准。
    public func applied(to configuration: KeyboardConfiguration) -> KeyboardConfiguration {
        var result = configuration
        for profile in patches.keys.sorted() {
            guard let current = result.profile(profile), let patch = patches[profile],
                  let changed = try? ProfileConfig(profile: profile, raw: current.applying(patch)) else { continue }
            result = result.replacing(changed)
        }
        if let activeProfile,
           let activated = try? KeyboardConfiguration(activeProfile: activeProfile, profiles: result.profiles) {
            result = activated
        }
        return result
    }
}
