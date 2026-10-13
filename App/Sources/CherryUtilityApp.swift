import AppKit
import CherryFeatures
import ComposableArchitecture
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
        let updates = UpdateController()
        simulation = root.simulation
        // `@Shared(.appStorage)` keys resolve their UserDefaults when state is created, so point them at the
        // composition root's store before the first State exists.
        prepareDependencies { $0.defaultAppStorage = root.preferences }
        showsMainWindowAtLaunch = root.simulation != nil || (root.preferences.object(forKey: "showMainWindowAtLaunch") as? Bool ?? true)
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
            MenuBarLabel(store: store.scope(state: \.menuBar, action: \.menuBar))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 App 在启动时注入；退出前尽力写完诊断 journal。
    var flushDiagnostics: (@Sendable () async -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
