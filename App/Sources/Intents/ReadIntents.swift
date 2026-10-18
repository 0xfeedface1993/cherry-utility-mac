import AppIntents
import CherryCore
import CherryFeatures
import CherryPresentation
import Foundation

struct GetKeyboardStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "获取键盘状态"
    static let description = IntentDescription(
        "读取 CHERRY 键盘的电量、连接方式、固件版本、当前配置档和灯效。", categoryName: "键盘", searchKeywords: ["电量", "灯效", "配置档"]
    )
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("获取键盘状态") { \.$keyboard }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<KeyboardStatusEntity> & ProvidesDialog {
        let report = try await automated { try await automation.status(of: keyboard?.keyboardID) }
        return .result(value: KeyboardStatusEntity(report), dialog: "\(AutomationText.status(report))")
    }
}

struct GetBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "获取键盘电量"
    static let description = IntentDescription("读取无线 CHERRY 键盘的电量百分比。", categoryName: "键盘", searchKeywords: ["电池", "充电"])
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "键盘", description: "不选时使用唯一连接的键盘")
    var keyboard: KeyboardEntity?

    @AppDependency private var automation: KeyboardAutomation

    static var parameterSummary: some ParameterSummary {
        Summary("获取键盘电量") { \.$keyboard }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let (summary, battery) = try await automated { try await automation.battery(of: keyboard?.keyboardID) }
        return .result(value: battery.percent, dialog: "\(AutomationText.battery(summary, battery))")
    }
}
