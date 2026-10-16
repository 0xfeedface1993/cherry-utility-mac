import Foundation

// CLI / MCP 与 App 之间的本地控制协议 v1：Unix domain socket 上按行分隔的 JSON，每行一个请求或响应。
// 线上的数值都用界面单位：配置档 1 起、速度 1…5、亮度 0…4。App 是唯一访问键盘的进程，这里只描述消息。

public enum ControlProtocol {
    public static let version = 1
    /// 一行（一个请求或响应）的上限；超过即断开连接。
    public static let maxLineLength = 64 * 1024
    /// 覆盖 socket 路径（测试与模拟模式用）。设置后 CLI 不自动启动 App。
    public static let socketEnvironmentKey = "CHERRY_CONTROL_SOCKET"
    public static let bundleIdentifier = "online.odeployer.CherryUtility"
    /// 由 CLI 启动 App 时传入：不显示主窗口。
    public static let backgroundLaunchArgument = "--background"

    /// `~/Library/Application Support/CherryUtility/control.sock`
    public static var defaultSocketPath: String {
        URL.applicationSupportDirectory
            .appending(path: "CherryUtility", directoryHint: .isDirectory)
            .appending(path: "control.sock").path(percentEncoded: false)
    }

    /// 环境变量指定的路径，否则为默认路径。
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment[socketEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSocketPath
    }
}

public enum ControlMethod: String, Codable, Sendable, CaseIterable {
    case ping, version, keyboards, status, battery, effects, presets, activateProfile, update, applyPreset
    /// 订阅自动化入口写入后的配置变化；之后这个连接只推送事件。
    case watch
}

/// 所有方法共用的参数；各方法只读取自己需要的字段。
public struct ControlParams: Codable, Equatable, Sendable {
    /// `046A:01E2@03100000`；不填时使用唯一连接的键盘。
    public var keyboard: String?
    /// 1 起；写入类方法不填时为当前配置档。
    public var profile: Int?
    /// 灯效名，中文或英文。
    public var effect: String?
    /// 0（灭）…4（全亮）。
    public var brightness: Int?
    /// 1（最慢）…5（最快）。
    public var speed: Int?
    /// `#RRGGBB` 或 `random`。
    public var color: String?
    public var sleepSeconds: Int?
    public var deepSleepMinutes: Int?
    /// 预设名称或 ID。
    public var preset: String?

    public init(
        keyboard: String? = nil, profile: Int? = nil, effect: String? = nil, brightness: Int? = nil, speed: Int? = nil,
        color: String? = nil, sleepSeconds: Int? = nil, deepSleepMinutes: Int? = nil, preset: String? = nil
    ) {
        self.keyboard = keyboard
        self.profile = profile
        self.effect = effect
        self.brightness = brightness
        self.speed = speed
        self.color = color
        self.sleepSeconds = sleepSeconds
        self.deepSleepMinutes = deepSleepMinutes
        self.preset = preset
    }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var id: Int
    public var method: ControlMethod
    public var params: ControlParams?

    public init(id: Int, method: ControlMethod, params: ControlParams? = nil) {
        v = ControlProtocol.version
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var id: Int
    public var ok: Bool
    public var result: ControlResult?
    public var error: ControlFailure?

    public static func success(_ id: Int, _ result: ControlResult) -> Self {
        Self(v: ControlProtocol.version, id: id, ok: true, result: result, error: nil)
    }

    public static func failure(_ id: Int, _ error: ControlFailure) -> Self {
        Self(v: ControlProtocol.version, id: id, ok: false, result: nil, error: error)
    }
}

/// 失败原因：`code` 供程序判断，`message` 是给人看的中文说明。
public struct ControlFailure: Codable, Equatable, Sendable, Error {
    public var code: String
    public var message: String
    /// `ambiguousKeyboard` 时列出可选的键盘。
    public var candidates: [ControlKeyboard]?

    public init(code: String, message: String, candidates: [ControlKeyboard]? = nil) {
        self.code = code
        self.message = message
        self.candidates = candidates
    }
}

public struct ControlResult: Codable, Equatable, Sendable {
    /// 与快捷指令相同的中文结果说明。
    public var message: String?
    public var version: ControlVersion?
    public var keyboards: [ControlKeyboard]?
    public var keyboard: ControlKeyboard?
    public var status: ControlStatus?
    public var battery: ControlBattery?
    public var effects: [ControlEffect]?
    public var presets: [ControlPreset]?
    /// 写入后读回的目标配置档。
    public var profile: ControlProfile?
    /// `watch` 推送的事件。
    public var change: ControlChange?

