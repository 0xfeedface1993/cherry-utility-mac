import AppKit
import CherryCore
import ComposableArchitecture
import SwiftUI

public struct SettingsView: View {
    @Bindable var store: StoreOf<SettingsFeature>

    public init(store: StoreOf<SettingsFeature>) {
        self.store = store
    }

    public var body: some View {
        TabView(selection: $store.tab) {
            GeneralSettings(store: store)
                .tabItem { Label(SettingsFeature.Tab.general.rawValue, systemImage: "gearshape") }
                .tag(SettingsFeature.Tab.general)
            UpdateSettings(store: store)
                .tabItem { Label(SettingsFeature.Tab.updates.rawValue, systemImage: "arrow.down.circle") }
                .tag(SettingsFeature.Tab.updates)
            AutomationSettings(store: store)
                .tabItem { Label(SettingsFeature.Tab.automation.rawValue, systemImage: "terminal") }
                .tag(SettingsFeature.Tab.automation)
            LabsSettings(store: store)
                .tabItem { Label(SettingsFeature.Tab.labs.rawValue, systemImage: "flask") }
                .tag(SettingsFeature.Tab.labs)
        }
        .frame(width: 560)
        .tint(Theme.accent)
        .task { await store.send(.task).finish() }
        .sheet(isPresented: $store.isConfirmingCustomFirmware) {
            CustomFirmwareRiskSheet(store: store)
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section {
                Toggle("登录时打开", isOn: Binding(get: { store.launchAtLogin }, set: { store.send(.launchAtLoginChanged($0)) }))
                    .accessibilityIdentifier("settings.launchAtLogin")
                if let error = store.loginItemError {
                    Text(error).font(.caption).foregroundStyle(Theme.warning)
                }
                Toggle(isOn: Binding(get: { store.showMainWindowAtLaunch }, set: { value in store.$showMainWindowAtLaunch.withLock { $0 = value } })) {
                    Text("启动时显示主窗口")
                    Text("关闭后只在菜单栏运行")
                }
                .accessibilityIdentifier("settings.showMainWindow")
                Toggle("菜单栏显示电量百分比", isOn: Binding(get: { store.showBatteryInMenuBar }, set: { value in store.$showBatteryInMenuBar.withLock { $0 = value } }))
                    .accessibilityIdentifier("settings.showBattery")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 230)
    }
}

private struct UpdateSettings: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CHERRY Utility \(store.update.version)").font(.headline)
                            .accessibilityIdentifier("settings.version")
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即检查") { store.send(.checkForUpdatesTapped) }
                        .disabled(!store.update.canCheckNow)
                        .accessibilityIdentifier("settings.checkNow")
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle(isOn: Binding(get: { store.update.automaticallyChecks }, set: { store.send(.automaticallyChecksChanged($0)) })) {
                    Text("自动检查更新")
                    Text("每天在后台检查一次")
                }
                .accessibilityIdentifier("settings.autoCheck")
                Toggle(isOn: Binding(get: { store.update.automaticallyDownloads }, set: { store.send(.automaticallyDownloadsChanged($0)) })) {
                    Text("自动下载并安装")
                    Text("下次退出时安装；更新包经过签名校验")
                }
                .disabled(!store.update.automaticallyChecks)
                .accessibilityIdentifier("settings.autoDownload")
            }
            .disabled(!store.update.isAvailable)
            Section {
                Label("更新来自 odeployer.online/cherry-utility，使用 EdDSA 签名并经过 Apple 公证。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("查看更新日志", destination: URL(string: "https://odeployer.online/cherry-utility/#changelog")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 330)
    }

    private var statusLine: String {
        guard store.update.isAvailable else { return "此版本未启用应用内更新" }
        guard let last = store.update.lastCheck else { return "尚未检查更新" }
        return "上次检查：" + last.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 命令行、MCP 与快捷指令三个自动化入口：开关、状态与安装 / 注册。
private struct AutomationSettings: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let snapshot = store.automation {
                commandLine(snapshot)
                mcp(snapshot)
            }
            Section("快捷指令与 Spotlight") {
                Text("10 个动作在快捷指令编辑器右侧的「App › CHERRY Utility」里（App 要装在「应用程序」文件夹里才会出现），用中文搜索「键盘」「配置档」「灯效」也能找到；Spotlight 里可以直接输入「切换配置档」等短语运行。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开快捷指令") { openURL(URL(string: "shortcuts://")!) }
                    .accessibilityIdentifier("settings.automation.openShortcuts")
            }
            if let notice = store.automationNotice {
                Section {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(notice.isError ? Theme.warning : .secondary)
                        .accessibilityIdentifier("settings.automation.notice")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }

    @ViewBuilder
    private func commandLine(_ snapshot: AutomationEntriesSnapshot) -> some View {
        Section("命令行 cherry") {
            Toggle(isOn: enabled(.commandLine, snapshot)) {
                Text("允许命令行控制")
                Text("终端和脚本里的 cherry 命令。CHERRY Utility 没在运行时，cherry 直接连接键盘，需要在「隐私与安全性 › 输入监控」里允许终端")
            }
            .accessibilityIdentifier("settings.automation.commandLine")
            HStack(alignment: .firstTextBaseline) {
                Text("cherry 命令")
                Spacer()
                Text(snapshot.commandLineToolText)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.automation.commandLine.tool")
            }
            HStack {
                Button("安装到 /usr/local/bin…") { store.send(.installCommandLineToolTapped) }
                    .disabled(!snapshot.canInstallCommandLineTool || store.isPerformingAutomationSetup)
                    .accessibilityIdentifier("settings.automation.commandLine.install")
                Button("移除") { store.send(.uninstallCommandLineToolTapped) }
                    .disabled(!snapshot.canUninstallCommandLineTool || store.isPerformingAutomationSetup)
                    .accessibilityIdentifier("settings.automation.commandLine.uninstall")
            }
            Text(snapshot.activityText(.commandLine))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.automation.commandLine.activity")
            Text(snapshot.endpointText)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.automation.endpoint")
        }
    }

    @ViewBuilder
    private func mcp(_ snapshot: AutomationEntriesSnapshot) -> some View {
        Section("MCP（Claude 等 AI 客户端）") {
            Toggle(isOn: enabled(.mcp, snapshot)) {
                Text("允许 MCP 控制")
                Text("AI 客户端通过 cherry mcp 读取和设置键盘")
            }
            .accessibilityIdentifier("settings.automation.mcp")
            Text(snapshot.activityText(.mcp))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.automation.mcp.activity")
            HStack {
                Text("Claude Desktop")
                Spacer()
                Text(snapshot.registrationText(.claudeDesktop))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.automation.claudeDesktop")
                Button("添加") { store.send(.registerMCPTapped(.claudeDesktop)) }
                    .disabled(!snapshot.canRegister(.claudeDesktop) || store.isPerformingAutomationSetup)
                    .accessibilityIdentifier("settings.automation.claudeDesktop.add")
            }
            HStack {
                Text("Claude Code")
                Spacer()
                Text(snapshot.registrationText(.claudeCode))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.automation.claudeCode")
                Button("复制注册命令") { copy(snapshot.claudeCodeCommand, as: "注册命令") }
                    .disabled(snapshot.claudeCodeCommand == nil)
                    .accessibilityIdentifier("settings.automation.claudeCode.copy")
            }
            Button("复制 JSON 配置（其他 MCP 客户端）") { copy(snapshot.mcpConfigurationJSON, as: "JSON 配置") }
                .disabled(snapshot.mcpConfigurationJSON == nil)
                .accessibilityIdentifier("settings.automation.mcp.copyJSON")
        }
    }

    private func enabled(_ entry: AutomationEntry, _ snapshot: AutomationEntriesSnapshot) -> Binding<Bool> {
        Binding(get: { snapshot.enabled[entry] ?? true }, set: { store.send(.automationEntryToggled(entry, $0)) })
    }

    private func copy(_ text: String?, as what: String) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.send(.automationCopied(what))
    }
}

private struct LabsSettings: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section {
                Note(tone: .warning) {
                    Text("实验性功能尚未经过广泛验证，可能让键盘行为与预期不同。仅在你清楚自己在做什么时开启。")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                Toggle(isOn: Binding(get: { store.customFirmwareEnabled }, set: { store.send(.customFirmwareToggled($0)) })) {
                    Text("自定义固件")
                    Text("在已知的原厂固件上选择要修改的功能，生成补丁镜像并写入键盘。随时可以恢复原厂固件。")
                }
                .accessibilityIdentifier("settings.customFirmware")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 230)
    }
}

private struct CustomFirmwareRiskSheet: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(systemImage: "exclamationmark.shield", tint: Theme.warning, background: Theme.warningSubtle, size: 44)
            Text("开启自定义固件？").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                bullet("写入修改过的固件可能导致部分按键、灯光或 Fn 组合键行为异常。")
                bullet("写入过程中断开连接，可能需要重新刷写原厂固件。")
                bullet("本工具是非官方软件，与 CHERRY 无关联，由此造成的问题需自行承担。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Toggle("我已了解风险，并知道如何「恢复原厂固件」。", isOn: $store.riskAcknowledged)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("settings.customFirmware.acknowledge")
            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.send(.cancelCustomFirmwareTapped) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.customFirmware.cancel")
                Button("开启") { store.send(.confirmCustomFirmwareTapped) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.riskAcknowledged)
                    .accessibilityIdentifier("settings.customFirmware.confirm")
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Settings") {
    SettingsView(store: Store(initialState: SettingsFeature.State()) {
        SettingsFeature()
    } withDependencies: {
        $0.appUpdateClient = .previewValue
        $0.loginItemClient = .previewValue
        $0.automationEntriesClient = .previewValue
    })
}
