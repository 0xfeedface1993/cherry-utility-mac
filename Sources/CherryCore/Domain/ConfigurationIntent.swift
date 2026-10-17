import Foundation

/// 尚未执行的配置意图。不同配置档分别保留，同字段与激活目标采用最后值。
///
/// `activePatch` 写到执行时的当前档：自动化入口不指定配置档时由写入事务在通道内落位，不必先单独读一次配置。
/// 同一批里若还有切换，它落在切换后的那一档（同批的请求彼此并发，没有先后，这是其中一种合法的顺序）。
public struct ConfigurationIntent: Equatable, Sendable {
    public private(set) var patches: [Int: ProfilePatch]
    public private(set) var activeProfile: Int?
    public private(set) var activePatch: ProfilePatch?

    public init(patches: [Int: ProfilePatch] = [:], activeProfile: Int? = nil, activePatch: ProfilePatch? = nil) {
        self.patches = patches.filter { !$0.value.isEmpty }
        self.activeProfile = activeProfile
        self.activePatch = activePatch?.isEmpty == false ? activePatch : nil
    }

    public static func activate(_ profile: Int) -> Self { .init(activeProfile: profile) }
    public static func update(_ profile: Int, patch: ProfilePatch) -> Self { .init(patches: [profile: patch]) }
    public static func updateActive(patch: ProfilePatch) -> Self { .init(activePatch: patch) }
    public var isEmpty: Bool { patches.isEmpty && activeProfile == nil && activePatch == nil }

    public func merging(_ newer: Self) -> Self {
        var patches = self.patches
        for (profile, patch) in newer.patches {
            patches[profile] = patches[profile].map { $0.merging(patch) } ?? patch
        }
        let active = activePatch.map { older in newer.activePatch.map(older.merging) ?? older } ?? newer.activePatch
        return .init(patches: patches, activeProfile: newer.activeProfile ?? activeProfile, activePatch: active)
    }

    /// `activePatch` 落到本批执行后的当前档（`currentProfile` 是执行前读到的当前档），叠在该档的显式补丁之上。
    public func resolved(currentProfile: Int) -> Self {
        guard let activePatch else { return self }
        let target = activeProfile ?? currentProfile
        var patches = self.patches
        patches[target] = patches[target].map { $0.merging(activePatch) } ?? activePatch
        return .init(patches: patches, activeProfile: activeProfile)
    }

    /// 即时预览用户意图；调用方仍保留已读回的配置作为权威基准。
    public func applied(to configuration: KeyboardConfiguration) -> KeyboardConfiguration {
        let intent = resolved(currentProfile: configuration.activeProfile)
        var result = configuration
        for profile in intent.patches.keys.sorted() {
            guard let current = result.profile(profile), let patch = intent.patches[profile],
                  let changed = try? ProfileConfig(profile: profile, raw: current.applying(patch)) else { continue }
            result = result.replacing(changed)
        }
        if let activeProfile = intent.activeProfile,
           let activated = try? KeyboardConfiguration(activeProfile: activeProfile, profiles: result.profiles) {
            result = activated
        }
        return result
    }
}