    public init(
        message: String? = nil, version: ControlVersion? = nil, keyboards: [ControlKeyboard]? = nil, keyboard: ControlKeyboard? = nil,
        status: ControlStatus? = nil, battery: ControlBattery? = nil, effects: [ControlEffect]? = nil, presets: [ControlPreset]? = nil,
        profile: ControlProfile? = nil, change: ControlChange? = nil
    ) {
        self.message = message
        self.version = version
        self.keyboards = keyboards
        self.keyboard = keyboard
        self.status = status
        self.battery = battery
        self.effects = effects
        self.presets = presets
        self.profile = profile
        self.change = change
    }
}

public struct ControlVersion: Codable, Equatable, Sendable {
    public var app: String
    public var build: String
    public var protocolVersion: Int

    public init(app: String, build: String, protocolVersion: Int = ControlProtocol.version) {
        self.app = app
        self.build = build
        self.protocolVersion = protocolVersion
    }
}

public struct ControlKeyboard: Codable, Equatable, Sendable {
    /// `046A:01E2@03100000`
    public var id: String
    public var name: String
    public var model: String?
    public var transport: String
    public var firmware: String
    /// 是否有配置接口（蓝牙连接时没有）。
    public var configurable: Bool

    public init(id: String, name: String, model: String?, transport: String, firmware: String, configurable: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.transport = transport
        self.firmware = firmware
        self.configurable = configurable
    }
}

public struct ControlBattery: Codable, Equatable, Sendable {
    public var percent: Int
    /// nil：键盘报告了未知的充电状态。
    public var charging: Bool?

    public init(percent: Int, charging: Bool?) {
        self.percent = percent
        self.charging = charging
    }
}

/// 一个配置档。型号不支持的字段为 nil（例如无背光型号没有灯效，有线型号没有休眠）。
public struct ControlProfile: Codable, Equatable, Sendable {
    /// 1 起。
    public var profile: Int
    public var effect: String?
    public var effectEnglishName: String?
    public var brightness: Int?
    /// 1…5。
    public var speed: Int?
    /// `#RRGGBB`
    public var color: String?
    public var randomColor: Bool?
    public var sleepSeconds: Int?
    public var deepSleepMinutes: Int?

    public init(
        profile: Int, effect: String? = nil, effectEnglishName: String? = nil, brightness: Int? = nil, speed: Int? = nil,
        color: String? = nil, randomColor: Bool? = nil, sleepSeconds: Int? = nil, deepSleepMinutes: Int? = nil
    ) {
        self.profile = profile
        self.effect = effect
        self.effectEnglishName = effectEnglishName
        self.brightness = brightness
        self.speed = speed
        self.color = color
        self.randomColor = randomColor
        self.sleepSeconds = sleepSeconds
        self.deepSleepMinutes = deepSleepMinutes
    }
}

public struct ControlStatus: Codable, Equatable, Sendable {
    public var keyboard: ControlKeyboard
    public var battery: ControlBattery?
    public var connection: String
    /// 1 起；没有配置接口时为 nil。
    public var activeProfile: Int?
    public var profiles: [ControlProfile]?
    public var summary: String

    public init(
        keyboard: ControlKeyboard, battery: ControlBattery?, connection: String, activeProfile: Int?, profiles: [ControlProfile]?, summary: String
    ) {
        self.keyboard = keyboard
        self.battery = battery
        self.connection = connection
        self.activeProfile = activeProfile
        self.profiles = profiles
        self.summary = summary
    }
}

public struct ControlEffect: Codable, Equatable, Sendable {
    public var name: String
    public var englishName: String

    public init(name: String, englishName: String) {
        self.name = name
        self.englishName = englishName
    }
}

public struct ControlPreset: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// 预设来自的型号；nil 表示适用于任何型号。
    public var model: String?
    public var createdAt: Date

    public init(id: String, name: String, model: String?, createdAt: Date) {
        self.id = id
        self.name = name
        self.model = model
        self.createdAt = createdAt
    }
}

public struct ControlChange: Codable, Equatable, Sendable {
    public var keyboard: String
    public var activeProfile: Int
    public var profiles: [ControlProfile]

    public init(keyboard: String, activeProfile: Int, profiles: [ControlProfile]) {
        self.keyboard = keyboard
        self.activeProfile = activeProfile
        self.profiles = profiles
    }
}
