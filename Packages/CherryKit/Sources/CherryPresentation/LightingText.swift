import CherryCore
import Foundation

// 灯光数值的中文显示：界面、菜单栏与自动化入口共用。

public enum LightingText {
    public static let brightness = ["灭", "低", "中", "高", "全亮"]

    public static func brightness(_ v: Int) -> String {
        brightness.indices.contains(v) ? brightness[v] : "\(v)"
    }

    public static func speed(_ v: Int) -> String { "\(v + 1) / 5" }

    public static func sleep(seconds: Int) -> String { seconds == 0 ? "不休眠" : "\(seconds) 秒" }

    public static func deepSleep(minutes: Int) -> String { minutes == 0 ? "不休眠" : "\(minutes) 分钟" }

    /// Raw polling indices: the PIXIU 75 stores 0 here and the driver's index→Hz table is not confirmed for it.
    public static func polling(_ p: ProfileConfig) -> String {
        "有线 \(p.wiredPollingIndex) · 无线 \(p.wirelessPollingIndex)（原始值，对应频率未确认）"
    }
}

extension KeyboardModel {
    /// 灯效显示名；不在型号灯效表里的值显示原始编号。
    public func effectName(_ rawValue: UInt8) -> String {
        effect(rawValue)?.name ?? String(format: "效果 0x%02X", rawValue)
    }
}
