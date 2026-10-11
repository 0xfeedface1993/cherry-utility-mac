import XCTest

@MainActor
final class DiagnosticsUITests: CherryUITestCase {
    /// 打开共享窗口、生成包、取消真实保存面板，再保存到本次独立目录。
    func testExportAndSaveDiagnosticPackage() throws {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-diagnostic-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["CHERRY_SIMULATION"] = "pixiu75"
        app.launchEnvironment["CHERRY_DIAGNOSTIC_MODE"] = "standard"
        app.launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 15))
        app.typeKey("d", modifierFlags: [.command, .shift])
        let export = app.buttons["diagnostics.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 8), app.debugDescription)
        export.click()
        let save = app.buttons["diagnostics.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "diagnostic-preview"; attachment.lifetime = .keepAlways; add(attachment)
        save.click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        let cancel = panel.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.click()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let go = panel.sheets.firstMatch.textFields.firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 3)); go.typeText(directory.path); app.typeKey(.return, modifierFlags: [])
        let saveButton = panel.buttons["OKButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3)); saveButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.saved"].waitForExistence(timeout: 8))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(files.first { $0.pathExtension == "zip" })
        XCTAssertGreaterThan(try Data(contentsOf: archive).count, 100)
    }
}
