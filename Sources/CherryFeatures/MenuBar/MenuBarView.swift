import CherryCore
import ComposableArchitecture
import SwiftUI

// MARK: - Presentation

struct MenuBarStatusPresentation: Equatable {
    let deviceName: String
    let connection: String
    let batteryPercent: Int?
    let isCharging: Bool
    let firmware: String
    let lightingSummary: String?
    let updatedAt: String?
}

struct MenuBarLightingPresentation: Equatable {
    let profiles: [ProfileChip]
    let effects: [EffectOption]
    let brightness: Int
    let speed: Int
    let color: LEDColor
    let randomColor: Bool
    let isEnabled: Bool

    struct ProfileChip: Equatable, Identifiable {
        let id: Int
        let title: String
        let isActive: Bool
    }
}

extension DeviceStatusBlock.ConnectionMode {
    var displayName: String {
        switch self {
        case .wired: "有线 USB"
        case .wireless(let raw): "无线（模式值 \(raw)）"
        case .unknown(let raw): "未知模式 \(raw)"
        }
    }
}

extension MenuBarFeature.State {
    var statusPresentation: MenuBarStatusPresentation? {
        guard let keyboard else { return nil }
        let snapshot = currentSnapshot
        let active = snapshot?.configuration.active
        return MenuBarStatusPresentation(
            deviceName: keyboard.displayName,
            connection: snapshot?.status.mode.displayName ?? keyboard.transport,
            batteryPercent: snapshot?.battery.percent,
            isCharging: snapshot?.battery.charging == .charging,
            firmware: keyboard.firmwareVersion.description,
            lightingSummary: active.map {
                "配置 \($0.profile + 1) · \(model?.effectName($0.lightingEffect) ?? "") · 亮度 \(LightingText.brightness($0.brightness))"
            },
            updatedAt: lastUpdated?.formatted(date: .omitted, time: .shortened)
        )
    }

    var lightingPresentation: MenuBarLightingPresentation? {
        guard let model, let snapshot = currentSnapshot else { return nil }
        let active = snapshot.configuration.active
        return MenuBarLightingPresentation(
            profiles: (0..<model.profileCount).map { .init(id: $0, title: "\($0 + 1)", isActive: $0 == snapshot.configuration.activeProfile) },
            effects: model.lightingEffects.map {
                EffectOption(id: $0.rawValue, name: $0.name, symbol: $0.symbol, isSelected: $0.rawValue == active.lightingEffect)
            },
            brightness: min(active.brightness, 4),
            speed: active.speed,
            color: active.color,
            randomColor: active.randomColor,
            isEnabled: !isApplying
        )
    }

    /// Text next to the status-item icon.
    var labelText: String? {
        currentSnapshot.map { "\($0.battery.percent)%" }
    }
}

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
    }
}

// MARK: - Panel (screen entry)

public struct MenuBarPanel: View {
    let store: StoreOf<MenuBarFeature>
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void

    public init(store: StoreOf<MenuBarFeature>, onOpenMainWindow: @escaping @MainActor () -> Void, onQuit: @escaping @MainActor () -> Void) {
        self.store = store
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.keyboards.count > 1 {
                Picker("设备", selection: Binding(get: { store.keyboard?.id }, set: { if let id = $0 { store.send(.selectKeyboard(id)) } })) {
                    ForEach(store.keyboards) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
            if let status = store.statusPresentation {
                StatusHeader(presentation: status, isLoading: store.snapshot.isLoading || store.isApplying)
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
                } else if store.snapshot.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = store.errorMessage {
                    ErrorNotice(message: error, showsSettingsButton: store.needsInputMonitoring) {
                        store.send(.openInputMonitoringTapped)
                    }
                }
            } else {
                ContentUnavailableView("未检测到 CHERRY 键盘", systemImage: "keyboard.badge.ellipsis", description: Text("用 USB 线连接键盘"))
                    .frame(height: 140)
            }
            Divider()
            PanelFooter(
                canRefresh: store.keyboard != nil,
                onRefresh: { store.send(.refresh) },
                onOpenMainWindow: onOpenMainWindow,
                onQuit: onQuit
            )
        }
        .padding(14)
        .frame(width: 340)
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
                Spacer()
                if isLoading { ProgressView().controlSize(.mini) }
                BatteryBadge(percent: presentation.batteryPercent, isCharging: presentation.isCharging)
                    .font(.callout)
            }
            HStack(spacing: 10) {
                Label(presentation.connection, systemImage: "cable.connector")
                Label("固件 \(presentation.firmware)", systemImage: "cpu")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let lighting = presentation.lightingSummary {
                Label(lighting, systemImage: "light.max").font(.caption).foregroundStyle(.secondary)
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
            }
            Text("灯效").font(.subheadline.weight(.medium))
            EffectGrid(options: presentation.effects, columns: 4, compact: true, isEnabled: presentation.isEnabled, onSelect: onEffect)
            HStack {
                Text("亮度").font(.subheadline.weight(.medium)).frame(width: 34, alignment: .leading)
                BrightnessPicker(value: presentation.brightness, isEnabled: presentation.isEnabled, onChange: onBrightness)
            }
            HStack {
                Text("速度").font(.subheadline.weight(.medium)).frame(width: 34, alignment: .leading)
                SpeedSlider(value: presentation.speed, isEnabled: presentation.isEnabled, onChange: onSpeed)
            }
            ColorChooser(
                color: presentation.color, randomColor: presentation.randomColor, showsPicker: false,
                isEnabled: presentation.isEnabled, onColor: onColor, onRandom: { if $0 { onRandom() } }
            )
        }
        .disabled(!presentation.isEnabled)
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
    }
}

struct ErrorNotice: View {
    let message: String
    let showsSettingsButton: Bool
    let onOpenSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            if showsSettingsButton {
                Button("打开“输入监控”设置", action: onOpenSettings).controlSize(.small)
            }
        }
    }
}

struct PanelFooter: View {
    let canRefresh: Bool
    let onRefresh: @MainActor () -> Void
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void

    var body: some View {
        HStack {
            Button("打开 CHERRY Utility", action: onOpenMainWindow)
            Spacer()
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .help("刷新")
                .disabled(!canRefresh)
            Button(action: onQuit) { Image(systemName: "power") }
                .help("退出")
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
