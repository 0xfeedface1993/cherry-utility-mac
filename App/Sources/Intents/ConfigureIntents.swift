import AppIntents
import CherryCore
import CherryFeatures
import Foundation

// 写入类意图：未选配置档时修改当前配置档，未选键盘时使用唯一连接的键盘。
// 只写请求的字段，经共享写入队列执行并读回校验；固件刷写与自定义固件不开放给自动化。

struct SwitchProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "切换配置档"
    static let description = IntentDescription("把 CHERRY 键盘切换到指定的板载配置档。", categoryName: "键盘", searchKeywords: ["配置", "profile"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "配置档")
    var profile: ProfileSlot

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("切换到\(\.$profile)") { \.$keyboard }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await automated { try await automation.activate(profile: profile.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.activated(result))")
    }
}

struct SetLightingEffectIntent: AppIntent {
    static let title: LocalizedStringResource = "设置灯效"
    static let description = IntentDescription("设置配置档的背光灯效。不同型号支持的灯效不同。", categoryName: "键盘", searchKeywords: ["背光", "灯光"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "灯效")
    var effect: LightingEffectOption

    @Parameter(title: "配置档", description: "不选时修改当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("把灯效设为\(\.$effect)") {
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = SettingsRequest(effect: effect.rawValue)
        let result = try await automated { try await automation.update(request, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.updated(result, request: request))")
    }
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "设置背光亮度"
    static let description = IntentDescription("设置配置档的背光亮度（灭、低、中、高、全亮）。", categoryName: "键盘", searchKeywords: ["背光", "亮度"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "亮度")
    var brightness: BrightnessLevel

    @Parameter(title: "配置档", description: "不选时修改当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("把背光亮度设为\(\.$brightness)") {
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = SettingsRequest(brightness: brightness.value)
        let result = try await automated { try await automation.update(request, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.updated(result, request: request))")
    }
}

struct TurnOffBacklightIntent: AppIntent {
    static let title: LocalizedStringResource = "关闭背光"
    static let description = IntentDescription("把配置档的背光亮度设为「灭」。", categoryName: "键盘", searchKeywords: ["关灯", "背光"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "配置档", description: "不选时修改当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("关闭背光") {
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = SettingsRequest(brightness: BrightnessLevel.off.value)
        let result = try await automated { try await automation.update(request, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.updated(result, request: request))")
    }
}

struct SetLightingSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "设置灯效速度"
    static let description = IntentDescription("设置配置档的灯效速度（1 最慢，5 最快）。", categoryName: "键盘", searchKeywords: ["速度", "灯效"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "速度")
    var speed: SpeedLevel

    @Parameter(title: "配置档", description: "不选时修改当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("把灯效速度设为\(\.$speed)") {
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = SettingsRequest(speed: speed.value)
        let result = try await automated { try await automation.update(request, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.updated(result, request: request))")
    }
}

struct SetLightingColorIntent: AppIntent {
    static let title: LocalizedStringResource = "设置灯光颜色"
    static let description = IntentDescription(
        "设置 RGB 键盘配置档的灯光颜色：调色板颜色、随机颜色，或自定义十六进制颜色。", categoryName: "键盘", searchKeywords: ["颜色", "RGB"]
    )
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "颜色")
    var color: LightingColorOption

    @Parameter(title: "十六进制颜色", description: "选「自定义颜色」时填写，例如 #FF7200")
    var hex: String?

    @Parameter(title: "配置档", description: "不选时修改当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("把灯光颜色设为\(\.$color)") {
            \.$hex
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let choice: SettingsRequest.Color
        switch color {
        case .random:
            choice = .random
        case .custom:
            guard let hex, !hex.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw $hex.needsValueError("请输入颜色，例如 #FF7200")
            }
            choice = try await automated { try SettingsRequest.Color(parsing: hex) }
        default:
            choice = .fixed(LEDColor(hex: color.hex ?? "")!)
        }
        let request = SettingsRequest(color: choice)
        let result = try await automated { try await automation.update(request, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.updated(result, request: request))")
    }
}

struct SetSleepTimersIntent: AppIntent {
    static let title: LocalizedStringResource = "设置休眠时间"
    static let description = IntentDescription(
        "设置无线键盘配置档的休眠与深度休眠时间；0 为不休眠。", categoryName: "键盘", searchKeywords: ["休眠", "省电"]
    )
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "休眠（秒）", description: "0 为不休眠，否则 30–300 秒", inclusiveRange: (0, 300))
    var sleepSeconds: Int?

    @Parameter(title: "深度休眠（分钟）", description: "0 为不休眠，否则 15–300 分钟", inclusiveRange: (0, 300))
    var deepSleepMinutes: Int?

    @Parameter(title: "配置档", description: "不选时修改当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("把休眠设为\(\.$sleepSeconds)秒、深度休眠\(\.$deepSleepMinutes)分钟") {
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = SettingsRequest(sleepSeconds: sleepSeconds, deepSleepMinutes: deepSleepMinutes)
        let result = try await automated { try await automation.update(request, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.updated(result, request: request))")
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "载入灯光预设"
    static let description = IntentDescription("把本机保存的灯光预设载入配置档，与菜单栏的「载入预设」相同。", categoryName: "键盘", searchKeywords: ["预设"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "预设")
    var preset: PresetEntity

    @Parameter(title: "配置档", description: "不选时载入当前配置档")
    var profile: ProfileSlot?

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("载入预设\(\.$preset)") {
            \.$profile
            \.$keyboard
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await automated { try await automation.applyPreset(id: preset.id, profile: profile?.index, on: keyboard?.keyboardID) }
        return .result(dialog: "\(AutomationText.presetApplied(preset.name, result))")
    }
}
