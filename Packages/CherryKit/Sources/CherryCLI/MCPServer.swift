import ArgumentParser
import CherryControl
import Dispatch
import Foundation
import MCP
import Synchronization

/// `cherry mcp`：stdio 上的 MCP 服务，供 Claude Code、Claude Desktop 等 AI 客户端读取和设置键盘。
/// 每次工具调用都按命令行的规则选路：App 在运行就经控制 socket 交给它执行，否则直接连接键盘。
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "作为 MCP 服务运行（stdio），供 Claude Code / Claude Desktop 等 AI 客户端读取和设置键盘。",
        discussion: """
        由 AI 客户端启动，经标准输入输出交换 JSON-RPC 消息，不要直接在终端里运行。
        注册到 Claude Code（<App> 为 App 包的路径，Finder 里显示为 CHERRY Utility，如 /Applications/CherryUtility.app）：
          claude mcp add --scope user cherry -- "<App>/Contents/MacOS/cherry" mcp
        """
    )
    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let backend = MCPBackend.routed(connection)
        let server = await CherryMCP.server(version: CherryMCP.version(), backend: backend)
        let stdio = MCPStdioTransport()
        try await server.start(transport: DrainingTransport(stdio, logger: stdio.logger))
        // 客户端关闭标准输入时消息循环结束；DrainingTransport 先等进行中的响应发出。
        await server.waitUntilCompleted()
        await server.stop()
    }
}

enum CherryMCP {
    static let name = "cherry-utility"

    static let instructions = """
    读取和设置本机连接的 CHERRY 键盘（配置档、灯效、亮度、速度、颜色、休眠、灯光预设）。CHERRY Utility 在运行时经由它执行，否则直接连接键盘。\
    不填 keyboard 时使用唯一连接的键盘；写入类工具不填 profile 时修改当前配置档。\
    灯效表因型号而异，可先用 list_lighting_effects 查看。不提供固件操作。
    """

    static func server(version: String, backend: MCPBackend) async -> Server {
        let server = Server(
            name: name, version: version, title: "CHERRY Utility", instructions: instructions,
            capabilities: Server.Capabilities(tools: Server.Capabilities.Tools(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: CherryTool.allCases.map(\.definition))
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await call(params, backend: backend)
        }
        return server
    }

    /// 未知工具是协议错误；参数不合要求、App 拒绝或连不上 App 都是 `isError` 的工具结果。取消向上传播，SDK 不回应。
    static func call(_ params: CallTool.Parameters, backend: MCPBackend) async throws -> CallTool.Result {
        guard let tool = CherryTool(rawValue: params.name) else {
            throw MCPError.invalidParams("未知工具 \(params.name)")
        }
        let request: ControlParams
        do {
            request = try tool.params(from: params.arguments)
        } catch {
            return ToolOutput.failure(code: "invalidArgument", message: error.message)
        }
        do {
            return ToolOutput.success(tool, try await backend.call(tool.method, request))
        } catch let error as CLIError {
            return ToolOutput.failure(error)
        }
    }

    /// 这个 cherry 的版本：独立安装时取自身内嵌的 Info.plist，在 App 包内时与 App 相同，`swift build` 时为 `dev`。
    static func version(executable: URL? = Bundle.main.executableURL, own: [String: Any]? = Bundle.main.infoDictionary) -> String {
        CherryVersion.current(executable: executable, own: own).app
    }
}

/// 工具调用到 App 的一次请求。
struct MCPBackend: Sendable {
    let call: @Sendable (ControlMethod, ControlParams) async throws -> ControlResult

    /// 每次调用重新路由（`Session.open`）：App 在运行就经由它，不在就直连键盘；App 后来启动了，之后的调用就经由它。
    /// 在 GCD 线程上同步完成，不占用协作线程。请求标明来自 MCP，App 据此套用 MCP 的开关。
    static func routed(
        _ options: ConnectionOptions, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPBackend {
        let (socket, viaApp, direct, noLaunch) = (options.socket, options.viaApp, options.direct, options.noLaunch)
        return MCPBackend { method, params in
            try await offload {
                try Session.open(
                    socket: socket, viaApp: viaApp, direct: direct, noLaunch: noLaunch, client: ControlClientKind.mcp, environment: environment
                ).call(method, params)
            }
        }
    }
}

/// 在 GCD 线程上执行同步阻塞的调用（socket 读写、等待 App 启动），不占用 Swift 并发的协作线程池。
/// 任务被取消时立即以 `CancellationError` 返回；阻塞调用本身无法中断，会在 socket 超时内结束，结果被丢弃。
func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let gate = ContinuationGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard gate.install(continuation) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            DispatchQueue.global().async {
                let result = Result { try body() }
                gate.take()?.resume(with: result)
            }
        }
    } onCancel: {
        gate.cancel()?.resume(throwing: CancellationError())
    }
}

/// `offload` 的 continuation 只恢复一次：完成与取消谁先到谁恢复。锁内只交换状态，恢复在锁外。
private final class ContinuationGate<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, any Error>)
        case cancelled
        case finished
    }

    private let state = Mutex(State.idle)

    /// 已取消时返回 false，由调用方立即恢复。
    func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        state.withLock { state in
            guard case .idle = state else { return false }
            state = .waiting(continuation)
            return true
        }
    }

    func take() -> CheckedContinuation<T, any Error>? {
        state.withLock { state in
            guard case .waiting(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
    }

    func cancel() -> CheckedContinuation<T, any Error>? {
        state.withLock { state in
            switch state {
            case .idle:
                state = .cancelled
                return nil
            case .waiting(let continuation):
                state = .cancelled
                return continuation
            case .cancelled, .finished:
                return nil
            }
        }
    }
}

/// 工具结果：第一段是中文说明（与命令行的文本输出相同，写入类为 App 返回的 `message`），
/// 第二段是同一结果的 JSON，`structuredContent` 也是它。
enum ToolOutput {
    static func success(_ tool: CherryTool, _ result: ControlResult) -> CallTool.Result {
        let text: String
        switch tool {
        case .listKeyboards: text = Output.keyboards(result)
        case .getStatus: text = Output.status(result)
        case .listLightingEffects: text = Output.effects(result)
        case .listPresets: text = Output.presets(result)
        case .getBattery, .switchProfile, .setLighting, .setSleepTimers, .applyPreset: text = Output.message(result)
        }
        return make(text: text, structured: result, isError: false)
    }

    static func failure(_ error: CLIError) -> CallTool.Result {
        make(text: error.message, structured: ErrorPayload(error: error.failure), isError: true)
    }

    static func failure(code: String, message: String) -> CallTool.Result {
        make(text: message, structured: ErrorPayload(error: ControlFailure(code: code, message: message)), isError: true)
    }

    private struct ErrorPayload: Encodable {
        let error: ControlFailure
    }

    private static func make(text: String, structured: some Encodable, isError: Bool) -> CallTool.Result {
        let json = Output.jsonLine(structured)
        // `Value?`：避开 SDK 里会抛错的泛型重载。
        let value: Value? = (try? JSONDecoder().decode(Value.self, from: Data(json.utf8))) ?? .object([:])
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil), .text(text: json, annotations: nil, _meta: nil)],
            structuredContent: value, isError: isError ? true : nil
        )
    }
}
