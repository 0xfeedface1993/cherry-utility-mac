import ArgumentParser
import CherryControl
import Foundation

struct ConnectionOptions: ParsableArguments {
    @Option(name: .customLong("socket"), help: ArgumentHelp("控制 socket 路径（测试用）。", visibility: .hidden))
    var socket: String?

    @Flag(name: .customLong("no-launch"), help: "App 没运行时不自动启动，直接报错。")
    var noLaunch = false
}

struct KeyboardOption: ParsableArguments {
    @Option(name: .shortAndLong, help: "键盘 ID（cherry keyboards 列出）；不填时使用唯一连接的键盘。")
    var keyboard: String?

    func validate() throws {
        try ArgumentLimit.check(keyboard, "--keyboard", ArgumentLimit.short)
    }
}

/// 字符串参数的长度上限：请求必须装进控制协议的一行（64 KiB），超长时在命令行就报用法错误，
/// 而不是让 App 断开连接、被误报成「App 已退出」。
enum ArgumentLimit {
    static let short = 64
    static let presetName = 256

    static func check(_ value: String?, _ name: String, _ limit: Int) throws {
        guard let value, value.count > limit else { return }
        throw ValidationError("\(name) 过长（\(value.count) 个字符，最多 \(limit) 个）")
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "输出 JSON。")
    var json = false
}

enum CLIError: Error, Equatable {
    case appUnavailable(String)
    case rejected(ControlFailure)
    case failed(String)

    init(_ error: ControlClientError) {
        switch error {
        case .unavailable: self = .appUnavailable("CHERRY Utility 没有运行")
        case .disconnected: self = .appUnavailable("CHERRY Utility 关闭了连接（可能已退出）")
        case .timeout: self = .failed("等待 CHERRY Utility 响应超时")
        case .pathTooLong(let path): self = .failed("socket 路径过长：\(path)")
        case .notASocket(let path): self = .failed("\(path) 不是 socket，而是被别的文件占用；删除或换一个路径后重启 CHERRY Utility")
        case .malformedResponse: self = .failed("CHERRY Utility 的响应格式不对（App 与命令行版本可能不一致）")
        case .system(let operation, let code): self = .failed("\(operation) 失败：\(String(cString: strerror(code)))")
        }
    }

    var exitCode: Int32 {
        switch self {
        case .appUnavailable: CherryExit.appUnavailable
        case .rejected: CherryExit.rejected
        case .failed: 1
        }
    }

    /// `--json` 与 MCP 使用的错误对象：App 拒绝时原样转发，连不上 App 或客户端出错时给出稳定的错误码。
    var failure: ControlFailure {
        switch self {
        case .rejected(let failure): failure
        case .appUnavailable(let message): ControlFailure(code: "appUnavailable", message: message)
        case .failed(let message): ControlFailure(code: "clientError", message: message)
        }
    }

    var message: String {
        switch self {
        case .appUnavailable(let message), .failed(let message): message
        case .rejected(let failure):
            ([failure.message] + (failure.candidates ?? []).map { "  \($0.id)  \($0.name)" }).joined(separator: "\n")
        }
    }
}

/// 到运行中 App 的一个连接。默认路径上没有 App 时在后台启动它；显式指定 socket 时不启动（测试与模拟模式）。
struct Session {
    let client: ControlClient

    static func open(
        _ options: ConnectionOptions, timeout: Duration? = .seconds(20),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(CLIError) -> Session {
        try open(socket: options.socket, noLaunch: options.noLaunch, timeout: timeout, environment: environment)
    }

    static func open(
        socket: String?, noLaunch: Bool, timeout: Duration? = .seconds(20),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(CLIError) -> Session {
        let explicit = socket ?? environment[ControlProtocol.socketEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        let path = explicit ?? ControlProtocol.defaultSocketPath
        do {
            return Session(client: try ControlClient.connect(path: path, timeout: timeout))
        } catch .unavailable where explicit == nil && !noLaunch {
            try launchApp()
            return try waitForApp(path: path, timeout: timeout)
        } catch .unavailable {
            throw .appUnavailable("CHERRY Utility 没有运行（socket：\(path)）")
        } catch {
            throw CLIError(error)
        }
    }

    func call(_ method: ControlMethod, _ params: ControlParams? = nil) throws(CLIError) -> ControlResult {
        let response: ControlResponse
        do { response = try client.call(method, params) } catch { throw CLIError(error) }
        guard response.ok, let result = response.result else {
            throw .rejected(response.error ?? ControlFailure(code: "internalError", message: "CHERRY Utility 没有返回结果"))
        }
        return result
    }

    /// 命令行工具在 App 包内（`CHERRY Utility.app/Contents/MacOS/cherry`，可经符号链接调用）时启动所在的 App，
    /// 否则按 bundle ID 启动已安装的 App。`--background` 让 App 不显示主窗口。
    private static func launchApp() throws(CLIError) {
        var arguments = ["-g", "-j"]
        if let bundle = enclosingAppBundle() {
            arguments += ["-a", bundle.path(percentEncoded: false)]
        } else {
            arguments += ["-b", ControlProtocol.bundleIdentifier]
        }
        arguments += ["--args", ControlProtocol.backgroundLaunchArgument]
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
        } catch {
            throw .appUnavailable("无法启动 CHERRY Utility：\(error.localizedDescription)")
        }
        // `open` 交给 LaunchServices 后立即返回；10 秒仍未结束就终止它，按启动失败处理。
        let deadline = Date.now.addingTimeInterval(10)
        while open.isRunning, Date.now < deadline { usleep(50_000) }
        if open.isRunning {
            open.terminate()
            open.waitUntilExit()
            throw .appUnavailable("启动 CHERRY Utility 超时")
        }
        guard open.terminationStatus == 0 else {
            throw .appUnavailable("找不到 CHERRY Utility。请先把它安装到「应用程序」并打开一次")
        }
    }

    static func enclosingAppBundle(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable = executable?.resolvingSymlinksInPath() else { return nil }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    /// App 冷启动后要先完成发现与组合根装配，socket 才会出现；最多等 10 秒。
    private static func waitForApp(path: String, timeout: Duration?) throws(CLIError) -> Session {
        for _ in 0..<100 {
            usleep(100_000)
            if let client = try? ControlClient.connect(path: path, timeout: timeout) { return Session(client: client) }
        }
        throw .appUnavailable("已启动 CHERRY Utility，但 10 秒内没有响应")
    }
}

/// 子命令的公共流程：连接、调用、按 `--json` 输出；错误写到标准错误并以对应退出码结束。
func perform(
    _ connection: ConnectionOptions, json: Bool, _ body: (Session) throws -> ControlResult,
    human: (ControlResult) -> String
) throws {
    do {
        let result = try body(try Session.open(connection))
        print(json ? Output.json(result) : human(result))
    } catch let error as CLIError {
        report(error, json: json)
        throw ExitCode(error.exitCode)
    }
}

/// 失败输出：文本模式写到标准错误；`--json` 时把 `{"error":{code,message,candidates}}` 写到标准输出，脚本能拿到错误码。
/// `watch --json` 每个事件一行，错误也写成一行（`line`），逐行解析的调用方不会读到半个对象。
func report(_ error: CLIError, json: Bool, line: Bool = false) {
    if json {
        let output = ErrorOutput(error: error.failure)
        print(line ? Output.jsonLine(output) : Output.json(output))
    } else {
        FileHandle.standardError.write(Data(("错误：" + error.message + "\n").utf8))
    }
}

struct ErrorOutput: Encodable {
    let error: ControlFailure
}
