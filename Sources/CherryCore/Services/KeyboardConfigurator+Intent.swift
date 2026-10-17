import Foundation

extension KeyboardConfigurator {
    private struct IntentResult: Sendable {
        let configuration: KeyboardConfiguration
        let written: Bool
    }

    /// 一次通道占用内读、合并、写、校验整批意图，其他页面不能插入半个事务。
    public func apply(_ intent: ConfigurationIntent, on keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        let model = try supportedModel(keyboard)
        for (profile, patch) in intent.patches {
            try Self.validate(profile: profile, model: model)
            try Self.validate(patch: patch, model: model)
        }
        if let patch = intent.activePatch { try Self.validate(patch: patch, model: model) }
        if let profile = intent.activeProfile { try Self.validate(profile: profile, model: model) }
        let activatesOnly = intent.patches.isEmpty && intent.activePatch == nil && intent.activeProfile != nil
        let operation: DiagnosticOperation = activatesOnly ? .profileActivate : .configurationWrite
        return try await diagnostics.measure(operation, outcome: { (result: IntentResult) in result.written ? .success : .noChange }) {
            try await session(keyboard, model) { session in
                let current = try await session.configuration(profileCount: model.profileCount)
                // 未指定配置档的补丁按通道内读到的当前档落位，其他页面不能在读与写之间插入切换。
                let resolved = intent.resolved(currentProfile: current.activeProfile)
                let expected = resolved.applied(to: current)
                let changed = resolved.patches.keys.sorted().flatMap { profile -> [(Int, [UInt8], Range<Int>)] in
                    guard let source = current.profile(profile), let target = expected.profile(profile) else { return [] }
                    return source.changedRanges(to: target.raw).map { (profile, target.raw, $0) }
                }
                let activates = expected.activeProfile != current.activeProfile
                guard !changed.isEmpty || activates else { return IntentResult(configuration: current, written: false) }
                try await session.transaction {
                    for (profile, bytes, range) in changed {
                        try await session.write(Array(bytes[range]), at: profile * ProfileConfig.blockSize + range.lowerBound)
                    }
                    if activates { try await session.write([UInt8(expected.activeProfile)], at: 0) }
                }
                let saved = try await diagnostics.measure(.configurationReadBack) {
                    try await session.configuration(profileCount: model.profileCount)
                }
                guard resolved.activeProfile == nil || saved.activeProfile == expected.activeProfile else {
                    throw CherryError.writeNotApplied("键盘未切换到指定配置档")
                }
                for (profile, patch) in resolved.patches {
                    guard let actual = saved.profile(profile), let target = expected.profile(profile),
                          ProfileField.differences(between: actual.settings, and: target.settings).isDisjoint(with: patch.fields) else {
                        throw CherryError.writeNotApplied("读回的配置与写入不一致")
                    }
                }
                return IntentResult(configuration: saved, written: true)
            }
        }.configuration
    }
}
