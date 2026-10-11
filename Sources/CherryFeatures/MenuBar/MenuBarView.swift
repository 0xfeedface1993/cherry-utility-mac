import CherryCore
import ComposableArchitecture
import SwiftUI

// MARK: - Status item label

public struct MenuBarLabel: View {
    let store: StoreOf<MenuBarFeature>

    public init(store: StoreOf<MenuBarFeature>) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.keyboard == nil ? "keyboard.badge.ellipsis" : "keyboard")
            if let text = store.labelText {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CHERRY Utility")
        .accessibilityValue(store.labelText ?? "未连接")
        .accessibilityIdentifier("menubar.label")
    }
}

// MARK: - Panel (screen entry)

public struct MenuBarPanel: View {
    let store: StoreOf<MenuBarFeature>
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    let onOpenDiagnostics: @MainActor () -> Void

    public init(store: StoreOf<MenuBarFeature>, onOpenMainWindow: @escaping @MainActor () -> Void, onQuit: @escaping @MainActor () -> Void, onOpenDiagnostics: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit
        self.onOpenDiagnostics = onOpenDiagnostics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.keyboards.count > 1 {
                Picker("设备", selection: Binding(get: { store.keyboard?.id }, set: { if let id = $0 { store.send(.selectKeyboard(id)) } })) {
                    ForEach(store.keyboards) { Text($0.selectionLabel).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("menubar.devicePicker")
            }
            if let status = store.statusPresentation {
                StatusHeader(presentation: status, isLoading: store.snapshot.isLoading)
                Divider()
                if let lighting = store.lightingPresentation {
                    QuickLightingControls(
                        presentation: lighting,
                        onProfile: { store.send(.activateProfile($0)) },
                        onEffect: { store.send(.setEffect($0)) },
                        onBrightness: { store.send(.setBrightness($0)) },
                        onSpeed: { store.send(.setSpeed($0)) },
                        onColor: { store.send(.setColor($0)) },
                        onRandom: { store.send(.setRandomColor) }
                    )
                    if !store.presets.isEmpty {
                        PresetMenu(presets: store.presets, isEnabled: lighting.isEnabled) { store.send(.applyPreset($0)) }
                    }
                } else if store.model == nil {
                    Text("该型号尚未适配，只能查看 USB 信息。").font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("menubar.unsupported")
                } else if store.snapshot.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Label("正在配置键盘…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                    .opacity(store.isApplying ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: store.isApplying)
                    .accessibilityHidden(!store.isApplying)
                    .accessibilityIdentifier("menubar.configuring")
                if store.model != nil && store.keyboard?.canConfigure == false {
                    Label("配置接口已断开，重新连接 USB 后可操作", systemImage: "cable.connector.slash")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("menubar.unavailable")
                }
                if let error = store.errorMessage {
                    ErrorNotice(message: error, showsSettingsButton: store.needsInputMonitoring) {
                        store.send(.openInputMonitoringTapped)
                    }
                }
            } else {
                ContentUnavailableView("未检测到 CHERRY 键盘", systemImage: "keyboard.badge.ellipsis", description: Text("用 USB 线连接键盘"))
                    .frame(height: 140)
                    .accessibilityIdentifier("menubar.empty")
            }
            Divider()
            PanelFooter(
                canRefresh: store.keyboard?.canConfigure == true,
                onRefresh: { store.send(.refresh) },
                onOpenMainWindow: onOpenMainWindow,
                onQuit: onQuit,
                onOpenDiagnostics: onOpenDiagnostics
            )
        }
        .padding(14)
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.panel")
        .task { await store.send(.panelAppeared).finish() }
    }
}

// MARK: - Components

struct StatusHeader: View {
    let presentation: MenuBarStatusPresentation
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "keyboard").foregroundStyle(Color.accentColor)
                Text(presentation.deviceName).font(.headline)
                    .accessibilityIdentifier("menubar.device")
                Spacer()
                if isLoading { ProgressView().controlSize(.mini) }
                BatteryBadge(percent: presentation.batteryPercent, isCharging: presentation.isCharging)
                    .font(.callout)
                    .accessibilityIdentifier("menubar.battery")
            }
            HStack(spacing: 10) {
                Label(presentation.connection, systemImage: "cable.connector")
                    .accessibilityIdentifier("menubar.connection")
                Label("固件 \(presentation.firmware)", systemImage: "cpu")
                    .accessibilityIdentifier("menubar.firmware")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let lighting = presentation.lightingSummary {
                Label(lighting, systemImage: "light.max").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("menubar.summary")
            }
        }
    }
}

