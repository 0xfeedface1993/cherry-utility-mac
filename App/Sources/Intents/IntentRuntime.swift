import AppIntents
import CherryCore
import CherryFeatures
import Foundation

// 意图（快捷指令、Spotlight）在 App 进程内执行：经组合根注册的 `KeyboardAutomation` 访问键盘，
// 与菜单栏、主窗口共用独占通道和合并写入队列。这里的文件不引入 TCA，避免与它的 `@Dependency` 混淆。

/// 意图失败时快捷指令和 Spotlight 显示的中文说明。
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// 以自动化来源（诊断 origin）执行意图主体，并把错误换成界面同款中文文案。
func automated<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await DiagnosticOrigin.$current.withValue(.automation) { try await body() }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw IntentFailure(message: error.userMessage)
    }
}
