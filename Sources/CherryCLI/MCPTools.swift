import CherryControl
import MCP

/// `cherry mcp` 的工具：名称、说明、参数 schema 与注解，以及把工具参数换算成控制协议请求。
/// 能力与命令行相同，只到读取与配置，不提供固件操作。参数名用 snake_case，数值用界面单位（配置档 1 起、速度 1–5）。
enum CherryTool: String, CaseIterable, Sendable {
    case listKeyboards = "list_keyboards"
    case getStatus = "get_status"
    case getBattery = "get_battery"
    case listLightingEffects = "list_lighting_effects"
    case listPresets = "list_presets"
    case switchProfile = "switch_profile"
    case setLighting = "set_lighting"
    case setSleepTimers = "set_sleep_timers"
    case applyPreset = "apply_preset"

    var method: ControlMethod {
        switch self {
        case .listKeyboards: .keyboards
        case .getStatus: .status
        case .getBattery: .battery
        case .listLightingEffects: .effects
        case .listPresets: .presets
        case .switchProfile: .activateProfile
        case .setLighting, .setSleepTimers: .update
        case .applyPreset: .applyPreset
        }
    }

    var title: String {
        switch self {
        case .listKeyboards: "列出键盘"
        case .getStatus: "获取键盘状态"
        case .getBattery: "获取键盘电量"
        case .listLightingEffects: "列出灯效"
        case .listPresets: "列出灯光预设"
        case .switchProfile: "切换配置档"
        case .setLighting: "设置灯光"
        case .setSleepTimers: "设置休眠时间"
        case .applyPreset: "载入灯光预设"
        }
    }

    var summary: String {
        switch self {
        case .listKeyboards:
            "列出连接的 CHERRY 键盘：ID、名称、连接方式、固件版本、是否可配置。连接多把键盘时，其他工具的 keyboard 参数填这里的 ID。"
        case .getStatus:
            "读取键盘的电量、连接方式、固件版本、当前配置档，以及每个配置档的灯效、亮度（0–4）、速度（1–5）、颜色和休眠时间。"
        case .getBattery:
            "读取无线键盘的电量百分比和是否在充电。有线型号会返回错误。"
        case .listLightingEffects:
            "列出这把键盘支持的灯效（中文名和英文名）。不同型号的灯效表不同，设置灯效前可先查看。"
        case .listPresets:
            "列出本机保存的灯光预设：名称、来源型号和 ID。"
        case .switchProfile:
            "切换键盘当前使用的板载配置档（1–3）。"
        case .setLighting:
            "修改一个配置档的灯效、亮度、速度或颜色，只写指定的项；effect、brightness、speed、color 至少填一项。不填 profile 时修改当前配置档。"
        case .setSleepTimers:
            "修改一个配置档的休眠与深度休眠时间（只适用于无线型号），只写指定的项；sleep_seconds、deep_sleep_minutes 至少填一项。不填 profile 时修改当前配置档。"
        case .applyPreset:
            "把本机保存的灯光预设载入一个配置档，会覆盖该配置档原有的灯光与休眠设置。不填 profile 时载入当前配置档。来自其他型号的预设会被拒绝。"
        }
    }

    var annotations: Tool.Annotations {
        switch self {
        case .listKeyboards, .getStatus, .getBattery, .listLightingEffects, .listPresets:
            Tool.Annotations(title: title, readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        case .switchProfile, .setLighting, .setSleepTimers:
            Tool.Annotations(title: title, readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        case .applyPreset:
            Tool.Annotations(title: title, readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
        }
    }

    /// 按 schema 中的顺序。
    private var parameters: [ToolParameter] {
        switch self {
        case .listKeyboards, .listPresets:
            []
        case .getStatus, .getBattery, .listLightingEffects:
            [.keyboard]
        case .switchProfile:
            [.profile(required: true), .keyboard]
        case .setLighting:
            [.effect, .brightness, .speed, .color, .profile(required: false), .keyboard]
        case .setSleepTimers:
            [.sleepSeconds, .deepSleepMinutes, .profile(required: false), .keyboard]
        case .applyPreset:
            [.preset, .profile(required: false), .keyboard]
        }
    }

    /// 「至少一项」不写进 schema：Claude 的工具 schema 不支持顶层 anyOf，由 `params(from:)` 检查。
    var inputSchema: Value {
        let parameters = parameters
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })),
            "additionalProperties": false,
        ]
        let required = parameters.filter(\.required).map { Value.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    var definition: Tool {
        Tool(name: rawValue, title: title, description: summary, inputSchema: inputSchema, annotations: annotations)
    }

    /// 检查参数的名称与类型并换算成请求；数值范围、灯效与颜色由 App 按型号校验（与快捷指令、命令行的文案相同）。
    func params(from arguments: [String: Value]?) throws(ToolInputError) -> ControlParams {
        let arguments = ToolArguments(arguments ?? [:])
        try arguments.rejectUnknown(allowed: parameters.map(\.name))
        var params = ControlParams(keyboard: try arguments.string("keyboard"), profile: try arguments.integer("profile"))
        switch self {
        case .listKeyboards, .getStatus, .getBattery, .listLightingEffects, .listPresets:
            break
        case .switchProfile:
            guard params.profile != nil else { throw ToolInputError("缺少参数 profile") }
        case .setLighting:
            params.effect = try arguments.string("effect")
            params.brightness = try arguments.integer("brightness")
            params.speed = try arguments.integer("speed")
            params.color = try arguments.string("color")
            guard params.effect != nil || params.brightness != nil || params.speed != nil || params.color != nil else {
                throw ToolInputError("至少指定一项：effect、brightness、speed 或 color")
            }
        case .setSleepTimers:
            params.sleepSeconds = try arguments.integer("sleep_seconds")
            params.deepSleepMinutes = try arguments.integer("deep_sleep_minutes")
            guard params.sleepSeconds != nil || params.deepSleepMinutes != nil else {
                throw ToolInputError("至少指定一项：sleep_seconds 或 deep_sleep_minutes")
            }
        case .applyPreset:
            guard let preset = try arguments.string("preset") else { throw ToolInputError("缺少参数 preset") }
            params.preset = preset
        }
        return params
    }
}

/// 工具参数不合要求（名称、类型、缺少必填项）：作为 `isError` 的工具结果返回，让模型改正后重试。
struct ToolInputError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 灯效英文名（schema 枚举值）与中文名。与 CherryCore 的 `KeyboardModel.allLightingEffects` 一致，顺序相同（测试检查）；
/// 命令行不依赖 CherryCore，所以在这里写一份。
enum LightingEffectNames {
    static let all: [(english: String, chinese: String)] = [
        ("Wave", "波纹"), ("Spectrum", "光谱"), ("Breathing", "呼吸"), ("Rolling", "霓虹"), ("Curve", "曲线"), ("Scan", "折返"),
        ("Radiation", "放射"), ("Ripples", "扩散"), ("Single Key", "单点亮"), ("Static", "常亮"), ("Custom", "自定义"),
        ("Battle", "对战"), ("RGB Static", "RGB常亮"), ("Lightning", "闪电"), ("Flame", "火焰"), ("Rainbow Rain", "彩虹雨"),
    ]
}

private struct ToolParameter {
    let name: String
    let schema: Value
    var required = false