struct QuickLightingControls: View {
    let presentation: MenuBarLightingPresentation
    let onProfile: @MainActor (Int) -> Void
    let onEffect: @MainActor (UInt8) -> Void
    let onBrightness: @MainActor (Int) -> Void
    let onSpeed: @MainActor (Int) -> Void
    let onColor: @MainActor (LEDColor) -> Void
    let onRandom: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("配置档").font(.subheadline.weight(.medium))
                Spacer()
                Picker("配置档", selection: Binding(
                    get: { presentation.profiles.first(where: \.isActive)?.id ?? 0 },
                    set: onProfile
                )) {
                    ForEach(presentation.profiles) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityIdentifier("menubar.profile")
                .disabled(!presentation.isProfileEnabled)
                .animation(.easeInOut(duration: 0.18), value: presentation.profiles)
            }
            Text("灯效").font(.subheadline.weight(.medium))
            EffectGrid(options: presentation.effects, columns: 4, compact: true, idPrefix: "menubar.effect", isEnabled: presentation.isEnabled, onSelect: onEffect)
            HStack {
                Text("亮度").font(.subheadline.weight(.medium)).frame(width: 34, alignment: .leading)
                BrightnessPicker(value: presentation.brightness, id: "menubar.brightness", isEnabled: presentation.isEnabled, onChange: onBrightness)
            }
            HStack {
                Text("速度").font(.subheadline.weight(.medium)).frame(width: 34, alignment: .leading)
                SpeedSlider(value: presentation.speed, id: "menubar.speed", isEnabled: presentation.isEnabled, onChange: onSpeed)
            }
            ColorChooser(
                color: presentation.color, randomColor: presentation.randomColor, showsPicker: false, idPrefix: "menubar.color",
                isEnabled: presentation.isEnabled, onColor: onColor, onRandom: { if $0 { onRandom() } }
            )
        }
    }
}

struct PresetMenu: View {
    let presets: [ProfilePreset]
    let isEnabled: Bool
    let onApply: @MainActor (ProfilePreset.ID) -> Void

    var body: some View {
        Menu {
            ForEach(presets) { preset in
                Button(preset.name) { onApply(preset.id) }
            }
        } label: {
            Label("载入预设到当前配置档", systemImage: "square.stack.3d.down.right")
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("menubar.presets")
    }
}

struct ErrorNotice: View {
    let message: String
    let showsSettingsButton: Bool
    let onOpenSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("menubar.error")
            if showsSettingsButton {
                Button("打开“输入监控”设置", action: onOpenSettings).controlSize(.small)
                    .accessibilityIdentifier("menubar.openSettings")
            }
        }
    }
}

struct PanelFooter: View {
    let canRefresh: Bool
    let onRefresh: @MainActor () -> Void
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    let onOpenDiagnostics: @MainActor () -> Void

    var body: some View {
        HStack {
            Button("打开 CHERRY Utility", action: onOpenMainWindow)
                .accessibilityIdentifier("menubar.openMain")
            Spacer()
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .help("刷新")
                .disabled(!canRefresh)
                .accessibilityLabel("刷新")
                .accessibilityIdentifier("menubar.refresh")
            Button("诊断", action: onOpenDiagnostics)
                .accessibilityIdentifier("menubar.diagnostics")
            Button(action: onQuit) { Image(systemName: "power") }
                .help("退出")
                .accessibilityLabel("退出")
                .accessibilityIdentifier("menubar.quit")
        }
        .buttonStyle(.borderless)
    }
}

#Preview("Menu bar panel") {
    MenuBarPanel(
        store: Store(initialState: {
            var s = MenuBarFeature.State()
            s.keyboards = [.preview]
            s.snapshot = .loaded(.preview)
            s.snapshotID = KeyboardSummary.preview.id
            s.presets = [.preview]
            return s
        }()) {
            MenuBarFeature()
        } withDependencies: {
            $0.keyboardClient = .previewValue
            $0.configurationClient = .previewValue
            $0.presetClient = .previewValue
        },
        onOpenMainWindow: {}, onQuit: {}
    )
}
