import CherryControl
import Foundation

/// 终端输出：默认为中文文本，`--json` 时输出结果对象。
enum Output {
    static func json<T: Encodable>(_ value: T) -> String {
        encode(value, formatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `watch --json`：每个事件一行。
    static func jsonLine<T: Encodable>(_ value: T) -> String {
        encode(value, formatting: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func encode<T: Encodable>(_ value: T, formatting: JSONEncoder.OutputFormatting) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func message(_ result: ControlResult) -> String { result.message ?? "完成" }

    static func status(_ result: ControlResult) -> String {
        guard let status = result.status else { return message(result) }
        var lines = [status.summary]
        if let profiles = status.profiles, !profiles.isEmpty {
            lines.append("")
            lines += profiles.map { (($0.profile == status.activeProfile) ? "* " : "  ") + profile($0) }
        }
        return lines.joined(separator: "\n")
    }

    /// 「配置 2：波纹 · 亮度 4/4 · 速度 2/5 · 随机颜色 · 休眠 300 秒 · 深度休眠 30 分钟」；型号没有的项不显示。
    static func profile(_ profile: ControlProfile) -> String {
        var parts: [String] = []
        if let effect = profile.effect { parts.append(effect) }
        if let brightness = profile.brightness { parts.append("亮度 \(brightness)/4") }
        if let speed = profile.speed { parts.append("速度 \(speed)/5") }
        if profile.randomColor == true {
            parts.append("随机颜色")
        } else if let color = profile.color {
            parts.append("颜色 \(color)")
        }
        if let seconds = profile.sleepSeconds { parts.append(seconds == 0 ? "不休眠" : "休眠 \(seconds) 秒") }
        if let minutes = profile.deepSleepMinutes { parts.append(minutes == 0 ? "不深度休眠" : "深度休眠 \(minutes) 分钟") }
        return "配置 \(profile.profile)：" + (parts.isEmpty ? "无背光" : parts.joined(separator: " · "))
    }

    static func keyboards(_ result: ControlResult) -> String {
        guard let keyboards = result.keyboards, !keyboards.isEmpty else { return "没有连接受支持的 CHERRY 键盘" }
        return keyboards.map { keyboard in
            var line = "\(keyboard.id)  \(keyboard.name)  \(keyboard.transport)  固件 \(keyboard.firmware)"
            if !keyboard.configurable { line += "  （没有配置接口）" }
            return line
        }.joined(separator: "\n")
    }

    static func effects(_ result: ControlResult) -> String {
        guard let effects = result.effects, !effects.isEmpty else {
            return "\(result.keyboard?.name ?? "这把键盘") 没有背光灯效"
        }
        let header = "\(result.keyboard?.name ?? "键盘") 的灯效："
        return ([header] + effects.map { "  \($0.name)（\($0.englishName)）" }).joined(separator: "\n")
    }

    static func presets(_ result: ControlResult) -> String {
        guard let presets = result.presets, !presets.isEmpty else { return "还没有保存灯光预设" }
        return presets.map { "\($0.name)  \($0.model ?? "任何型号")  \($0.id)" }.joined(separator: "\n")
    }

    static func version(_ result: ControlResult) -> String {
        guard let version = result.version else { return message(result) }
        return "cherry（控制协议 v\(ControlProtocol.version)）· CHERRY Utility \(version.app) (\(version.build))，App 协议 v\(version.protocolVersion)"
    }

    static func change(_ change: ControlChange, at date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let active = change.profiles.first { $0.profile == change.activeProfile }.map(profile) ?? "配置 \(change.activeProfile)"
        return "[\(time)] \(change.keyboard) 当前 \(active)"
    }
}
