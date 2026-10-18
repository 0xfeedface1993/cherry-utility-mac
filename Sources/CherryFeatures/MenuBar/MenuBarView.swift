import CherryCore
import CherryPresentation
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
            // Template images from the app's asset catalog (Design/icons/MenuBarKeycap*.svg): filled = connected.
            Image(store.keyboard == nil ? "MenuBarKeycapDisconnected" : "MenuBarKeycap", bundle: .main)
            if let text = store.labelText {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CHERRY Utility")
        .accessibilityValue(store.labelAccessibilityValue)
        .accessibilityIdentifier("menubar.label")
    }
}

// MARK: - Panel (screen entry)

public struct MenuBarPanel: View {
    let store: StoreOf<MenuBarFeature>
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    let onOpenDiagnostics: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void

    public init(
        store: StoreOf<MenuBarFeature>,
        onOpenMainWindow: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void,
        onOpenDiagnostics: @escaping @MainActor () -> Void = {},
        onOpenSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit
        self.onOpenDiagnostics = onOpenDiagnostics
        self.onOpenSettings = onOpenSettings
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
                    if !store.presets.isEmpty, lighting.showsLighting {
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
                    .frame(height: store.isApplying ? nil : 0)
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
                VStack(spacing: 8) {
                    Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("未检测到 CHERRY 键盘").font(.headline)
                    Text("用 USB 线连接键盘后会自动出现").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("menubar.empty")
            }
            Divider().padding(.horizontal, -14)
            PanelFooter(
                canRefresh: store.keyboard?.canConfigure == true,
                onRefresh: { store.send(.refresh) },
                onOpenMainWindow: onOpenMainWindow,
                onQuit: onQuit,
                onOpenDiagnostics: onOpenDiagnostics,
                onOpenSettings: onOpenSettings
            )
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.windowBackground)
        .tint(Theme.accent)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                KeycapGlyph()
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .frame(width: 36, height: 36)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.deviceName).font(.headline).lineLimit(1)
                        .accessibilityIdentifier("menubar.device")
                    HStack(spacing: 4) {
                        Circle().fill(Theme.success).frame(width: 6, height: 6)
                        Text(presentation.connection)
                            .accessibilityIdentifier("menubar.connection")
                        Text("·")
                        Text("固件 \(presentation.firmware)")
                            .accessibilityIdentifier("menubar.firmware")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isLoading { ProgressView().controlSize(.mini) }
                if presentation.showsBattery {
                    BatteryRing(percent: presentation.batteryPercent, isCharging: presentation.isCharging)
                        .accessibilityIdentifier("menubar.battery")
                }
            }
            if let lighting = presentation.lightingSummary {
                Label(lighting, systemImage: "light.max").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("menubar.summary")
            }
        }
    }
}

/// Battery as a ring with the percentage inside; charging adds a bolt.
struct BatteryRing: View {
    let percent: Int?
    let isCharging: Bool

    var body: some View {
        ZStack {
            RingGauge(fraction: Double(percent ?? 0) / 100, tint: (percent ?? 100) < 20 && !isCharging ? Theme.danger : Theme.success)
            if let percent {
                Text("\(percent)").font(.system(size: 11, weight: .bold)).monospacedDigit()
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 38, height: 38)
        .overlay(alignment: .bottomTrailing) {
            if isCharging {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(2.5).background(Theme.success, in: Circle()).offset(x: 3, y: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "电量 \($0)%" + (isCharging ? "，充电中" : "") } ?? "电量未知")
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
        VStack(alignment: .leading, spacing: 12) {
            section("配置档") {
                Picker("配置档", selection: Binding(
                    get: { presentation.profiles.first(where: \.isActive)?.id ?? 0 },
                    set: onProfile
                )) {
                    ForEach(presentation.profiles) { Text("配置 \($0.title)").tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("menubar.profile")
                .disabled(!presentation.isProfileEnabled)
                .animation(.easeInOut(duration: 0.18), value: presentation.profiles)
            }
            if presentation.showsLighting {
                section("灯效") {
                    EffectGrid(options: presentation.effects, columns: 4, compact: true, idPrefix: "menubar.effect", isEnabled: presentation.isEnabled, onSelect: onEffect)
                }
                section("亮度") {
                    BrightnessPicker(value: presentation.brightness, id: "menubar.brightness", isEnabled: presentation.isEnabled, onChange: onBrightness)
                }
                section("速度") {
                    SpeedSlider(value: presentation.speed, id: "menubar.speed", isEnabled: presentation.isEnabled, onChange: onSpeed)
                }
                if presentation.showsColor {
                    section("颜色") {
                        ColorChooser(
                            color: presentation.color, randomColor: presentation.randomColor, showsPicker: false, idPrefix: "menubar.color",
                            isEnabled: presentation.isEnabled, onColor: onColor, onRandom: { if $0 { onRandom() } }
                        )
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
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
    let onOpenSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onOpenMainWindow) {
                Label("打开 CHERRY Utility", systemImage: "macwindow")
            }
            .foregroundStyle(Theme.accentText)
            .accessibilityIdentifier("menubar.openMain")
            Spacer()
            iconButton("arrow.clockwise", "刷新", id: "menubar.refresh", action: onRefresh).disabled(!canRefresh)
            iconButton("stethoscope", "诊断", id: "menubar.diagnostics", action: onOpenDiagnostics)
            iconButton("gearshape", "设置", id: "menubar.settings", action: onOpenSettings)
            iconButton("power", "退出", id: "menubar.quit", action: onQuit)
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, _ title: String, id: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
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
