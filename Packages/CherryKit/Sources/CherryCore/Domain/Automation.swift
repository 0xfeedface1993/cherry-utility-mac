import Foundation

/// 自动化请求（快捷指令、Spotlight，之后的 CLI / MCP）在到达键盘之前被拒绝的原因。
/// 设备与协议层面的失败仍是 `CherryError`；文案由驱动侧映射。配置档编号从 0 开始。
public enum AutomationError: Error, Equatable, Sendable {
    /// 没有连接受支持的键盘。
    case noKeyboard
    /// 连接了多把可配置的键盘，又没有指定其中一把。
    case ambiguousKeyboard([KeyboardSummary])
    case fieldUnsupported(ProfileField, model: KeyboardModel)
    case unknownEffect(String, model: KeyboardModel)
    case valueOutOfRange(ProfileField, Int)
    case profileOutOfRange(Int, model: KeyboardModel)
    case noBattery(model: KeyboardModel)
    case invalidColor(String)
    case presetNotFound(UUID)
    case presetIncompatible(name: String)
    case nothingToChange
    /// 这把键盘正在刷写固件；刷写期间不接受配置写入。
    case firmwareUpdateInProgress
    /// 用户在 App 的「设置 › 自动化」里关闭了这个入口。
    case entryDisabled(AutomationEntry)
}

/// 一次设置请求：只写出现的字段，其余保持键盘上的值。数值用 Core 单位（亮度、速度 0…4）。
public struct SettingsRequest: Equatable, Sendable {
    public enum Color: Equatable, Sendable {
        case fixed(LEDColor)
        case random

        /// `#RRGGBB`、`RRGGBB`，或 `random` / `随机`。
        public init(parsing text: String) throws {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if ["random", "随机"].contains(trimmed.lowercased()) {
                self = .random
            } else if let color = LEDColor(hex: trimmed) {
                self = .fixed(color)
            } else {
                throw AutomationError.invalidColor(text)
            }
        }
    }

    /// Effect name (English or Chinese), resolved against the target keyboard's table.
    public var effect: String?
    public var brightness: Int?
    public var speed: Int?
    public var color: Color?
    /// 0 = never, otherwise seconds.
    public var sleepSeconds: Int?
    /// 0 = never, otherwise minutes.
    public var deepSleepMinutes: Int?

    public init(
        effect: String? = nil, brightness: Int? = nil, speed: Int? = nil, color: Color? = nil, sleepSeconds: Int? = nil,
        deepSleepMinutes: Int? = nil
    ) {
        self.effect = effect
        self.brightness = brightness
        self.speed = speed
        self.color = color
        self.sleepSeconds = sleepSeconds
        self.deepSleepMinutes = deepSleepMinutes
    }

    public var isEmpty: Bool { self == SettingsRequest() }
}

/// 键盘当前状态：USB 信息，加上可配置时读到的电量、连接方式和全部配置档。
public struct KeyboardStatusReport: Equatable, Sendable {
    public let keyboard: KeyboardSummary
    public let model: KeyboardModel
    /// nil when the keyboard exposes no configuration interface (e.g. connected over Bluetooth).
    public let snapshot: VendorSnapshot?

    public init(keyboard: KeyboardSummary, model: KeyboardModel, snapshot: VendorSnapshot?) {
        self.keyboard = keyboard
        self.model = model
        self.snapshot = snapshot
    }
}

/// 写入并读回校验后的结果。
public struct AutomationResult: Equatable, Sendable {
    public let keyboard: KeyboardSummary
    public let model: KeyboardModel
    public let configuration: KeyboardConfiguration
    /// The profile the request targeted (0-based).
    public let profile: Int

    public init(keyboard: KeyboardSummary, model: KeyboardModel, configuration: KeyboardConfiguration, profile: Int) {
        self.keyboard = keyboard
        self.model = model
        self.configuration = configuration
        self.profile = profile
    }

    public var settings: ProfileSettings? { configuration.profile(profile)?.settings }
}

/// 界面之外（自动化入口）写入并读回的配置，供菜单栏和主窗口同步。
public struct ExternalConfigurationChange: Equatable, Sendable {
    public let keyboardID: KeyboardID
    public let change: ConfigurationChange

    public init(keyboardID: KeyboardID, change: ConfigurationChange) {
        self.keyboardID = keyboardID
        self.change = change
    }
}
