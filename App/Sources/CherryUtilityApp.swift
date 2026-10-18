import AppIntents
import AppKit
import CherryControl
import CherryFeatures
import ComposableArchitecture
import OSLog
import SwiftUI

@main
struct CherryUtilityApp: App {
    static let mainWindowID = "main"
    static let diagnosticsWindowID = "diagnostics"

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store: StoreOf<AppFeature>
    @State private var updates: UpdateController
    private let simulation: SimulationControls?
    private let showsMainWindowAtLaunch: Bool

    init() {
        // 不恢复上次的窗口：恢复数据与签名身份绑定，ad-hoc 构建（README 的默认方式）读不出任何窗口，
        // 系统却仍报告“有状态可恢复”，SwiftUI 因此不打开主窗口。启动时总是按设置决定是否打开主窗口。
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        let root = CompositionRoot()
        let runtime = root.diagnosticRuntime
        // 系统可能为了执行快捷指令 / Spotlight 意图而启动 App；意图执行前 App.init 一定已经完成，这里注册即可。
        let automation = root.automation
        AppDependencyManager.shared.add(dependency: automation)
        root.startControlServer()
        if root.simulation == nil {
            CherryShortcuts.updateAppShortcutParameters()
        } else {
            #if DEBUG
            AutomationCatalogCheck.verify()
            #endif
        }
        let updates = UpdateController()
        simulation = root.simulation
        // `@Shared(.appStorage)` keys resolve their UserDefaults when state is created, so point them at the
        // composition root's store before the first State exists.
        prepareDependencies { $0.defaultAppStorage = root.preferences }
        // 命令行在后台启动 App（`open --args --background`）时不显示主窗口。
        let launchedInBackground = CommandLine.arguments.contains(ControlProtocol.backgroundLaunchArgument)
        showsMainWindowAtLaunch = !launchedInBackground
            && (root.simulation != nil || (root.preferences.object(forKey: "showMainWindowAtLaunch") as? Bool ?? true))
        let store = Store(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            root.install(into: &$0, updates: updates)
        }
        // Device discovery and the status-item poll run for the app's lifetime, window or not.
        store.send(.task)
        simulation?.keyInput.start()
        _store = State(initialValue: store)
        _updates = State(initialValue: updates)
        // init 中取到的就是 SwiftUI 之后回调的 delegate 实例（2026-10-11 用最小程序验证过）。
        appDelegate.flushDiagnostics = { try? await runtime.flush() }
        appDelegate.stopControlServer = root.stopControlServer
        appDelegate.installTerminationSignalHandler()
    }

