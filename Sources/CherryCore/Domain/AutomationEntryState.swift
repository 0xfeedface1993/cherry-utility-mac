import Foundation

/// 外部自动化入口。快捷指令与 Spotlight 在 App 进程内执行，不经过这里。
public enum AutomationEntry: String, CaseIterable, Codable, Sendable {
    case commandLine
    case mcp
}

/// 请求是怎样到达 Core 的：经由运行中的 App，或在命令行进程内直接连接键盘。
public enum AutomationRoute: String, Codable, Sendable {
    case viaApp
    case direct
}

/// 一次自动化调用。`operation` 是控制协议的方法名（`status`、`update` …）。
public struct AutomationCall: Equatable, Codable, Sendable {
    public var entry: AutomationEntry
    public var operation: String
    public var succeeded: Bool
    public var route: AutomationRoute
    public var date: Date

    public init(entry: AutomationEntry, operation: String, succeeded: Bool, route: AutomationRoute, date: Date) {
        self.entry = entry
        self.operation = operation
        self.succeeded = succeeded
        self.route = route
        self.date = date
    }
}

public struct AutomationEntryActivity: Equatable, Codable, Sendable {
    public var lastCall: AutomationCall?
    /// 自活动记录建立以来的调用次数（App 与命令行共用同一份记录）。
    public var count: Int

    public init(lastCall: AutomationCall? = nil, count: Int = 0) {
        self.lastCall = lastCall
        self.count = count
    }
}

/// App 与命令行共用的调用记录，供「设置 › 自动化」显示。
public struct AutomationActivity: Equatable, Codable, Sendable {
    public var commandLine = AutomationEntryActivity()
    public var mcp = AutomationEntryActivity()

    public init() {}

    public subscript(entry: AutomationEntry) -> AutomationEntryActivity {
        get {
            switch entry {
            case .commandLine: commandLine
            case .mcp: mcp
            }
        }
        set {
            switch entry {
            case .commandLine: commandLine = newValue
            case .mcp: mcp = newValue
            }
        }
    }

    public func recording(_ call: AutomationCall) -> Self {
        var next = self
        next[call.entry] = AutomationEntryActivity(lastCall: call, count: self[call.entry].count + 1)
        return next
    }
}

/// `cherry` 命令在 PATH 里的安装情况。
public enum CommandLineToolStatus: Equatable, Sendable {
    case notInstalled
    /// 符号链接，指向本 App 包内的 cherry。
    case linkedToBundledTool(path: String)
    /// 独立安装的 cherry（Homebrew cask 或手动复制），不在任何 App 包里。
    case standalone(path: String)
    /// 符号链接，指向别处（另一份 App 或已不存在的文件）。
    case other(path: String, target: String)

    /// MCP 客户端应当调用的 cherry：独立安装的优先，其次是链接到 App 包内的那一个。
    public var installedPath: String? {
        switch self {
        case .standalone(let path), .linkedToBundledTool(let path): path
        case .notInstalled, .other: nil
        }
    }
}

/// 能注册 `cherry mcp` 的客户端。
public enum MCPClient: String, CaseIterable, Sendable {
    case claudeDesktop
    case claudeCode
}

public enum MCPClientRegistration: Equatable, Sendable {
    /// 客户端没有安装（找不到它的配置）。
    case clientNotInstalled
    case notRegistered
    /// 已注册；`command` 是配置里写的可执行文件。
    case registered(command: String)
    /// 配置文件存在但读不懂，不去改它。
    case unreadable(reason: String)
}

/// MCP 客户端启动服务的方式：`<command> mcp`。
public struct MCPServerLaunch: Equatable, Sendable {
    public var command: String
    public var arguments: [String]

    public init(command: String, arguments: [String] = ["mcp"]) {
        self.command = command
        self.arguments = arguments
    }
}

/// App 的控制 socket 的状态。
public enum ControlEndpointStatus: Equatable, Sendable {
    /// 没有开启（模拟模式下没有指定 socket，或者是命令行进程自己）。
    case off
    case listening(path: String)
    /// 另一个 App 实例已在这个路径上应答。
    case servedByAnotherInstance(path: String)
    case unavailable(path: String, reason: String)
}

/// 「设置 › 自动化」显示的全部状态。
public struct AutomationEntriesSnapshot: Equatable, Sendable {
    public var enabled: [AutomationEntry: Bool]
    public var activity: AutomationActivity
    public var endpoint: ControlEndpointStatus
    public var commandLineTool: CommandLineToolStatus
    /// 本 App 包内 cherry 的路径；独立的命令行进程没有。
    public var bundledTool: String?
    public var registrations: [MCPClient: MCPClientRegistration]
    /// 注册到 MCP 客户端时用的启动方式；没有可用的 cherry 时为 nil。
    public var launch: MCPServerLaunch?

    public init(
        enabled: [AutomationEntry: Bool], activity: AutomationActivity, endpoint: ControlEndpointStatus,
        commandLineTool: CommandLineToolStatus, bundledTool: String?, registrations: [MCPClient: MCPClientRegistration],
        launch: MCPServerLaunch?
    ) {
        self.enabled = enabled
        self.activity = activity
        self.endpoint = endpoint
        self.commandLineTool = commandLineTool
        self.bundledTool = bundledTool
        self.registrations = registrations
        self.launch = launch
    }
}

/// 把 cherry 装进 PATH、注册到 MCP 客户端时的失败原因。
public enum AutomationSetupError: Error, Equatable, Sendable {
    /// 没有可用的 cherry：既没有独立安装，也不在 App 里运行。
    case noCommandLineTool
    /// 安装目录里已有独立安装的 cherry，不覆盖。
    case standaloneToolInstalled(path: String)
    /// 安装目录里的 cherry 指向别处（不是某个 CherryUtility.app），不动它。
    case foreignTool(path: String)
    /// 用户在管理员授权对话框里取消了。
    case authorizationCancelled
    /// 客户端的配置读不懂，不去改它。
    case unreadableConfiguration(path: String, reason: String)
    /// 这个客户端的配置由它自己的命令管理（Claude Code 用 `claude mcp add`）。
    case managedByClient(MCPClient)
    case io(String)
}
