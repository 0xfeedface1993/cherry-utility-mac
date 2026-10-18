import AppKit
import CherryCore
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
@testable import CherryFeatures

/// Renders the real screens with fixture data into PNGs, for visual review against the Figma redesign and as the
/// website screenshots. Off by default; run with
///     CHERRY_RENDER_DIR=/abs/dir swift test --filter ScreenRender
/// Windows are never ordered on screen: the window frame (title bar + toolbar) is drawn with `cacheDisplay`.
@MainActor
@Suite("ScreenRender", .enabled(if: ProcessInfo.processInfo.environment["CHERRY_RENDER_DIR"] != nil), .serialized)
struct ScreenRenderTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHERRY_RENDER_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)

    init() {
        // The test runner has no bundle icon; use the app's so onboarding / settings show the real artwork.
        let icon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
        if let image = NSImage(contentsOf: icon) { NSApplication.shared.applicationIconImage = image }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func mainWindow(appearance: NSAppearance.Name) async throws {
        let suffix = appearance == .aqua ? "light" : "dark"
        for section in [KeyboardFeature.Section.info, .configuration, .keyTest, .firmware] {
            let store = makeStore(section: section)
            try await renderWindow(AppView(store: store), size: CGSize(width: 1120, height: 760), appearance: appearance, name: "main-\(section.fileName)-\(suffix)") {
                await prepare(store, section: section)
            }
        }
        let empty = Store(initialState: AppFeature.State()) { AppFeature() } withDependencies: { configure(&$0, keyboards: []) }
        try await renderWindow(AppView(store: empty), size: CGSize(width: 1120, height: 760), appearance: appearance, name: "main-onboarding-\(suffix)") {}
    }

    /// Other models (driver-derived capabilities): wired RGB board, no-backlight board, type-B PIXIU 98.
    @Test(arguments: [UInt16(0x0079), 0x0077, 0x01E6])
    func otherModels(productID: UInt16) async throws {
        let keyboard = MultiModelFeatureFixtures.keyboard(productID)
        let model = try #require(keyboard.model)
        let snapshot = model.hasBattery ? VendorSnapshot.preview : MultiModelFeatureFixtures.wiredSnapshot
        let release = model.catalogName.map {
            FirmwareRelease(
                name: $0 + "_0136", deviceIndex: 0, versionCode: "0136", versionName: "0.1.3.6",
                downloadURL: URL(string: "https://example.invalid/\($0)_0136.exe")!, md5: "00", isForced: false
            )
        }
        for section in [KeyboardFeature.Section.info, .configuration, .keyTest, .firmware] {
            var state = AppFeature.State()
            state.keyboards = [keyboard]
            var detail = KeyboardFeature.State(keyboard: keyboard)
            detail.section = section
            if section == .firmware { detail.firmware.latest = .loaded(release) }
            state.detail = detail
            let store = Store(initialState: state) { AppFeature() } withDependencies: {
                configure(&$0, keyboards: [keyboard])
                $0.keyboardClient.vendorSnapshot = { _ in snapshot }
                $0.firmwareClient.latestRelease = { _ in release }
            }
            let name = String(format: "model-%04X-\(section.fileName)", productID)
            try await renderWindow(AppView(store: store), size: CGSize(width: 1120, height: 760), appearance: .aqua, name: name) {}
        }
        let store = Store(initialState: { var s = AppFeature.State(); s.keyboards = [keyboard]; return s }()) { AppFeature() } withDependencies: {
            configure(&$0, keyboards: [keyboard])
            $0.keyboardClient.vendorSnapshot = { _ in snapshot }
        }
        store.send(.task)
        let panel = MenuBarPanel(store: store.scope(state: \.menuBar, action: \.menuBar), onOpenMainWindow: {}, onQuit: {})
        try await renderView(panel, appearance: .aqua, name: String(format: "model-%04X-menubar", productID))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func menuBarPanel(appearance: NSAppearance.Name) async throws {
        let store = makeStore(section: .info)
        store.send(.task)
        let view = MenuBarPanel(store: store.scope(state: \.menuBar, action: \.menuBar), onOpenMainWindow: {}, onQuit: {})
        try await renderView(view, appearance: appearance, name: "menubar-\(appearance == .aqua ? "light" : "dark")")
    }

    @Test func settings() async throws {
        for tab in SettingsFeature.Tab.allCases {
            var state = SettingsFeature.State()
            state.tab = tab
            let store = Store(initialState: state) { SettingsFeature() } withDependencies: { configure(&$0, keyboards: [.preview]) }
            try await renderWindow(SettingsView(store: store), size: CGSize(width: 560, height: tab == .automation ? 650 : tab == .updates ? 380 : 280), appearance: .aqua, name: "settings-\(tab.fileName)") {}
        }
    }

    // MARK: Fixtures

    private func makeStore(section: KeyboardFeature.Section) -> StoreOf<AppFeature> {
        var state = AppFeature.State()
        state.keyboards = [.preview]
        var detail = KeyboardFeature.State(keyboard: .preview)
        detail.section = section
        if section == .firmware {
            detail.firmware.latest = .loaded(Self.release)
            detail.firmware.package = .loaded(Self.package)
            detail.firmware.deviceFirmware = .loaded(DeviceFirmwareStatus(version: 0x0117, crc: 0xCFE1_A03E))
            detail.firmware.phase = .flashing(sent: 1231, total: 1920, percent: 64)
        }
        state.detail = detail
        return Store(initialState: state) { AppFeature() } withDependencies: { configure(&$0, keyboards: [.preview]) }
    }

    private func prepare(_ store: StoreOf<AppFeature>, section: KeyboardFeature.Section) async {
        switch section {
        case .configuration:
            // Pending edits show the floating save bar.
            store.send(.detail(.configuration(.edit(.brightness(3)))))
            store.send(.detail(.configuration(.edit(.color(LEDColor(r: 0x00, g: 0x99, b: 0xFF))))))
            store.send(.detail(.configuration(.edit(.randomColor(false)))))
        case .keyTest:
            let tested: [UInt16] = [0x29, 0x3A, 0x3B, 0x3C, 0x3D, 0x35, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                                    0x2B, 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x39, 0x04, 0x16, 0x07, 0x09,
                                    0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0xE1, 0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0xE0, 0xE3, 0xE2, 0x2C]
            var t: UInt64 = 1_000_000_000
            for usage in tested {
                store.send(.detail(.keyTest(.keyEvent(KeyEvent(usage: .keyboard(usage), isDown: true, timestamp: t)))))
                t += 38_000_000
                store.send(.detail(.keyTest(.keyEvent(KeyEvent(usage: .keyboard(usage), isDown: false, timestamp: t)))))
                t += 52_000_000
            }
            store.send(.detail(.keyTest(.keyEvent(KeyEvent(usage: .keyboard(0x1A), isDown: true, timestamp: t)))))
            store.send(.detail(.keyTest(.keyEvent(KeyEvent(usage: .keyboard(0x07), isDown: true, timestamp: t + 41_300_000)))))
        default:
            break
        }
    }

    private func configure(_ d: inout DependencyValues, keyboards: [KeyboardSummary]) {
        d.context = .preview
        d.defaultAppStorage = Self.preferences
        d.keyboardClient = KeyboardClient(
            keyboards: { keyboards },
            updates: { AsyncStream { $0.yield(keyboards) } },
            vendorSnapshot: { _ in .preview },
            battery: { _ in try #require(VendorSnapshot.preview.battery) },
            firmwareStatus: { _ in DeviceFirmwareStatus(version: 0x0117, crc: 0xCFE1_A03E) }
        )
        d.firmwareClient = FirmwareClient(
            latestRelease: { _ in Self.release },
            download: { _ in Self.package },
            loadLocal: { _ in Self.package },
            deviceFirmware: { _, _ in DeviceFirmwareStatus(version: 0x0117, crc: 0xCFE1_A03E) },
            flash: { _, _, _ in .confirmed },
            verifyAfterFlash: { _, _ in DeviceFirmwareStatus(version: 0x0118, crc: 0x5B0D_72E4) }
        )
    }

    nonisolated(unsafe) static let preferences = UserDefaults(suiteName: "online.odeployer.CherryUtility.render")!

    nonisolated static let release = FirmwareRelease(
        name: "MX_PIXIU75_WIRELESS_0118", deviceIndex: 51, versionCode: "0118", versionName: "0.1.1.8",
        downloadURL: URL(string: "https://example.invalid/MX_PIXIU75_WIRELESS_0118.exe")!, md5: "9F0C2E7B5D1A4C88B2E6F1A3D4C5B6A7", isForced: false
    )

    nonisolated static let package: FirmwarePackage = {
        var param = [UInt8](repeating: 0xFF, count: 128)
        param.replaceSubrange(64..<74, with: Array("046A01E205".utf8))
        param.replaceSubrange(80..<84, with: Array("FFEF".utf8))
        let size = 131_072
        var code = [UInt8](repeating: 0, count: 256 + size)
        code.replaceSubrange(48..<52, with: [0, 2, 0, 0])
        code.replaceSubrange(256 + size - 4..<256 + size, with: [0xE4, 0x72, 0x0D, 0x5B])
        let image = try! UpdaterImage(param: param, code: code)
        return FirmwarePackage(source: .catalog(release), fileMD5: "9F0C2E7B5D1A4C88B2E6F1A3D4C5B6A7", image: image)
    }()

    // MARK: Rendering

    private func renderWindow<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, name: String, after: () async -> Void) async throws {
        let controller = NSHostingController(rootView: view
            .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
            .environment(\.controlActiveState, .key))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        // Lists (NSTableView) only create rows for a visible window: show it far outside every screen.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        await settle(0.8)
        await after()
        await settle(1.2)
        let frame = try #require(window.contentView?.superview)
        if let image = Self.windowServerImage(of: window) {
            // The window server composites the Liquid Glass sidebar, which view-level drawing cannot reproduce.
            try writePNG(NSBitmapImageRep(cgImage: image), name: name)
        } else {
            try write(frame, name: name)
        }
        window.close()
    }

    private func renderView<V: View>(_ view: V, appearance: NSAppearance.Name, name: String) async throws {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
            .environment(\.controlActiveState, .key))
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        await settle(1.0)
        host.setFrameSize(host.fittingSize)
        await settle(0.6)
        try write(host, name: name)
        window.close()
    }

    private func settle(_ seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pumpRunLoop()
            await Task.yield()
        }
    }

    private func dumpTables(_ view: NSView, depth: Int = 0) {
        let name = String(describing: type(of: view))
        if depth < 14 { print("VIEW " + String(repeating: " ", count: depth) + name + " \(view.frame.integral) hidden=\(view.isHidden) layer=\(view.layer.map { String(describing: type(of: $0)) } ?? "-")") }
        if depth < 40 { view.subviews.forEach { dumpTables($0, depth: depth + 1) } }
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is unavailable to Swift on macOS 15+, but still captures the caller's own windows
    /// (no Screen Recording permission involved). Looked up dynamically; nil when the symbol is gone.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: WindowImageFunction.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3; kCGWindowImageBoundsIgnoreFraming = 1 << 0, BestResolution = 1 << 3.
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    private func writePNG(_ rep: NSBitmapImageRep, name: String) throws {
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appending(path: "\(name).png"))
    }

    /// Lets AppKit / SwiftUI commit layout and drawing between effect deliveries.
    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func write(_ view: NSView, name: String) throws {
        let bounds = view.bounds
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appending(path: "\(name).png"))
    }
}

private extension KeyboardFeature.Section {
    var fileName: String {
        switch self {
        case .info: "overview"
        case .configuration: "lighting"
        case .keyTest: "keytest"
        case .firmware: "firmware"
        case .customFirmware: "custom"
        }
    }
}

private extension SettingsFeature.Tab {
    var fileName: String {
        switch self {
        case .general: "general"
        case .updates: "updates"
        case .automation: "automation"
        case .labs: "labs"
        }
    }
}
