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
        let explicit = options.socket ?? environment[ControlProtocol.socketEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        let path = explicit ?? ControlProtocol.defaultSocketPath
        do {
            return Session(client: try ControlClient.connect(path: path, timeout: timeout))
        } catch .unavailable where explicit == nil && !options.noLaunch {
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
        FileHandle.standardError.write(Data(("错误：" + error.message + "\n").utf8))
        throw ExitCode(error.exitCode)
    }
}
