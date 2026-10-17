import ArgumentParser
import CherryControl
import Foundation

/// `cherry`：本机 CHERRY Utility 的命令行入口。命令经运行中的 App 执行（没运行时在后台启动它），
/// 与菜单栏、快捷指令共用同一个设备通道和写入队列。不提供固件操作。
///
/// 退出码：0 成功；2 用法错误；3 无法连接 App；4 键盘或参数被 App 拒绝；1 其它错误。
@main
struct Cherry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cherry",
        abstract: "通过 CHERRY Utility 读取和设置 CHERRY 键盘。",
        discussion: """
        命令经本机运行的 CHERRY Utility 执行；App 没运行时会在后台启动它（不显示主窗口）。
        需要 App 已获得「输入监控」权限。不填 --keyboard 时使用唯一连接的键盘，不填 --profile 时修改当前配置档。
        """,
        version: "控制协议 v\(ControlProtocol.version)",
        subcommands: [
            StatusCommand.self, KeyboardsCommand.self, BatteryCommand.self, EffectsCommand.self, PresetsCommand.self,
            ProfileCommand.self, SetCommand.self, PresetCommand.self, WatchCommand.self, VersionCommand.self, MCPCommand.self,
        ]
    )

    static func main() async {
        do {
            var command = try await asyncParseAsRoot()
            if var command = command as? AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            // 用法错误统一用 2（ArgumentParser 默认 64）；帮助、版本与 ExitCode 照常处理。
            if exitCode(for: error) == .validationFailure {
                FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
                Foundation.exit(2)
            }
            exit(withError: error)
        }
    }
}

enum CherryExit {
    static let usage: Int32 = 2
    static let appUnavailable: Int32 = 3
    static let rejected: Int32 = 4
}
