import CherryCore
import Foundation

/// Puts the app's bundled `cherry` on the PATH as a symbolic link (by default `/usr/local/bin/cherry`), and reports what
/// a shell would find in the usual bin directories.
///
/// The link is made directly when the directory is writable; otherwise, if allowed, through the system's administrator
/// authorization dialog (`osascript … with administrator privileges`), where the user types the password. Simulation and
/// tests point it at a temporary directory and disallow the dialog.
public struct SymlinkCommandLineToolInstaller: CommandLineToolInstallerPort {
    public let bundledTool: String?
    private let installDirectory: URL
    private let searchDirectories: [URL]
    private let allowsAuthorization: Bool

    public init(bundledTool: String?, installDirectory: URL, searchDirectories: [URL], allowsAuthorization: Bool) {
        self.bundledTool = bundledTool
        self.installDirectory = installDirectory
        self.searchDirectories = [installDirectory] + searchDirectories.filter { $0.standardizedFileURL != installDirectory.standardizedFileURL }
        self.allowsAuthorization = allowsAuthorization
    }

    /// `/usr/local/bin`, then Homebrew's and the user's bin directories.
    public static func standardSearchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin"), home.appending(path: ".local/bin")]
    }

    public func status() async -> CommandLineToolStatus {
        for directory in searchDirectories {
            let status = Self.status(at: directory.appending(path: "cherry").path, bundledTool: bundledTool)
            if status != .notInstalled { return status }
        }
        return .notInstalled
    }

    public func install() async throws {
        guard let bundledTool else { throw AutomationSetupError.noCommandLineTool }
        let link = installDirectory.appending(path: "cherry").path
        switch Self.status(at: link, bundledTool: bundledTool) {
        case .standalone(let path): throw AutomationSetupError.standaloneToolInstalled(path: path)
        case .other(let path, let target) where !Self.isBundledCherry(target): throw AutomationSetupError.foreignTool(path: path)
        case .linkedToBundledTool: return
        case .notInstalled, .other: break
        }
        if Self.isWritable(installDirectory) {
            do {
                try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
                if Self.exists(link) { try FileManager.default.removeItem(atPath: link) }
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: bundledTool)
            } catch {
                throw AutomationSetupError.io(error.localizedDescription)
            }
        } else {
            try await runWithAuthorization(
                "/bin/mkdir -p \(Self.quoted(installDirectory.path)) && /bin/ln -sfh \(Self.quoted(bundledTool)) \(Self.quoted(link))"
            )
        }
    }

    public func uninstall() async throws {
        let link = installDirectory.appending(path: "cherry").path
        switch Self.status(at: link, bundledTool: bundledTool) {
        case .notInstalled: return
        case .standalone(let path): throw AutomationSetupError.standaloneToolInstalled(path: path)
        case .other(let path, let target) where !Self.isBundledCherry(target): throw AutomationSetupError.foreignTool(path: path)
        case .linkedToBundledTool, .other: break
        }
        if Self.isWritable(installDirectory) {
            do { try FileManager.default.removeItem(atPath: link) } catch { throw AutomationSetupError.io(error.localizedDescription) }
        } else {
            try await runWithAuthorization("/bin/rm -f \(Self.quoted(link))")
        }
    }

    // MARK: - Classification

    static func status(at path: String, bundledTool: String?) -> CommandLineToolStatus {
        guard exists(path) else { return .notInstalled }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return .standalone(path: path)
        }
        let target = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: path).deletingLastPathComponent())
            .standardizedFileURL.resolvingSymlinksInPath().path
        if let bundledTool, target == URL(fileURLWithPath: bundledTool).standardizedFileURL.resolvingSymlinksInPath().path {
            return .linkedToBundledTool(path: path)
        }
        // Homebrew links its casks' binaries the same way; a target outside any app bundle is a standalone install.
        if !target.contains(".app/Contents/"), FileManager.default.isExecutableFile(atPath: target) {
            return .standalone(path: path)
        }
        return .other(path: path, target: target)
    }

    /// `cherry` inside some copy of the app (another build, an older location): ours to replace or remove.
    static func isBundledCherry(_ target: String) -> Bool {
        target.hasSuffix("/Contents/MacOS/cherry") && target.contains("CherryUtility.app")
    }

    private static func exists(_ path: String) -> Bool {
        // `fileExists` follows links; a dangling link still occupies the name.
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func isWritable(_ directory: URL) -> Bool {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return false }
            probe = parent
        }
        return FileManager.default.isWritableFile(atPath: probe.path)
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Administrator authorization

    private func runWithAuthorization(_ command: String) async throws {
        guard allowsAuthorization else { throw AutomationSetupError.io("没有写入 \(installDirectory.path) 的权限") }
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: AutomationSetupError.io(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // AppleScript error -128: the user cancelled the dialog.
            if message.contains("-128") { throw AutomationSetupError.authorizationCancelled }
            throw AutomationSetupError.io(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
