import CherryCore
import CherryPresentation
import Foundation

// 「设置 › 自动化」的状态文字。Core 只给类型化的状态，文字在这里。

extension AutomationEntriesSnapshot {
    func activityText(_ entry: AutomationEntry, now: Date = Date()) -> String {
        let record = activity[entry]
        guard let call = record.lastCall else { return "还没有调用" }
        let route = call.route == .viaApp ? "经由 App" : "命令行直连"
        let outcome = call.succeeded ? "成功" : "失败"
        return "最近：\(Self.time(call.date, now: now)) · \(call.operation) · \(route) · \(outcome)（共 \(record.count) 次）"
    }

    var endpointText: String {
        switch endpoint {
        case .off: "没有开启控制 socket（模拟模式下没有指定）"
        case .listening(let path): "正在监听 \(path)"
        case .servedByAnotherInstance(let path): "另一个 CHERRY Utility 实例正在服务 \(path)"
        case .unavailable(let path, let reason): "无法监听 \(path)：\(reason)"
        }
    }

    var commandLineToolText: String {
        switch commandLineTool {
        case .notInstalled: "未安装。安装后可以在终端里直接运行 cherry"
        case .linkedToBundledTool(let path): "已安装：\(path)（链接到本 App 自带的 cherry）"
        case .standalone(let path): "已独立安装：\(path)"
        case .other(let path, let target): "\(path) 指向 \(target)"
        }
    }

    var canInstallCommandLineTool: Bool {
        guard bundledTool != nil else { return false }
        switch commandLineTool {
        case .notInstalled, .other: return true
        case .linkedToBundledTool, .standalone: return false
        }
    }

    var canUninstallCommandLineTool: Bool {
        if case .linkedToBundledTool = commandLineTool { return true }
        return false
    }

    func registrationText(_ client: MCPClient) -> String {
        switch registrations[client] ?? .notRegistered {
        case .clientNotInstalled: "没有找到 \(AutomationText.name(of: client))"
        case .notRegistered: "未添加"
        case .registered(let command): "已添加（\(command)）"
        case .unreadable(let reason): "配置无法读取：\(reason)"
        }
    }

    func canRegister(_ client: MCPClient) -> Bool {
        guard launch != nil else { return false }
        switch registrations[client] ?? .notRegistered {
        case .notRegistered, .registered: return true
        case .clientNotInstalled, .unreadable: return false
        }
    }

    /// `claude mcp add --scope user cherry -- "<cherry>" mcp`
    var claudeCodeCommand: String? {
        launch.map { launch in
            (["claude mcp add --scope user cherry --", "\"\(launch.command)\""] + launch.arguments).joined(separator: " ")
        }
    }

    /// 其他 MCP 客户端通用的 `mcpServers` 片段。
    var mcpConfigurationJSON: String? {
        guard let launch else { return nil }
        let object: [String: Any] = ["mcpServers": ["cherry": ["command": launch.command, "args": launch.arguments]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func time(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(clock)" }
        return date.formatted(.dateTime.month().day()) + " " + clock
    }
}
