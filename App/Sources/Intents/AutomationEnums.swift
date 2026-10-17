import AppIntents
import CherryCore
import Foundation

// 枚举是静态元数据：键盘没连接、App 没运行时，快捷指令编辑器和 Spotlight 也能列出选项，
// 也能直接放进 App Shortcut 短语。标题必须是字面量，供构建时提取元数据。

enum ProfileSlot: String, AppEnum {
    case first = "1", second = "2", third = "3"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "配置档"
    static let caseDisplayRepresentations: [ProfileSlot: DisplayRepresentation] = [
        .first: DisplayRepresentation(title: "配置 1", synonyms: ["配置档 1", "配置一", "配置档一", "第一个配置档"]),
        .second: DisplayRepresentation(title: "配置 2", synonyms: ["配置档 2", "配置二", "配置档二", "第二个配置档"]),
        .third: DisplayRepresentation(title: "配置 3", synonyms: ["配置档 3", "配置三", "配置档三", "第三个配置档"]),
    ]

    /// Core 的 0 起编号。
    var index: Int { Int(rawValue)! - 1 }
}

enum BrightnessLevel: String, AppEnum {
    case off, low, medium, high, full

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "亮度"
    static let caseDisplayRepresentations: [BrightnessLevel: DisplayRepresentation] = [
        .off: DisplayRepresentation(title: "灭", synonyms: ["关闭", "关灯", "0"]),
        .low: DisplayRepresentation(title: "低", synonyms: ["暗", "1"]),
        .medium: DisplayRepresentation(title: "中", synonyms: ["中等", "2"]),
        .high: DisplayRepresentation(title: "高", synonyms: ["亮", "3"]),
        .full: DisplayRepresentation(title: "全亮", synonyms: ["最亮", "最高", "4"]),
    ]

    var value: Int {
        switch self {
        case .off: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .full: 4
        }
    }
}

enum SpeedLevel: String, AppEnum {
    case slowest = "1", slow = "2", medium = "3", fast = "4", fastest = "5"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "灯效速度"
    static let caseDisplayRepresentations: [SpeedLevel: DisplayRepresentation] = [
        .slowest: DisplayRepresentation(title: "1 / 5（最慢）", synonyms: ["最慢", "1"]),
        .slow: DisplayRepresentation(title: "2 / 5（较慢）", synonyms: ["较慢", "慢", "2"]),
        .medium: DisplayRepresentation(title: "3 / 5（适中）", synonyms: ["适中", "中速", "3"]),
        .fast: DisplayRepresentation(title: "4 / 5（较快）", synonyms: ["较快", "快", "4"]),
        .fastest: DisplayRepresentation(title: "5 / 5（最快）", synonyms: ["最快", "5"]),
    ]

    /// Core 的 0…4。
    var value: Int { Int(rawValue)! - 1 }
}

/// 全部型号灯效表的并集，原始值为英文名；执行时按目标键盘的表解析（同一编号在不同型号上是不同灯效）。
enum LightingEffectOption: String, AppEnum {
    case wave = "Wave", spectrum = "Spectrum", breathing = "Breathing", rolling = "Rolling", curve = "Curve", scan = "Scan"
    case radiation = "Radiation", ripples = "Ripples", singleKey = "Single Key", staticLight = "Static", custom = "Custom"
    case rainbowRain = "Rainbow Rain", rgbStatic = "RGB Static", lightning = "Lightning", flame = "Flame", battle = "Battle"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "灯效"
    static let caseDisplayRepresentations: [LightingEffectOption: DisplayRepresentation] = [
        .wave: DisplayRepresentation(title: "波纹", synonyms: ["Wave"]),
        .spectrum: DisplayRepresentation(title: "光谱", synonyms: ["Spectrum", "彩虹"]),
        .breathing: DisplayRepresentation(title: "呼吸", synonyms: ["Breathing", "呼吸灯"]),
        .rolling: DisplayRepresentation(title: "霓虹", synonyms: ["Rolling"]),
        .curve: DisplayRepresentation(title: "曲线", synonyms: ["Curve"]),
        .scan: DisplayRepresentation(title: "折返", synonyms: ["Scan"]),
        .radiation: DisplayRepresentation(title: "放射", synonyms: ["Radiation"]),
        .ripples: DisplayRepresentation(title: "扩散", synonyms: ["Ripples"]),
        .singleKey: DisplayRepresentation(title: "单点亮", synonyms: ["Single Key", "单键"]),
        .staticLight: DisplayRepresentation(title: "常亮", synonyms: ["Static"]),
        .custom: DisplayRepresentation(title: "自定义", synonyms: ["Custom"]),
        .rainbowRain: DisplayRepresentation(title: "彩虹雨", synonyms: ["Rainbow Rain"]),
        .rgbStatic: DisplayRepresentation(title: "RGB常亮", synonyms: ["RGB Static"]),
        .lightning: DisplayRepresentation(title: "闪电", synonyms: ["Lightning"]),
        .flame: DisplayRepresentation(title: "火焰", synonyms: ["Flame"]),
        .battle: DisplayRepresentation(title: "对战", synonyms: ["Battle"]),
    ]

