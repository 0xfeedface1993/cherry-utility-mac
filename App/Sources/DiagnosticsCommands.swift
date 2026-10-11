import SwiftUI

struct DiagnosticsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("诊断与日志…") { openWindow(id: "diagnostics"); NSApp.activate() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
