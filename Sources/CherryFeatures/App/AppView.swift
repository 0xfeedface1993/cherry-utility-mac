import CherryCore
import ComposableArchitecture
import SwiftUI

public struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Opens the diagnostics window; the app supplies it because only scenes know their window IDs.
    let onOpenDiagnostics: @MainActor () -> Void

    public init(store: StoreOf<AppFeature>, onOpenDiagnostics: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onOpenDiagnostics = onOpenDiagnostics
    }

    public var body: some View {
        NavigationSplitView {
            Sidebar(store: store, onOpenDiagnostics: onOpenDiagnostics)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            if let detailStore = store.scope(state: \.detail, action: \.detail) {
                KeyboardView(store: detailStore)
            } else {
                OnboardingView()
            }
        }
        .tint(Theme.accent)
        .task { await store.send(.task).finish() }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var store: StoreOf<AppFeature>
    let onOpenDiagnostics: @MainActor () -> Void

    var body: some View {
        List(selection: selection) {
            Section("设备") {
                ForEach(sections) { section in
                    Label {
                        HStack {
                            Text(section.rawValue)
                            if section.isExperimental {
                                Spacer()
                                Badge("实验", tone: .warning)
                            }
                        }
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .tag(section)
                    .accessibilityIdentifier("section.\(section.rawValue)")
                }
            }
            .disabled(store.detail == nil)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            DeviceCard(store: store)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Divider().padding(.bottom, 6)
                Button(action: onOpenDiagnostics) {
                    Label("诊断与日志", systemImage: "stethoscope").frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("sidebar.diagnostics")
                SettingsLink {
                    Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("sidebar.settings")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    private var sections: [KeyboardFeature.Section] {
        store.detail?.visibleSections ?? KeyboardFeature.Section.allCases.filter { !$0.isExperimental }
    }

    private var selection: Binding<KeyboardFeature.Section?> {
        Binding(
            get: { store.detail?.displayedSection },
            set: { section in
                guard let section, store.detail != nil else { return }
                store.send(.detail(.binding(.set(\.section, section))))
            }
        )
    }
}

/// Top of the sidebar: the selected keyboard, its connection and battery. With several keyboards it becomes a menu.
struct DeviceCard: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        if let detail = store.detail {
            let connected = detail.isConnected
            let content = card(
                title: detail.keyboard.displayName,
                subtitle: connected ? "\(detail.keyboard.transportDescription) · 固件 \(detail.keyboard.firmwareVersion.description)" : "已断开 · 显示上次读取的信息",
                status: connected ? .success : .warning,
                showsChevron: store.keyboards.count > 1
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(connected ? "sidebar.keyboard" : "sidebar.disconnectedKeyboard")
            if store.keyboards.count > 1 {
                Menu {
                    ForEach(store.keyboards) { keyboard in
                        Button {
                            store.send(.selectKeyboard(keyboard.id))
                        } label: {
                            if keyboard.id == detail.keyboard.id {
                                Label(keyboard.selectionLabel, systemImage: "checkmark")
                            } else {
                                Text(keyboard.selectionLabel)
                            }
                        }
                    }
                } label: {
                    content
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(detail.isBusy)
                .accessibilityIdentifier("sidebar.devicePicker")
            } else {
                content
            }
        } else {
            card(title: "未连接键盘", subtitle: "等待 USB 连接", status: .neutral, showsChevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sidebar.empty")
        }
    }

    private enum Status { case success, warning, neutral }

    private func card(title: String, subtitle: String, status: Status, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            KeycapGlyph(filled: status != .neutral)
                .foregroundStyle(status == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .frame(width: 22, height: 22)
                .frame(width: 36, height: 36)
                .background(status == .neutral ? AnyShapeStyle(Theme.control) : AnyShapeStyle(Theme.brandGradient),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(color(status)).frame(width: 6, height: 6)
                    Text(subtitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }

    private func color(_ status: Status) -> Color {
        switch status {
        case .success: Theme.success
        case .warning: Theme.warning
        case .neutral: Theme.tertiaryText
        }
    }
}

// MARK: - Detail

struct KeyboardView: View {
    @Bindable var store: StoreOf<KeyboardFeature>

    var body: some View {
        VStack(spacing: 0) {
            if !store.isConnected {
                Label(store.firmware.isBusy || store.customFirmware.isBusy ? "设备正在重启…" : "设备已断开，显示上次读取信息；重新连接后自动刷新", systemImage: "cable.connector.slash")
                    .font(.callout)
                    .accessibilityIdentifier("detail.disconnected")
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Theme.warningSubtle)
            }
            switch store.displayedSection {
            case .info:
                DeviceInfoView(store: store.scope(state: \.info, action: \.info))
            case .configuration:
                ConfigurationView(store: store.scope(state: \.configuration, action: \.configuration))
            case .keyTest:
                KeyTestView(store: store.scope(state: \.keyTest, action: \.keyTest))
            case .firmware:
                FirmwareView(store: store.scope(state: \.firmware, action: \.firmware))
            case .customFirmware:
                CustomFirmwareView(store: store.scope(state: \.customFirmware, action: \.customFirmware))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
        .navigationTitle(store.displayedSection.rawValue)
        .navigationSubtitle(store.keyboard.displayName)
    }
}

/// Shown when no keyboard is attached.
struct OnboardingView: View {
    private let steps: [(String, String, String)] = [
        ("cable.connector", "用 USB 线连接键盘", "读取配置、写入灯效和升级固件都走有线接口。"),
        ("antenna.radiowaves.left.and.right", "无线模式也能显示", "2.4G / 蓝牙下只读取接收器的基础信息。"),
        ("hand.raised.fill", "按键测试需要授权", "首次使用时按提示打开「输入监控」权限。"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: Color(hex: 0x8A0D2E).opacity(0.25), radius: 12, y: 8)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("连接你的 CHERRY 键盘").font(.title.weight(.bold))
                    Text("插上后会自动识别，并在菜单栏显示电量。关闭窗口后仍在菜单栏运行。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 8) {
                            IconTile(systemImage: step.0, size: 34)
                            Text("\(index + 1). \(step.1)").font(.headline)
                            Text(step.2).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .card(padding: 18)
                    }
                }
                .frame(maxWidth: 720)
                .padding(.top, 8)
                Text("MX PIXIU 75 已在真机验证 · 其余 \(KeyboardModel.all.count - 1) 款 CHERRY 键盘与接收器按官方驱动适配")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: 560)
        }
        .background(Theme.windowBackground)
        .navigationTitle("CHERRY Utility")
        .navigationSubtitle("未检测到设备")
        .accessibilityIdentifier("onboarding")
    }
}

// MARK: - Shared helpers

/// Two-column label/value row used by grids on the detail screens.
struct InfoRow<Value: View>: View {
    let title: String
    /// Accessibility identifier of the value (UI tests read rows by it).
    let id: String?
    /// Spoken / exposed text for composite values whose children don't merge into a readable label.
    let summary: String?
    @ViewBuilder var value: Value

    init(_ title: String, id: String? = nil, summary: String? = nil, @ViewBuilder value: () -> Value) {
        self.title = title
        self.id = id
        self.summary = summary
        self.value = value()
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            if let id, let summary {
                value
                    .gridColumnAlignment(.leading)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summary)
                    .accessibilityIdentifier(id)
            } else if let id {
                value
                    .gridColumnAlignment(.leading)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(id)
            } else {
                value
                    .gridColumnAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
    }
}

extension InfoRow where Value == Text {
    init(_ title: String, id: String? = nil, _ text: String) {
        self.init(title, id: id) { Text(text) }
    }
}

extension Loadable {
    /// Plain-text form for accessibility summaries.
    func summary(_ describe: (Value) -> String) -> String {
        switch self {
        case .idle: "—"
        case .loading: "读取中"
        case .loaded(let value): describe(value)
        case .failed(let message): message
        }
    }
}

struct LoadableView<Value: Equatable, Content: View>: View {
    let loadable: Loadable<Value>
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch loadable {
        case .idle:
            Text("—").foregroundStyle(.tertiary)
        case .loading:
            ProgressView().controlSize(.small)
        case .loaded(let value):
            content(value)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warning)
        }
    }
}

func hexString(_ bytes: [UInt8], perLine: Int = 16) -> String {
    stride(from: 0, to: bytes.count, by: perLine).map { start in
        let line = bytes[start..<min(start + perLine, bytes.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
        return String(format: "%04X  ", start) + line
    }.joined(separator: "\n")
}
