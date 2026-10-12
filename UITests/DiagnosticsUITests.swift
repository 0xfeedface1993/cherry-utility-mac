import XCTest

@MainActor
final class DiagnosticsUITests: CherryUITestCase {
    /// 打开共享窗口、生成包、取消真实保存面板，再保存到本次独立目录。
    func testExportAndSaveDiagnosticPackage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-diagnostic-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["CHERRY_SIMULATION"] = "pixiu75"
        app.launchEnvironment["CHERRY_DIAGNOSTIC_MODE"] = "standard"
        app.launchEnvironment["CHERRY_DIAGNOSTIC_SAVE_DIR"] = directory.path
        // journal 和临时导出包也放在本次目录：共享的 $TMPDIR 会被其他程序清理，包可能在「存储」前消失。
        app.launchEnvironment["CHERRY_DIAGNOSTIC_DIR"] = directory.appendingPathComponent("journal", isDirectory: true).path
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
        // 面板直接打开本次目录（CHERRY_DIAGNOSTIC_SAVE_DIR），不在系统面板里输入路径：
        // 「前往文件夹」里按回车时，系统面板进程偶尔在中文输入法的文本处理中崩溃，整个面板随之消失。
        let saveButton = panel.buttons["OKButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: saveButton)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 5), .completed, "存储按钮不可用")
        XCTAssertEqual(panel.popUpButtons["where popup"].value as? String, directory.lastPathComponent)
        saveButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.saved"].waitForExistence(timeout: 8))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(files.first { $0.pathExtension == "zip" })
        XCTAssertGreaterThan(try Data(contentsOf: archive).count, 100)
    }
}
