/// 已经通过设备读回验证的配置变化。接收者保留电量、设备状态和未编辑字段。
public enum ConfigurationChange: Equatable, Sendable {
    case profile(ProfileConfig)
    case configuration(KeyboardConfiguration)

    public func applied(to current: KeyboardConfiguration) -> KeyboardConfiguration {
        switch self {
        case .profile(let profile): current.replacing(profile)
        case .configuration(let configuration): configuration
        }
    }
}