    /// 型号目录里的中文名（与 `caseDisplayRepresentations` 的标题相同，`AutomationCatalogCheck` 核对）。
    var catalogName: String {
        KeyboardModel.allLightingEffects.first { $0.englishName == rawValue }?.name ?? rawValue
    }
}

/// 官方「收藏颜色」调色板，外加随机颜色与自定义十六进制颜色。
enum LightingColorOption: String, AppEnum {
    case random, red, orange, yellow, green, skyBlue, blue, purple, magenta, pink, white, custom

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "灯光颜色"
    static let caseDisplayRepresentations: [LightingColorOption: DisplayRepresentation] = [
        .random: DisplayRepresentation(title: "随机颜色", synonyms: ["随机", "Random"]),
        .red: DisplayRepresentation(title: "红色", subtitle: "#FF0000", synonyms: ["红"]),
        .orange: DisplayRepresentation(title: "橙色", subtitle: "#FF7200", synonyms: ["橙"]),
        .yellow: DisplayRepresentation(title: "黄色", subtitle: "#FFF005", synonyms: ["黄"]),
        .green: DisplayRepresentation(title: "绿色", subtitle: "#00D70F", synonyms: ["绿"]),
        .skyBlue: DisplayRepresentation(title: "天蓝", subtitle: "#0099FF", synonyms: ["天蓝色", "浅蓝"]),
        .blue: DisplayRepresentation(title: "蓝色", subtitle: "#3153FF", synonyms: ["蓝"]),
        .purple: DisplayRepresentation(title: "紫色", subtitle: "#5E01D2", synonyms: ["紫"]),
        .magenta: DisplayRepresentation(title: "品红", subtitle: "#EE00F1", synonyms: ["洋红", "品红色"]),
        .pink: DisplayRepresentation(title: "粉红", subtitle: "#FF008A", synonyms: ["粉色", "粉红色"]),
        .white: DisplayRepresentation(title: "白色", subtitle: "#FFFFFF", synonyms: ["白"]),
        .custom: DisplayRepresentation(title: "自定义颜色", subtitle: "填写十六进制颜色"),
    ]

    var hex: String? {
        switch self {
        case .red: "FF0000"
        case .orange: "FF7200"
        case .yellow: "FFF005"
        case .green: "00D70F"
        case .skyBlue: "0099FF"
        case .blue: "3153FF"
        case .purple: "5E01D2"
        case .magenta: "EE00F1"
        case .pink: "FF008A"
        case .white: "FFFFFF"
        case .random, .custom: nil
        }
    }
}

#if DEBUG
enum AutomationCatalogCheck {
    /// 枚举与 Core 型号目录必须一致（新增型号带来新灯效时提醒同步）。模拟模式启动时执行，UI 测试每次都会经过。
    static func verify() {
        let catalog = KeyboardModel.allLightingEffects
        let options = Dictionary(uniqueKeysWithValues: LightingEffectOption.allCases.map { ($0.rawValue, $0) })
        precondition(Set(options.keys) == Set(catalog.map(\.englishName)), "LightingEffectOption 与型号灯效表不一致")
        for effect in catalog {
            let title = options[effect.englishName].flatMap { LightingEffectOption.caseDisplayRepresentations[$0]?.title }
            precondition(title.map { String(localized: $0) } == effect.name, "灯效「\(effect.englishName)」的中文名不一致")
        }
    }
}
#endif
