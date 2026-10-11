import CherryFeatures
import ComposableArchitecture
import SwiftUI

@main
struct CherryUtilityApp: App {
    @State private var store: StoreOf<AppFeature>

    init() {
        let root = CompositionRoot()
        _store = State(initialValue: Store(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            root.install(into: &$0)
        })
    }

    var body: some Scene {
        WindowGroup("CHERRY Utility") {
            AppView(store: store)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 800)
        .windowToolbarStyle(.unified)
    }
}
