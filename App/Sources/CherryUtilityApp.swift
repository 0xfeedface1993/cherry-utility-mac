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

        MenuBarExtra {
            MenuBarContent(store: store.scope(state: \.menuBar, action: \.menuBar))
        } label: {
            MenuBarLabel(store: store.scope(state: \.menuBar, action: \.menuBar))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
            onQuit: { NSApp.terminate(nil) }
        )
    }
}
