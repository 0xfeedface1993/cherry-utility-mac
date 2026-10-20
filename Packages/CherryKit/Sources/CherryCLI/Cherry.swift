import ArgumentParser
import CherryControl
import Foundation

/// `cherry`：CHERRY 键盘的命令行入口。CHERRY Utility 在运行时经由它执行（与菜单栏、快捷指令共用设备通道和写入队列），
/// 否则在本进程直接连接键盘；两边经设备锁与跨进程信号协调，共用预设与设置。不提供固件操作。
///
/// 退出码：0 成功；2 用法错误；3 无法连接 App；4 键盘或参数被 App 拒绝；1 其它错误。
@main
struct Cherry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cherry",
        abstract: "读取和设置 CHERRY 键盘。",
        discussion: """
        CHERRY Utility 在运行时，命令经由它执行；没在运行时直接连接键盘，此时需要在「系统设置 › 隐私与安全性 › 输入监控」\
        里允许运行 cherry 的终端。加 --via-app 改为先在后台启动 App。`cherry doctor` 显示当前会走哪条路。
        不填 --keyboard 时使用唯一连接的键盘，不填 --profile 时修改当前配置档。
        """,
        version: "控制协议 v\(ControlProtocol.version)",
        subcommands: [
            StatusCommand.self, KeyboardsCommand.self, BatteryCommand.self, EffectsCommand.self, PresetsCommand.self,
            ProfileCommand.self, SetCommand.self, PresetCommand.self, WatchCommand.self, VersionCommand.self, DoctorCommand.self,
            MCPCommand.self,
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
