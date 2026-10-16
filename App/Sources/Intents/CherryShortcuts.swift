import AppIntents

/// 无需用户设置即出现在快捷指令 App 与 Spotlight 中的动作（上限 10 个）。每条短语都含 App 名，最多一个枚举或实体参数。
/// 只写 zh-Hans：加 en 本地化会让系统按英文显示 Sparkle 对话框和日期格式。
struct CherryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetKeyboardStatusIntent(),
            phrases: ["\(.applicationName)键盘状态", "用\(.applicationName)查看键盘状态", "\(.applicationName)现在是什么灯效"],
            shortTitle: "键盘状态",
            systemImageName: "keyboard"
        )
        AppShortcut(
            intent: GetBatteryIntent(),
            phrases: ["\(.applicationName)键盘电量", "用\(.applicationName)查看键盘电量", "\(.applicationName)还剩多少电"],
            shortTitle: "键盘电量",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: SwitchProfileIntent(),
            phrases: ["用\(.applicationName)切换到\(\.$profile)", "\(.applicationName)切换到\(\.$profile)", "\(.applicationName)切换配置档"],
            shortTitle: "切换配置档",
            systemImageName: "square.stack.3d.up"
        )
        AppShortcut(
            intent: SetLightingEffectIntent(),
            phrases: ["用\(.applicationName)把灯效换成\(\.$effect)", "\(.applicationName)灯效\(\.$effect)", "\(.applicationName)换个灯效"],
            shortTitle: "设置灯效",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: ["用\(.applicationName)把背光调到\(\.$brightness)", "\(.applicationName)亮度\(\.$brightness)", "\(.applicationName)调整背光亮度"],
            shortTitle: "背光亮度",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: TurnOffBacklightIntent(),
            phrases: ["用\(.applicationName)关闭背光", "\(.applicationName)关灯", "\(.applicationName)关闭键盘背光"],
            shortTitle: "关闭背光",
            systemImageName: "lightbulb.slash"
        )
        AppShortcut(
            intent: SetLightingColorIntent(),
            phrases: ["用\(.applicationName)把灯光换成\(\.$color)", "\(.applicationName)灯光颜色\(\.$color)", "\(.applicationName)换个颜色"],
            shortTitle: "灯光颜色",
            systemImageName: "paintpalette"
        )
        AppShortcut(
            intent: SetLightingSpeedIntent(),
            phrases: ["用\(.applicationName)把灯效速度调到\(\.$speed)", "\(.applicationName)灯效速度"],
            shortTitle: "灯效速度",
            systemImageName: "gauge.with.dots.needle.50percent"
        )
        AppShortcut(
            intent: ApplyPresetIntent(),
            phrases: ["用\(.applicationName)载入预设\(\.$preset)", "\(.applicationName)预设\(\.$preset)", "\(.applicationName)载入灯光预设"],
            shortTitle: "载入预设",
            systemImageName: "tray.and.arrow.down"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .red
}
