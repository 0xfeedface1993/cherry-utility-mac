import CherryCore
import Foundation

// 自动化入口（快捷指令、Spotlight，之后的 CLI / MCP）的中文文案。用语与菜单栏一致：「配置 n」「亮度 全亮」。

extension AutomationError: UserFacingError {
    public var message: String {
        switch self {
        case .noKeyboard:
            "没有连接受支持的 CHERRY 键盘"
        case .ambiguousKeyboard(let keyboards):
            "连接了多把键盘（\(keyboards.map(\.selectionLabel).joined(separator: "、"))），请在操作的「键盘」参数里选择一把"
        case .fieldUnsupported(let field, let model):
            AutomationText.unsupported(field, model: model)
        case .unknownEffect(let name, let model):
            "\(model.name) 没有「\(name)」灯效，可选：\(model.lightingEffects.map(\.name).joined(separator: "、"))"
        case .valueOutOfRange(let field, let value):
            AutomationText.outOfRange(field, value)
        case .profileOutOfRange(let profile, let model):
            "\(model.name) 只有 \(model.profileCount) 个配置档，没有配置 \(profile + 1)"
        case .noBattery(let model):
            "\(model.name) 是有线键盘，没有电量"
        case .invalidColor(let text):
            "颜色「\(text)」格式不对，请用 #RRGGBB，例如 #FF7200"
        case .presetNotFound:
            "预设已被删除"
        case .presetIncompatible(let name):
            "预设「\(name)」来自其他型号"
        case .nothingToChange:
            "没有需要修改的设置"
        case .firmwareUpdateInProgress:
            "这把键盘正在升级固件，请完成后再试"
        case .entryDisabled(let entry):
            "\(AutomationText.name(of: entry))控制已在 CHERRY Utility 的「设置 › 自动化」里关闭"
        }
    }
}

public enum AutomationText {
    public static func profile(_ profile: Int) -> String { "配置 \(profile + 1)" }

    public static func brightness(_ value: Int) -> String { LightingText.brightness(value) }

    /// 1…5，与界面的速度滑块一致（Core 存 0…4）。
    public static func speed(_ value: Int) -> String { LightingText.speed(value) }

    public static func color(_ settings: ProfileSettings) -> String { settings.randomColor ? "随机颜色" : settings.color.description }

    public static func sleep(seconds: Int) -> String { LightingText.sleep(seconds: seconds) }

    public static func deepSleep(minutes: Int) -> String { LightingText.deepSleep(minutes: minutes) }

    public static func effect(_ rawValue: UInt8, model: KeyboardModel) -> String { model.effectName(rawValue) }

    /// 「波纹 · 亮度 全亮」；无背光型号为「无背光」。
    public static func lighting(_ settings: ProfileSettings, model: KeyboardModel) -> String {
        guard model.hasLighting else { return "无背光" }
        return "\(model.effectName(settings.effect)) · 亮度 \(brightness(settings.brightness))"
    }

    public static func connection(_ report: KeyboardStatusReport) -> String {
        report.snapshot?.status?.mode.displayName ?? report.keyboard.transportDescription
    }

    public static func battery(_ battery: BatteryStatus) -> String {
        let charging = switch battery.charging {
        case .charging: "充电中"
        case .notCharging: "未充电"
        case .other: "充电状态未知"
        }
        return "\(battery.percent)%（\(charging)）"
    }

    /// 「CHERRY MX PIXIU 75 · 电量 95%（充电中） · 有线 USB · 固件 0.1.1.7 · 配置 2 · 波纹 · 亮度 全亮」
    public static func status(_ report: KeyboardStatusReport) -> String {
        var parts = [report.keyboard.displayName]
        if let battery = report.snapshot?.battery { parts.append("电量 \(Self.battery(battery))") }
        parts.append(connection(report))
        parts.append("固件 \(report.keyboard.firmwareVersion)")
        if let configuration = report.snapshot?.configuration {
            parts.append(profile(configuration.activeProfile))
            parts.append(lighting(configuration.active.settings, model: report.model))
        } else {
            parts.append("没有配置接口，读不到配置（请用 USB 线或 2.4G 接收器连接）")
        }
        return parts.joined(separator: " · ")
    }

    public static func battery(_ keyboard: KeyboardSummary, _ battery: BatteryStatus) -> String {
        "\(keyboard.displayName) 电量 \(Self.battery(battery))"
    }

    public static func activated(_ result: AutomationResult) -> String {
        guard let settings = result.settings else { return "已切换到\(profile(result.profile))" }
        return "已切换到\(profile(result.profile))（\(lighting(settings, model: result.model))）"
    }

    /// 只列出请求里出现的字段，取读回后的值。
    public static func updated(_ result: AutomationResult, request: SettingsRequest) -> String {
        guard let settings = result.settings else { return "已更新\(profile(result.profile))" }
        var parts: [String] = []
        if request.effect != nil { parts.append("灯效 \(effect(settings.effect, model: result.model))") }
        if request.brightness != nil { parts.append("亮度 \(brightness(settings.brightness))") }
        if request.speed != nil { parts.append("速度 \(speed(settings.speed))") }
        if request.color != nil { parts.append("颜色 \(color(settings))") }
        if request.sleepSeconds != nil { parts.append("休眠 \(sleep(seconds: settings.sleepSeconds))") }
        if request.deepSleepMinutes != nil { parts.append("深度休眠 \(deepSleep(minutes: settings.deepSleepMinutes))") }
        return "已更新\(profile(result.profile))：" + parts.joined(separator: "，")
    }

    public static func presetApplied(_ name: String, _ result: AutomationResult) -> String {
        guard let settings = result.settings else { return "已把预设「\(name)」载入\(profile(result.profile))" }
        return "已把预设「\(name)」载入\(profile(result.profile))（\(lighting(settings, model: result.model))）"
    }

    public static func unsupported(_ field: ProfileField, model: KeyboardModel) -> String {
        switch field {
        case .effect, .brightness, .speed:
            model.hasLighting ? "\(model.name) 不支持修改\(name(of: field))" : "\(model.name) 没有背光，不能设置\(name(of: field))"
        case .color, .randomColor:
            "\(model.name) 不支持设置颜色"
        case .sleepSeconds, .deepSleepMinutes:
            "\(model.name) 不支持休眠设置"
        }
    }

    public static func outOfRange(_ field: ProfileField, _ value: Int) -> String {
        switch field {
        case .brightness: "亮度须为 0–4（灭到全亮），收到 \(value)"
        case .speed: "速度须为 1–5，收到 \(value + 1)"
        case .sleepSeconds: "休眠时间须为 0（不休眠）或 30–300 秒，收到 \(value)"
        case .deepSleepMinutes: "深度休眠须为 0（不休眠）或 15–300 分钟，收到 \(value)"
        case .effect, .randomColor, .color: "\(name(of: field))的值 \(value) 无效"
        }
    }

    public static func name(of field: ProfileField) -> String {
        switch field {
        case .effect: "灯效"
        case .brightness: "亮度"
        case .speed: "速度"
        case .randomColor, .color: "颜色"
        case .sleepSeconds: "休眠时间"
        case .deepSleepMinutes: "深度休眠"
        }
    }

    public static func name(of entry: AutomationEntry) -> String {
        switch entry {
        case .commandLine: "命令行"
        case .mcp: "MCP "
        }
    }

    public static func name(of client: MCPClient) -> String {
        switch client {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        }
    }
}
