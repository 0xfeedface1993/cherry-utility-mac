import CherryCore
import Foundation

/// Reads and edits the MCP server lists of Claude Desktop (`claude_desktop_config.json`) and Claude Code (`~/.claude.json`).
///
/// - A server counts as ours when it runs some `cherry` executable with the `mcp` argument, whatever its name.
/// - Only Claude Desktop is edited here. Before writing, the old file is kept as `<name>.bak-<time>`. Every other key and
///   server is preserved; a file that is not a JSON object is left untouched.
/// - Claude Code manages `~/.claude.json` itself (`claude mcp add`), so it is only read.
public struct ClaudeMCPClientRegistry: MCPClientRegistryPort {
    public static let serverName = "cherry"
    private let desktopConfig: URL
    private let codeConfig: URL
    private let now: @Sendable () -> Date

    public init(desktopConfig: URL, codeConfig: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.desktopConfig = desktopConfig
        self.codeConfig = codeConfig
        self.now = now
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(
            desktopConfig: home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json"),
            codeConfig: home.appending(path: ".claude.json")
        )
    }

    public func registration(in client: MCPClient) async -> MCPClientRegistration {
        let file = file(for: client)
        let installed = switch client {
        // Claude Desktop creates its support directory on first launch, before any configuration exists.
        case .claudeDesktop: FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
        case .claudeCode: FileManager.default.fileExists(atPath: file.path)
        }
        guard installed else { return .clientNotInstalled }
        guard FileManager.default.fileExists(atPath: file.path) else { return .notRegistered }
        switch Self.object(at: file) {
        case .failure(let reason): return .unreadable(reason: reason.message)
        case .success(let object):
            let servers = object["mcpServers"] as? [String: Any] ?? [:]
            return Self.ourServer(in: servers).map { .registered(command: $0) } ?? .notRegistered
        }
    }

    public func register(_ launch: MCPServerLaunch, in client: MCPClient) async throws {
        guard client == .claudeDesktop else { throw AutomationSetupError.managedByClient(client) }
        let file = desktopConfig
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else {
            throw AutomationSetupError.io("没有找到 Claude Desktop（\(file.deletingLastPathComponent().path) 不存在）")
        }
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            switch Self.object(at: file) {
            case .failure(let reason): throw AutomationSetupError.unreadableConfiguration(path: file.path, reason: reason.message)
            case .success(let existing): object = existing
            }
        }
        object["mcpServers"] = Self.merging(launch, into: object["mcpServers"] as? [String: Any] ?? [:])
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: file, to: backupURL(for: file))
            }
            try data.write(to: file, options: .atomic)
        } catch {
            throw AutomationSetupError.io(error.localizedDescription)
        }
    }

    // MARK: - Pure rules

    /// The existing `cherry … mcp` entry (under any name) is replaced; otherwise one named `cherry` is added.
    static func merging(_ launch: MCPServerLaunch, into servers: [String: Any]) -> [String: Any] {
        var servers = servers
        let name = servers.first { isOurs($0.value) }?.key ?? serverName
        servers[name] = ["command": launch.command, "args": launch.arguments]
        return servers
    }

    static func ourServer(in servers: [String: Any]) -> String? {
        servers.values.first(where: isOurs).flatMap { ($0 as? [String: Any])?["command"] as? String }
    }

    static func isOurs(_ server: Any) -> Bool {
        guard let server = server as? [String: Any], let command = server["command"] as? String else { return false }
        let arguments = server["args"] as? [String] ?? []
        return URL(fileURLWithPath: command).lastPathComponent == "cherry" && arguments.first == "mcp"
    }

    struct Unreadable: Error { let message: String }

    static func object(at file: URL) -> Result<[String: Any], Unreadable> {
        guard let data = try? Data(contentsOf: file) else { return .failure(Unreadable(message: "读不出文件")) }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .success([:]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .failure(Unreadable(message: "不是有效的 JSON")) }
        guard let dictionary = object as? [String: Any] else { return .failure(Unreadable(message: "顶层不是对象")) }
        return .success(dictionary)
    }

    private func file(for client: MCPClient) -> URL {
        switch client {
        case .claudeDesktop: desktopConfig
        case .claudeCode: codeConfig
        }
    }

    private func backupURL(for file: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).bak-\(formatter.string(from: now()))")
    }
}
