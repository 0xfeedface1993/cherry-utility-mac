@testable import CherryAdapters
import CherryCore
import Foundation
import Synchronization
import Testing

/// 两个 `FileDeviceLock` 实例各开各的文件描述，flock 在它们之间互斥，相当于两个进程。
@Suite("跨进程设备锁")
struct FileDeviceLockTests {
    static let keyboard = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0310_0000)

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CherryLocks-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func anotherProcessWaitsUntilTheLeaseIsReleased() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FileDeviceLock(directory: directory)
        let cli = FileDeviceLock(directory: directory, waitLimit: .milliseconds(150))
        let held = try await app.acquire(Self.keyboard, purpose: .session)
        await #expect(throws: CherryError.deviceBusy(.inUse)) { _ = try await cli.acquire(Self.keyboard, purpose: .session) }
        held.release()
        let lease = try await cli.acquire(Self.keyboard, purpose: .session)
        lease.release()
        lease.release()
    }

    /// 进程内按键盘计数：最后一个租约释放后，别的进程才拿得到。
    @Test func leasesAreCountedWithinTheProcess() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FileDeviceLock(directory: directory)
        let cli = FileDeviceLock(directory: directory, waitLimit: .milliseconds(100))
        let first = try await app.acquire(Self.keyboard, purpose: .session)
        let second = try await app.acquire(Self.keyboard, purpose: .session)
        first.release()
        await #expect(throws: CherryError.deviceBusy(.inUse)) { _ = try await cli.acquire(Self.keyboard, purpose: .session) }
        second.release()
        try await cli.acquire(Self.keyboard, purpose: .session).release()
    }

    /// 刷写期间另一个进程立即被拒绝，不等到超时；刷写结束后标记清除。
    @Test func aFirmwareUpdateRefusesOtherProcessesAtOnce() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FileDeviceLock(directory: directory)
        let cli = FileDeviceLock(directory: directory, waitLimit: .seconds(5))
        let update = try await app.acquire(Self.keyboard, purpose: .firmwareUpdate)
        let session = try await app.acquire(Self.keyboard, purpose: .session)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect(throws: CherryError.deviceBusy(.updatingFirmware)) { _ = try await cli.acquire(Self.keyboard, purpose: .session) }
        }
        #expect(elapsed < .seconds(1))
        update.release()
        let quick = FileDeviceLock(directory: directory, waitLimit: .milliseconds(100))
        await #expect(throws: CherryError.deviceBusy(.inUse)) { _ = try await quick.acquire(Self.keyboard, purpose: .session) }
        session.release()
        try await cli.acquire(Self.keyboard, purpose: .session).release()
    }

    /// 刷写中崩溃的进程留下的标记不会挡住后来者：锁没人持有就能取得，取得后标记被清掉。
    @Test func aStaleUpdateMarkerIsIgnoredAndCleared() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "046A-01E2-03100000.lock")
        try Data("firmwareUpdate".utf8).write(to: file)
        let app = FileDeviceLock(directory: directory)
        let lease = try await app.acquire(Self.keyboard, purpose: .session)
        #expect(try String(contentsOf: file, encoding: .utf8).isEmpty)
        lease.release()
    }

    @Test func waitingIsCancellable() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FileDeviceLock(directory: directory)
        let cli = FileDeviceLock(directory: directory, waitLimit: .seconds(30))
        let held = try await app.acquire(Self.keyboard, purpose: .session)
        let waiter = Task { try await cli.acquire(Self.keyboard, purpose: .session) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        held.release()
    }

    /// 不同键盘互不影响。
    @Test func keyboardsAreIndependent() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FileDeviceLock(directory: directory)
        let cli = FileDeviceLock(directory: directory, waitLimit: .milliseconds(100))
        let held = try await app.acquire(Self.keyboard, purpose: .session)
        let other = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0320_0000)
        try await cli.acquire(other, purpose: .session).release()
        held.release()
    }
}

@Suite("跨进程信号")
struct DarwinNotifySignalTests {
    /// 自己发的信号被跳过；另一个进程发的才送达。这里用系统的 notifyutil 扮演另一个进程，像 `post` 一样先写入发送方 pid。
    @Test func onlySignalsFromOtherProcessesArrive() async throws {
        let signal = DarwinNotifySignal(namespace: "online.odeployer.CherryUtility.tests.\(UUID().uuidString)")
        let received = Mutex(0)
        let stream = signal.signals(.configurationChanged)
        // 一个常驻任务消费：取消正在等待的迭代会结束整个流。
        let consumer = Task {
            for await _ in stream { received.withLock { $0 += 1 } }
        }
        defer { consumer.cancel() }
        signal.post(.configurationChanged)
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.withLock { $0 } == 0)
        let poster = Process()
        poster.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        poster.arguments = ["-s", signal.name(of: .configurationChanged), "1", "-p", signal.name(of: .configurationChanged)]
        try poster.run()
        poster.waitUntilExit()
        for _ in 0..<30 where received.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(received.withLock { $0 } == 1)
    }
}

