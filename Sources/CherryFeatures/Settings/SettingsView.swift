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
    })
}
