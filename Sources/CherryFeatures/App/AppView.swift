import CherryCore
import ComposableArchitecture
import SwiftUI

public struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { store.selectedID }, set: { store.send(.selectKeyboard($0)) })) {
                Section("已连接的 CHERRY 设备") {
                    ForEach(store.keyboards) { keyboard in
                        KeyboardRow(keyboard: keyboard)
                            .tag(keyboard.id)
                    }
                }
                if let detail = store.detail, !detail.isConnected {
                    Section("已断开") {
                        KeyboardRow(keyboard: detail.keyboard).foregroundStyle(.secondary).tag(detail.keyboard.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .overlay {
                if store.keyboards.isEmpty && store.detail == nil {
                    ContentUnavailableView("未检测到设备", systemImage: "keyboard.badge.ellipsis", description: Text("用 USB 线连接 CHERRY 键盘"))
                }
            }
        } detail: {
            if let detailStore = store.scope(state: \.detail, action: \.detail) {
                KeyboardView(store: detailStore)
            } else {
                ContentUnavailableView("选择一个设备", systemImage: "keyboard")
            }
        }
        .task { await store.send(.task).finish() }
    }
}

struct KeyboardRow: View {
    let keyboard: KeyboardSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(keyboard.model == nil ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(keyboard.displayName).font(.headline)
                Text("\(keyboard.transport) · 固件 \(keyboard.firmwareVersion.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct KeyboardView: View {
    @Bindable var store: StoreOf<KeyboardFeature>

    var body: some View {
        VStack(spacing: 0) {
            if !store.isConnected {
                Label(store.isBusy ? "设备正在重启…" : "设备已断开，重新连接后会自动刷新", systemImage: "cable.connector.slash")
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.orange.opacity(0.15))
            }
            switch store.section {
            case .info:
                DeviceInfoView(store: store.scope(state: \.info, action: \.info))
            case .configuration:
                ConfigurationView(store: store.scope(state: \.configuration, action: \.configuration))
            case .keyTest:
                KeyTestView(store: store.scope(state: \.keyTest, action: \.keyTest))
            case .firmware:
                FirmwareView(store: store.scope(state: \.firmware, action: \.firmware))
            }
        }
        .navigationTitle(store.keyboard.displayName)
        .navigationSubtitle(store.keyboard.id.description)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("功能", selection: $store.section) {
                    ForEach(KeyboardFeature.Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

/// Two-column label/value row used across the detail screens.
struct InfoRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value
                .gridColumnAlignment(.leading)
                .textSelection(.enabled)
        }
    }
}

extension InfoRow where Value == Text {
    init(_ title: String, _ text: String) {
        self.init(title) { Text(text) }
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
                .foregroundStyle(.orange)
        }
    }
}

func hexString(_ bytes: [UInt8], perLine: Int = 16) -> String {
    stride(from: 0, to: bytes.count, by: perLine).map { start in
        let line = bytes[start..<min(start + perLine, bytes.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
        return String(format: "%04X  ", start) + line
    }.joined(separator: "\n")
}
