import ArgumentParser
import CherryControl
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "显示电量、连接方式、固件和各配置档的灯光与休眠设置。")
    @OptionGroup var keyboard: KeyboardOption
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.status, ControlParams(keyboard: keyboard.keyboard)) }, human: Output.status)
    }
}

struct KeyboardsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keyboards", abstract: "列出连接的 CHERRY 键盘及其 ID。")
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.keyboards) }, human: Output.keyboards)
    }
}

struct BatteryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "battery", abstract: "显示无线键盘的电量。")
    @OptionGroup var keyboard: KeyboardOption
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.battery, ControlParams(keyboard: keyboard.keyboard)) }, human: Output.message)
    }
}

struct EffectsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "effects", abstract: "列出键盘支持的灯效（不同型号不同）。")
    @OptionGroup var keyboard: KeyboardOption
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.effects, ControlParams(keyboard: keyboard.keyboard)) }, human: Output.effects)
    }
}

struct PresetsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "presets", abstract: "列出本机保存的灯光预设。")
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.presets) }, human: Output.presets)
    }
}

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profile", abstract: "切换到板载配置档 1、2 或 3。")
    @Argument(help: "配置档编号（1 起）。")
    var profile: Int
    @OptionGroup var keyboard: KeyboardOption
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.activateProfile, ControlParams(keyboard: keyboard.keyboard, profile: profile)) },
                    human: Output.message)
    }
}

/// 0…4 或「灭 / 低 / 中 / 高 / 全亮」。
struct BrightnessArgument: ExpressibleByArgument, Equatable {
    static let names = ["灭", "低", "中", "高", "全亮"]
    let value: Int

    init?(argument: String) {
        if let index = Self.names.firstIndex(of: argument) {
            value = index
        } else if let number = Int(argument), (0...4).contains(number) {
            value = number
        } else {
            return nil
        }
    }

    static var allValueStrings: [String] { (0...4).map(String.init) + names }
}

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "修改配置档的灯效、亮度、速度、颜色或休眠时间（只写指定的项）。",
        discussion: "例：cherry set --effect 呼吸 --brightness 高；cherry set --color #FF7200；cherry set --profile 3 --sleep 0"
    )
    @Option(name: .shortAndLong, help: "配置档编号（1 起）；不填时修改当前配置档。")
    var profile: Int?
    @Option(help: "灯效名，中文或英文，例如「呼吸」或 Breathing（cherry effects 列出可选项）。")
    var effect: String?
    @Option(help: "亮度：0–4，或 灭 / 低 / 中 / 高 / 全亮。")
    var brightness: BrightnessArgument?
    @Option(help: "灯效速度：1（最慢）到 5（最快）。")
    var speed: Int?
    @Option(help: "颜色：#RRGGBB，或 random（随机颜色）。")
    var color: String?
    @Option(help: "休眠时间（秒）：0 为不休眠，否则 30–300。")
    var sleep: Int?
    @Option(name: .customLong("deep-sleep"), help: "深度休眠时间（分钟）：0 为不休眠，否则 15–300。")
    var deepSleep: Int?
    @OptionGroup var keyboard: KeyboardOption
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func validate() throws {
        guard params.effect != nil || params.brightness != nil || params.speed != nil || params.color != nil
                || params.sleepSeconds != nil || params.deepSleepMinutes != nil else {
            throw ValidationError("至少指定一项：--effect、--brightness、--speed、--color、--sleep 或 --deep-sleep")
        }
    }

    var params: ControlParams {
        ControlParams(
            keyboard: keyboard.keyboard, profile: profile, effect: effect, brightness: brightness?.value, speed: speed, color: color,
            sleepSeconds: sleep, deepSleepMinutes: deepSleep
        )
    }

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.update, params) }, human: Output.message)
    }
}

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preset", abstract: "使用本机保存的灯光预设。", subcommands: [Apply.self])

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "apply", abstract: "把预设载入配置档（与菜单栏的「载入预设」相同）。")
        @Argument(help: "预设名称或 ID（cherry presets 列出）。")
        var preset: String
        @Option(name: .shortAndLong, help: "配置档编号（1 起）；不填时载入当前配置档。")
        var profile: Int?
        @OptionGroup var keyboard: KeyboardOption
        @OptionGroup var output: OutputOptions
        @OptionGroup var connection: ConnectionOptions

        func run() throws {
            try perform(connection, json: output.json, {
                try $0.call(.applyPreset, ControlParams(keyboard: keyboard.keyboard, profile: profile, preset: preset))
            }, human: Output.message)
        }
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "显示命令行与 App 的版本。")
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        try perform(connection, json: output.json, { try $0.call(.version) }, human: Output.version)
    }
}

struct WatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch", abstract: "持续输出经快捷指令、命令行等自动化入口写入的配置变化（Ctrl-C 结束）。",
        discussion: "菜单栏和主窗口里的修改不在此列。--json 时每个事件一行 JSON。"
    )
    @OptionGroup var output: OutputOptions
    @OptionGroup var connection: ConnectionOptions

    func run() throws {
        do {
            let session = try Session.open(connection, timeout: nil)
            let id: Int
            do { id = try session.client.send(.watch) } catch { throw CLIError(error) }
            while true {
                let response: ControlResponse
                do { response = try session.client.receive() } catch { throw CLIError(error) }
                guard response.id == id else { continue }
                guard response.ok, let result = response.result else {
                    throw CLIError.rejected(response.error ?? ControlFailure(code: "internalError", message: "监听失败"))
                }
                guard let change = result.change else {
                    if !output.json, let message = result.message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
                    continue
                }
                print(output.json ? Output.jsonLine(change) : Output.change(change, at: Date()))
                fflush(stdout)
            }
        } catch let error as CLIError {
            FileHandle.standardError.write(Data(("错误：" + error.message + "\n").utf8))
            throw ExitCode(error.exitCode)
        }
    }
}