@Suite("自动化入口的共享偏好与调用记录")
struct AutomationSharingTests {
    @Test func switchesDefaultToOnAndPersistInTheDomain() {
        let domain = "online.odeployer.CherryUtility.tests.\(UUID().uuidString)"
        let preferences = SharedAutomationPreferences(domain: domain)
        defer {
            for entry in AutomationEntry.allCases {
                CFPreferencesSetAppValue(SharedAutomationPreferences.key(entry) as CFString, nil, domain as CFString)
            }
            CFPreferencesAppSynchronize(domain as CFString)
        }
        #expect(preferences.isEnabled(.commandLine) && preferences.isEnabled(.mcp))
        preferences.setEnabled(.mcp, false)
        // 另一个实例（另一个进程）读到同一个值。
        #expect(SharedAutomationPreferences(domain: domain).isEnabled(.mcp) == false)
        #expect(SharedAutomationPreferences(domain: domain).isEnabled(.commandLine))
    }

    @Test func concurrentRecordsAreNotLost() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CherryActivity-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "automation-activity.json")
        #expect(FileAutomationActivityStore(file: file).load() == AutomationActivity())
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            // 每次一个新实例，像不同进程那样各自读写文件。
            let store = FileAutomationActivityStore(file: file)
            let entry: AutomationEntry = index.isMultiple(of: 2) ? .mcp : .commandLine
            try? store.record(AutomationCall(entry: entry, operation: "status", succeeded: true, route: .direct, date: Date()))
        }
        let activity = FileAutomationActivityStore(file: file).load()
        #expect(activity.mcp.count == 20 && activity.commandLine.count == 20)
        #expect(activity.mcp.lastCall?.route == .direct && activity.mcp.lastCall?.operation == "status")
    }
}

@Suite("命令行工具安装")
struct CommandLineToolInstallerTests {
    struct Fixture {
        let root: URL
        let bundled: String
        let bin: URL
        let brew: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "CherryInstall-\(UUID().uuidString)", directoryHint: .isDirectory)
            bundled = try Self.executable(at: root.appending(path: "Apps/CherryUtility.app/Contents/MacOS/cherry"))
            bin = root.appending(path: "usr-local-bin", directoryHint: .isDirectory)
            brew = root.appending(path: "opt-homebrew-bin", directoryHint: .isDirectory)
        }

        func installer(allowsAuthorization: Bool = false, bundled: String? = nil) -> SymlinkCommandLineToolInstaller {
            SymlinkCommandLineToolInstaller(
                bundledTool: bundled ?? self.bundled, installDirectory: bin, searchDirectories: [brew], allowsAuthorization: allowsAuthorization
            )
        }

        @discardableResult
        static func executable(at url: URL) throws -> String {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func installLinksTheBundledToolAndUninstallRemovesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer()
        #expect(await installer.status() == .notInstalled)
        try await installer.install()
        let link = fixture.bin.appending(path: "cherry").path
        #expect(await installer.status() == .linkedToBundledTool(path: link))
        try await installer.install()
        try await installer.uninstall()
        #expect(await installer.status() == .notInstalled)
        try await installer.uninstall()
    }

    /// 独立安装的 cherry（例如 Homebrew）优先显示，也不会被覆盖。
    @Test func aStandaloneInstallationIsReportedAndNeverReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let caskroom = try Fixture.executable(at: fixture.root.appending(path: "Caskroom/cherry-cli/1.2.0/cherry"))
        try FileManager.default.createDirectory(at: fixture.brew, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.brew.appending(path: "cherry").path, withDestinationPath: caskroom)
        let installer = fixture.installer()
        #expect(await installer.status() == .standalone(path: fixture.brew.appending(path: "cherry").path))
        // 安装目录里放一个真文件：拒绝覆盖。
        try Fixture.executable(at: fixture.bin.appending(path: "cherry"))
        await #expect(throws: AutomationSetupError.standaloneToolInstalled(path: fixture.bin.appending(path: "cherry").path)) {
            try await installer.install()
        }
        await #expect(throws: AutomationSetupError.standaloneToolInstalled(path: fixture.bin.appending(path: "cherry").path)) {
            try await installer.uninstall()
        }
    }

    /// 指向另一份 App 的链接可以改指向本 App；指向别的东西的链接不动。
    @Test func linksToOtherAppCopiesAreReplacedButForeignLinksAreLeftAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let otherCopy = try Fixture.executable(at: fixture.root.appending(path: "Old/CherryUtility.app/Contents/MacOS/cherry"))
        try FileManager.default.createDirectory(at: fixture.bin, withIntermediateDirectories: true)
        let link = fixture.bin.appending(path: "cherry").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: otherCopy)
        let installer = fixture.installer()
        #expect(await installer.status() == .other(path: link, target: URL(fileURLWithPath: otherCopy).resolvingSymlinksInPath().path))
        try await installer.install()
        #expect(await installer.status() == .linkedToBundledTool(path: link))

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.root.appending(path: "Other.app/Contents/MacOS/tool").path)
        await #expect(throws: AutomationSetupError.foreignTool(path: link)) { try await installer.install() }
        await #expect(throws: AutomationSetupError.foreignTool(path: link)) { try await installer.uninstall() }
    }

    @Test func anUnwritableDirectoryNeedsAuthorization() async throws {
        let fixture = try Fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.bin.path)
            fixture.cleanUp()
        }
        try FileManager.default.createDirectory(at: fixture.bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.bin.path)
        await #expect(throws: AutomationSetupError.io("没有写入 \(fixture.bin.path) 的权限")) { try await fixture.installer().install() }
        await #expect(throws: AutomationSetupError.noCommandLineTool) {
            try await SymlinkCommandLineToolInstaller(bundledTool: nil, installDirectory: fixture.bin, searchDirectories: [], allowsAuthorization: false).install()
        }
    }

    @Test func pathsAreQuotedForTheShell() {
        #expect(SymlinkCommandLineToolInstaller.quoted("/Applications/CHERRY Utility's.app") == #"'/Applications/CHERRY Utility'\''s.app'"#)
    }
}

