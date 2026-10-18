import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("设置与实验性功能")
struct SettingsFeatureTests {
    @Test func enablingCustomFirmwareRequiresAcknowledgement() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
        }

        await store.send(.customFirmwareToggled(true)) {
            $0.isConfirmingCustomFirmware = true
        }
        // Confirming without ticking the box does nothing.
        await store.send(.confirmCustomFirmwareTapped)
        #expect(store.state.customFirmwareEnabled == false)

        await store.send(.binding(.set(\.riskAcknowledged, true))) {
            $0.riskAcknowledged = true
        }
        await store.send(.confirmCustomFirmwareTapped) {
            $0.$customFirmwareEnabled.withLock { $0 = true }
            $0.isConfirmingCustomFirmware = false
        }

        // Turning it off needs no confirmation.
        await store.send(.customFirmwareToggled(false)) {
            $0.$customFirmwareEnabled.withLock { $0 = false }
        }
    }

    @Test func cancellingTheRiskSheetKeepsTheSectionHidden() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
        }
        await store.send(.customFirmwareToggled(true)) { $0.isConfirmingCustomFirmware = true }
        await store.send(.binding(.set(\.riskAcknowledged, true))) { $0.riskAcknowledged = true }
        await store.send(.cancelCustomFirmwareTapped) {
            $0.isConfirmingCustomFirmware = false
            $0.riskAcknowledged = false
        }
        #expect(store.state.customFirmwareEnabled == false)
    }

    @Test func turningOffAutomaticChecksAlsoTurnsOffAutomaticDownloads() async {
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.appUpdateClient = AppUpdateClient(
                snapshot: { AppUpdateSnapshot(isAvailable: true, automaticallyChecks: false, automaticallyDownloads: false, canCheckNow: true, lastCheck: nil, version: "1.0.0 (1)") },
                setAutomaticallyChecks: { value in calls.withValue { $0.append("checks=\(value)") } },
                setAutomaticallyDownloads: { value in calls.withValue { $0.append("downloads=\(value)") } },
                checkForUpdates: {}
            )
            $0.loginItemClient = LoginItemClient(isEnabled: { false }, setEnabled: { _ in })
        }
        store.exhaustivity = .off
        await store.send(.automaticallyChecksChanged(false))
        await store.finish()
        #expect(calls.value == ["checks=false", "downloads=false"])
        #expect(store.state.update.automaticallyDownloads == false)
    }

    @Test func loginItemFailureRestoresTheActualState() async {
        struct Denied: Error {}
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.loginItemClient = LoginItemClient(isEnabled: { false }, setEnabled: { _ in throw Denied() })
        }
        await store.send(.launchAtLoginChanged(true)) { $0.launchAtLogin = true }
        await store.receive(\.loginItemFailed) {
            $0.launchAtLogin = false
            $0.loginItemError = Denied().localizedDescription
        }
    }

    @Test func experimentalSectionVisibility() {
        withDependencies {
            $0.defaultAppStorage = Self.isolatedDefaults()
        } operation: {
            var state = KeyboardFeature.State(keyboard: .preview)
            state.section = .customFirmware
            #expect(!state.visibleSections.contains(.customFirmware))
            #expect(state.displayedSection == .info, "hidden section falls back to the overview")

            state.$customFirmwareEnabled.withLock { $0 = true }
            #expect(state.visibleSections.contains(.customFirmware))
            #expect(state.displayedSection == .customFirmware)
        }
    }

    @Test func menuBarLabelFollowsTheBatteryPreference() {
        withDependencies {
            $0.defaultAppStorage = Self.isolatedDefaults()
        } operation: {
            var state = MenuBarFeature.State()
            state.keyboards = [.preview]
            state.snapshot = .loaded(.preview)
            state.snapshotID = KeyboardSummary.preview.id
            #expect(state.labelText == "95%")
            state.$showsBatteryInLabel.withLock { $0 = false }
            #expect(state.labelText == nil)
            #expect(state.labelAccessibilityValue == "95%", "VoiceOver still hears the level")
        }
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suite = "online.odeployer.CherryUtility.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - 自动化

    nonisolated static let snapshot = AutomationEntriesSnapshot(
        enabled: [.commandLine: true, .mcp: true], activity: AutomationActivity(), endpoint: .listening(path: "/tmp/c.sock"),
        commandLineTool: .notInstalled, bundledTool: "/Applications/CherryUtility.app/Contents/MacOS/cherry",
        registrations: [.claudeDesktop: .notRegistered, .claudeCode: .clientNotInstalled],
        launch: MCPServerLaunch(command: "/Applications/CherryUtility.app/Contents/MacOS/cherry")
    )

    /// 打开设置时加载状态，并在窗口打开期间接收命令行与 MCP 的调用记录。
    @Test func automationStatusLoadsAndFollowsTheActivity() async {
        let (activity, continuation) = AsyncStream.makeStream(of: AutomationActivity.self)
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.appUpdateClient = AppUpdateClient(snapshot: { .unavailable }, setAutomaticallyChecks: { _ in }, setAutomaticallyDownloads: { _ in }, checkForUpdates: {})
            $0.loginItemClient = LoginItemClient(isEnabled: { false }, setEnabled: { _ in })
            $0.automationEntriesClient.snapshot = { Self.snapshot }
            $0.automationEntriesClient.activityUpdates = { activity }
        }
        store.exhaustivity = .off
        let task = await store.send(.task)
        await store.receive(\.automationLoaded) { $0.automation = Self.snapshot }
        let call = AutomationCall(entry: .mcp, operation: "status", succeeded: true, route: .direct, date: Date(timeIntervalSince1970: 0))
        let recorded = AutomationActivity().recording(call)
        continuation.yield(recorded)
        await store.receive(\.automationActivityChanged) { $0.automation?.activity = recorded }
        #expect(store.state.automation?.activityText(.mcp).contains("命令行直连 · 成功（共 1 次）") == true)
        continuation.finish()
        await task.cancel()
    }

    @Test func togglingAnEntryWritesThroughTheService() async {
        let written = LockIsolated<[(AutomationEntry, Bool)]>([])
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.automationEntriesClient.setEnabled = { entry, enabled in written.withValue { $0.append((entry, enabled)) } }
            $0.automationEntriesClient.snapshot = {
                var snapshot = Self.snapshot
                snapshot.enabled[.mcp] = false
                return snapshot
            }
        }
        await store.send(.automationLoaded(Self.snapshot)) { $0.automation = Self.snapshot }
        await store.send(.automationEntryToggled(.mcp, false)) { $0.automation?.enabled[.mcp] = false }
        await store.receive(\.automationLoaded)
        #expect(written.value.map(\.0) == [.mcp] && written.value.map(\.1) == [false])
    }

    /// 安装、注册的成功与失败都以提示显示；失败用 Core 错误的中文说明。
    @Test func setupActionsReportTheirOutcome() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.automationEntriesClient.installCommandLineTool = {}
            $0.automationEntriesClient.registerMCP = { _ in throw AutomationSetupError.unreadableConfiguration(path: "/x.json", reason: "不是有效的 JSON") }
            $0.automationEntriesClient.snapshot = { Self.snapshot }
        }
        await store.send(.installCommandLineToolTapped) { $0.isPerformingAutomationSetup = true }
        await store.receive(\.automationSetupFinished) {
            $0.isPerformingAutomationSetup = false
            $0.automationNotice = .init("已安装 cherry 命令，新开的终端窗口里可以直接使用")
        }
        await store.receive(\.automationLoaded) { $0.automation = Self.snapshot }
        await store.send(.registerMCPTapped(.claudeDesktop)) {
            $0.isPerformingAutomationSetup = true
            $0.automationNotice = nil
        }
        await store.receive(\.automationSetupFinished) {
            $0.isPerformingAutomationSetup = false
            $0.automationNotice = .init("无法读取 /x.json（不是有效的 JSON），没有修改", isError: true)
        }
        await store.receive(\.automationLoaded)
        await store.send(.automationCopied("注册命令")) { $0.automationNotice = .init("已复制注册命令") }
    }

    @Test func statusTextsDescribeEachState() {
        var snapshot = Self.snapshot
        #expect(snapshot.canInstallCommandLineTool && !snapshot.canUninstallCommandLineTool)
        snapshot.commandLineTool = .standalone(path: "/opt/homebrew/bin/cherry")
        #expect(snapshot.commandLineToolText == "已独立安装：/opt/homebrew/bin/cherry" && !snapshot.canInstallCommandLineTool)
        #expect(snapshot.registrationText(.claudeCode) == "没有找到 Claude Code" && !snapshot.canRegister(.claudeCode))
        #expect(snapshot.claudeCodeCommand == #"claude mcp add --scope user cherry -- "/Applications/CherryUtility.app/Contents/MacOS/cherry" mcp"#)
        #expect(snapshot.mcpConfigurationJSON?.contains(#""args" : ["#) == true)
        #expect(snapshot.endpointText == "正在监听 /tmp/c.sock")
        #expect(snapshot.activityText(.commandLine) == "还没有调用")
    }

}
