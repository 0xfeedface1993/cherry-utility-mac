import AppKit
import CherryAdapters
import CherryCore
import CherryFeatures
import ComposableArchitecture
import Foundation
import UniformTypeIdentifiers

enum DiagnosticsComposition {
    static func make(support: URL, environment: [String: String]) -> DiagnosticsRuntime {
        let simulated = environment["CHERRY_SIMULATION"] != nil
        let directory: URL
        if simulated {
            directory = environment["CHERRY_DIAGNOSTIC_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("CherryUtility-Diagnostics-\(UUID().uuidString)")
        } else { directory = support.appendingPathComponent("Diagnostics", isDirectory: true) }
        let mode = environment["CHERRY_DIAGNOSTIC_MODE"].flatMap(DiagnosticMode.init(rawValue:)) ?? (simulated ? .off : .standard)
        return DiagnosticsRuntime(directory: directory, environment: .init(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1", simulated: simulated), mode: mode)
    }

    static func install(_ runtime: DiagnosticsRuntime, into dependencies: inout DependencyValues) {
        dependencies.diagnostics = runtime.port
        dependencies.diagnosticsClient = DiagnosticsClient(
            status: { runtime.status }, setMode: { runtime.setMode($0) }, export: { try await runtime.export(range: $0) },
            save: { export in
                guard let destination = await DiagnosticSavePanel.destination(for: export) else { return false }
                try Task.checkCancellation()
                try await runtime.exporter.save(export, to: destination)
                return true
            }, discard: { runtime.discard($0) })
    }
}

@MainActor
private enum DiagnosticSavePanel {
    static func destination(for export: DiagnosticExport) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存诊断包"
        panel.nameFieldStringValue = "CHERRY-诊断-\(Date().formatted(.iso8601.year().month().day())).cherrydiag.zip"
        panel.allowedContentTypes = [.zip]
        // 将取消转到主线程关闭属于本次请求的 panel，结束 continuation。
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "diagnostics" }) ?? NSApp.keyWindow {
                    panel.beginSheetModal(for: window, completionHandler: completion)
                } else { panel.begin(completionHandler: completion) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }
}