@Suite("MCP 客户端注册")
struct ClaudeMCPClientRegistryTests {
    struct Fixture {
        let home: URL
        let registry: ClaudeMCPClientRegistry
        var desktop: URL { home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }
        var code: URL { home.appending(path: ".claude.json") }

        init() {
            home = FileManager.default.temporaryDirectory.appending(path: "CherryClaude-\(UUID().uuidString)", directoryHint: .isDirectory)
            registry = ClaudeMCPClientRegistry.standard(home: home)
        }

        func json(_ url: URL) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }

        func cleanUp() { try? FileManager.default.removeItem(at: home) }
    }

    static let launch = MCPServerLaunch(command: "/Applications/CherryUtility.app/Contents/MacOS/cherry")

    @Test func claudeDesktopIsRegisteredWithoutTouchingOtherServers() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        #expect(await fixture.registry.registration(in: .claudeDesktop) == .clientNotInstalled)
        await #expect(throws: (any Error).self) { try await fixture.registry.register(Self.launch, in: .claudeDesktop) }

        try FileManager.default.createDirectory(at: fixture.desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(await fixture.registry.registration(in: .claudeDesktop) == .notRegistered)
        let existing = #"{"globalShortcut":"Cmd+Space","mcpServers":{"files":{"command":"npx","args":["-y","server-files"]}}}"#
        try Data(existing.utf8).write(to: fixture.desktop)
        try await fixture.registry.register(Self.launch, in: .claudeDesktop)

        let object = try fixture.json(fixture.desktop)
        #expect(object["globalShortcut"] as? String == "Cmd+Space")
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["cherry", "files"])
        #expect((servers["cherry"] as? [String: Any])?["args"] as? [String] == ["mcp"])
        #expect(await fixture.registry.registration(in: .claudeDesktop) == .registered(command: Self.launch.command))
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.desktop.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("claude_desktop_config.json.bak-") }
        #expect(backups.count == 1)
    }

    /// 已有的 `cherry … mcp`（不论叫什么名字）就地更新，不重复添加。
    @Test func anExistingEntryIsUpdatedInPlace() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"keyboard":{"command":"/usr/local/bin/cherry","args":["mcp"]}}}"#.utf8).write(to: fixture.desktop)
        try await fixture.registry.register(Self.launch, in: .claudeDesktop)
        let servers = try #require(try fixture.json(fixture.desktop)["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["keyboard"])
        #expect((servers["keyboard"] as? [String: Any])?["command"] as? String == Self.launch.command)
    }

    @Test func unreadableConfigurationsAreLeftUntouched() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fixture.desktop)
        #expect(await fixture.registry.registration(in: .claudeDesktop) == .unreadable(reason: "不是有效的 JSON"))
        await #expect(throws: AutomationSetupError.unreadableConfiguration(path: fixture.desktop.path, reason: "不是有效的 JSON")) {
            try await fixture.registry.register(Self.launch, in: .claudeDesktop)
        }
        #expect(try String(contentsOf: fixture.desktop, encoding: .utf8) == "{ not json")
        try Data("[1, 2]".utf8).write(to: fixture.desktop)
        #expect(await fixture.registry.registration(in: .claudeDesktop) == .unreadable(reason: "顶层不是对象"))
    }

    @Test func claudeCodeIsOnlyRead() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        #expect(await fixture.registry.registration(in: .claudeCode) == .clientNotInstalled)
        try FileManager.default.createDirectory(at: fixture.home, withIntermediateDirectories: true)
        try Data(#"{"numStartups":3}"#.utf8).write(to: fixture.code)
        #expect(await fixture.registry.registration(in: .claudeCode) == .notRegistered)
        try Data(#"{"mcpServers":{"cherry":{"type":"stdio","command":"/opt/homebrew/bin/cherry","args":["mcp"]}}}"#.utf8).write(to: fixture.code)
        #expect(await fixture.registry.registration(in: .claudeCode) == .registered(command: "/opt/homebrew/bin/cherry"))
        await #expect(throws: AutomationSetupError.managedByClient(.claudeCode)) { try await fixture.registry.register(Self.launch, in: .claudeCode) }
    }
}