    var body: some Scene {
        Window("CHERRY Utility", id: Self.mainWindowID) {
            MainWindowContent(store: store)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 800)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(showsMainWindowAtLaunch ? .presented : .suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
        .commands { SimulationCommands(controls: simulation) }
        .commands { DiagnosticsCommands() }

        Window("诊断与日志", id: Self.diagnosticsWindowID) {
            DiagnosticsView(store: store.scope(state: \.diagnostics, action: \.diagnostics))
        }
        .defaultSize(width: 600, height: 560)

        Settings {
            SettingsView(store: store.scope(state: \.settings, action: \.settings))
        }

        MenuBarExtra {
            MenuBarContent(store: store.scope(state: \.menuBar, action: \.menuBar))
        } label: {
            MenuBarLabelContent(store: store.scope(state: \.menuBar, action: \.menuBar), appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 App 在启动时注入；退出前尽力写完诊断 journal。
    var flushDiagnostics: (@Sendable () async -> Void)?
    /// 由 App 在启动时注入；退出时关闭命令行 socket。
    var stopControlServer: (@Sendable () -> Void)?
    private var terminationTask: Task<Void, Never>?
    nonisolated private static let launchLog = Logger(subsystem: "online.odeployer.CherryUtility", category: "launch")
    private var launchEvent = "none"
    private var terminationSignal: (any DispatchSourceSignal)?

    // 启动探针：记录是谁启动了 App（Finder / 登录项 / 为执行意图被系统拉起），用于判断能否在后台启动时不弹主窗口。
    // 只记录 Apple Event 编号和两个布尔值，不含用户数据。
    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchEvent = Self.fourCharacterCode(event.eventClass) + "/" + Self.fourCharacterCode(event.eventID)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefault = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool).map(String.init) ?? "nil"
        let isActive = NSApp.isActive
        let event = launchEvent
        // notice：info 级别不落盘，`log show` 事后读不到。
        Self.launchLog.notice("launch event=\(event, privacy: .public) isDefaultLaunch=\(isDefault, privacy: .public) isActive=\(isActive, privacy: .public)")
        installTerminationSignalHandler()
    }

    /// `kill` 或 launchd 发 SIGTERM 时，走与 ⌘Q 相同的退出流程：删除命令行 socket、写完诊断 journal。
    /// 默认处理会直接结束进程，留下残留的 socket 文件。
    func installTerminationSignalHandler() {
        // App.init 时就装上，启动中途收到也走正常退出；完成启动时再设一次 SIG_IGN，以防期间被改回默认处理。信号源只建一次。
        signal(SIGTERM, SIG_IGN)
        guard terminationSignal == nil else { return }
        terminationSignal = Self.makeTerminationSignalSource()
    }

    /// 信号在后台队列接收，再交给主 run loop 执行 `terminate:`：
    /// - `terminate:` 会进入嵌套 run loop，等 `applicationShouldTerminate` 里的 MainActor 任务回复；在主队列的 block 里
    ///   调用它，主队列一直被占着，那个任务排不上，进程就卡死；
    /// - 闭包必须不带 MainActor 隔离（所以放在 nonisolated 的静态函数里），否则在后台队列执行时运行时隔离检查直接崩溃。
    nonisolated private static func makeTerminationSignalSource() -> any DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            launchLog.notice("SIGTERM received, terminating")
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        source.resume()
        return source
    }

    private static func fourCharacterCode(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .macOSRoman) ?? String(code)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopControlServer?()
        stopControlServer = nil
        guard let flush = flushDiagnostics else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task { @MainActor in
                await flush() // writer 等待有 2 秒上限，不能无限阻止退出。
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    /// Closing the window keeps the status item (battery, quick lighting) alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 由菜单栏图标的视图注入：它从启动起一直存在，能拿到 SwiftUI 的 `openWindow`。
    var openMainWindow: (@MainActor () -> Void)?

    /// 点程序坞图标（或对运行中的 App 再 `open` 一次）时，没有能当主窗口的窗口就打开主窗口。启动时跳过了主窗口
    /// （`--background`，或关掉「启动时显示主窗口」）时 SwiftUI 不会自己打开它。菜单栏的图标和面板不算主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let hasMainCapableWindow = sender.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }
        guard !hasMainCapableWindow, let openMainWindow else { return true }
        openMainWindow()
        return false
    }
}

/// 菜单栏图标；顺带把打开主窗口的方式交给 AppDelegate，供点程序坞图标时使用。
private struct MenuBarLabelContent: View {
    let store: StoreOf<MenuBarFeature>
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(store: store)
            .onAppear {
                let openWindow = openWindow
                appDelegate.openMainWindow = { openWindow(id: CherryUtilityApp.mainWindowID) }
            }
    }
}

/// Main window content; bridges the sidebar's diagnostics button to SwiftUI window management.
private struct MainWindowContent: View {
    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AppView(store: store, onOpenDiagnostics: { openWindow(id: CherryUtilityApp.diagnosticsWindowID) })
    }
}

/// Bridges the panel's buttons to SwiftUI window management, which only views can reach.
private struct MenuBarContent: View {
    let store: StoreOf<MenuBarFeature>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarPanel(
            store: store,
            onOpenMainWindow: {
                openWindow(id: CherryUtilityApp.mainWindowID)
                NSApp.activate()
            },
            onQuit: { NSApp.terminate(nil) },
            onOpenDiagnostics: { openWindow(id: CherryUtilityApp.diagnosticsWindowID); NSApp.activate() },
            onOpenSettings: { openSettings(); NSApp.activate() }
        )
    }
}