    static let keyboard = ToolParameter(
        name: "keyboard", schema: ["type": "string", "description": "键盘 ID，例如 046A:01E2@03100000（list_keyboards 列出）。不填时使用唯一连接的键盘。"]
    )

    static func profile(required: Bool) -> ToolParameter {
        let description = required ? "配置档编号，1 起。" : "配置档编号，1 起。不填时为当前配置档。"
        return ToolParameter(
            name: "profile", schema: ["type": "integer", "minimum": 1, "maximum": 3, "description": .string(description)], required: required
        )
    }

    static let effect = ToolParameter(
        name: "effect",
        schema: [
            "type": "string",
            "enum": .array(LightingEffectNames.all.map { .string($0.english) }),
            "description": .string(
                "灯效英文名。中文对照：" + LightingEffectNames.all.map { "\($0.english)=\($0.chinese)" }.joined(separator: "，")
                    + "。不同型号支持的灯效不同，可先用 list_lighting_effects 查看。"
            ),
        ]
    )

    static let brightness = ToolParameter(
        name: "brightness", schema: ["type": "integer", "minimum": 0, "maximum": 4, "description": "亮度：0 灭、1 低、2 中、3 高、4 全亮。"]
    )

    static let speed = ToolParameter(
        name: "speed", schema: ["type": "integer", "minimum": 1, "maximum": 5, "description": "灯效速度：1 最慢，5 最快。"]
    )

    static let color = ToolParameter(
        name: "color", schema: ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$|^random$", "description": "颜色：#RRGGBB，或 random（随机颜色）。"]
    )

    static let sleepSeconds = ToolParameter(
        name: "sleep_seconds", schema: ["type": "integer", "minimum": 0, "maximum": 300, "description": "休眠时间（秒）：0 为不休眠，否则 30–300。"]
    )

    static let deepSleepMinutes = ToolParameter(
        name: "deep_sleep_minutes",
        schema: ["type": "integer", "minimum": 0, "maximum": 300, "description": "深度休眠时间（分钟）：0 为不休眠，否则 15–300。"]
    )

    static let preset = ToolParameter(
        name: "preset", schema: ["type": "string", "description": "预设名称或 ID（list_presets 列出）。"], required: true
    )
}

/// 按名称取参数并检查类型；`null` 视为未填。整数也接受整数值的小数和数字字符串。
private struct ToolArguments {
    let values: [String: Value]

    init(_ values: [String: Value]) {
        self.values = values.filter { !$0.value.isNull }
    }

    func rejectUnknown(allowed: [String]) throws(ToolInputError) {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let hint = allowed.isEmpty ? "这个工具没有参数" : "可用的参数：" + allowed.joined(separator: "、")
            throw ToolInputError("未知参数 \(unknown.joined(separator: "、"))；\(hint)")
        }
    }

    func string(_ name: String) throws(ToolInputError) -> String? {
        guard let value = values[name] else { return nil }
        guard let text = value.stringValue else { throw ToolInputError("参数 \(name) 应为字符串") }
        // 与命令行相同的上限：请求必须装进控制协议的一行，超长时直接说明，而不是变成「App 没有运行」。
        let limit = name == "preset" ? ArgumentLimit.presetName : ArgumentLimit.short
        guard text.count <= limit else { throw ToolInputError("参数 \(name) 过长（\(text.count) 个字符，最多 \(limit) 个）") }
        return text
    }

    func integer(_ name: String) throws(ToolInputError) -> Int? {
        guard let value = values[name] else { return nil }
        guard let number = Int(value, strict: false) else { throw ToolInputError("参数 \(name) 应为整数") }
        return number
    }
}
