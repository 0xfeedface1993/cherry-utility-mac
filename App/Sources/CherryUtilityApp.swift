import AppKit
import CherryFeatures
import ComposableArchitecture
import SwiftUI

@main
struct CherryUtilityApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store: StoreOf<AppFeature>
    private let simulation: SimulationControls?

    init() {
        let root = CompositionRoot()
        let runtime = root.diagnosticRuntime
        AppDelegate.flushDiagnostics = { try? await runtime.flush() }
        simulation = root.simulation
        let store = Store(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            root.install(into: &$0)
        }
        // Device discovery and the status-item poll run for the app's lifetime, window or not.
        store.send(.task)
        simulation?.keyInput.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        Window("CHERRY Utility", id: Self.mainWindowID) {
            AppView(store: store)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 800)
        .windowToolbarStyle(.unified)
        .commands { SimulationCommands(controls: simulation) }
        .commands { DiagnosticsCommands() }

        Window("诊断与日志", id: "diagnostics") {
            DiagnosticsView(store: store.scope(state: \.diagnostics, action: \.diagnostics))
        }
        .defaultSize(width: 600, height: 560)

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
    static var flushDiagnostics: (@Sendable () async -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flush = Self.flushDiagnostics else { return .terminateNow }
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

/// Bridges the panel's buttons to SwiftUI window management, which only views can reach.
private struct MenuBarContent: View {
    let store: StoreOf<MenuBarFeature>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanel(
            store: store,
            onOpenMainWindow: {
                openWindow(id: CherryUtilityApp.mainWindowID)
                NSApp.activate()
            },
            onQuit: { NSApp.terminate(nil) },
            onOpenDiagnostics: { openWindow(id: "diagnostics"); NSApp.activate() }
        )
    }
}
