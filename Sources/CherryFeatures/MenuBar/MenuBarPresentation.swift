import CherryCore
import CherryPresentation
import Foundation

// MARK: - Presentation

struct MenuBarStatusPresentation: Equatable {
    let deviceName: String
    let connection: String
    /// Wired-only models have no battery; the ring is hidden for them.
    let showsBattery: Bool
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
    /// No-backlight models only switch profiles; single-colour models have no colour row.
    let showsLighting: Bool
    let showsColor: Bool
    let isEnabled: Bool
    let isProfileEnabled: Bool

    struct ProfileChip: Equatable, Identifiable {
        let id: Int
        let title: String
        let isActive: Bool
    }
}

extension MenuBarFeature.State {
    var statusPresentation: MenuBarStatusPresentation? {
        guard let keyboard else { return nil }
        let snapshot = currentSnapshot
        let active = desiredConfiguration?.active
        return MenuBarStatusPresentation(
            deviceName: keyboard.displayName,
            connection: snapshot?.status?.mode.displayName ?? keyboard.transportDescription,
            showsBattery: model?.hasBattery ?? false,
            batteryPercent: snapshot?.battery?.percent,
            isCharging: snapshot?.battery?.charging == .charging,
            firmware: keyboard.firmwareVersion.description,
            lightingSummary: active.map {
                model?.hasLighting == false
                    ? "配置 \($0.profile + 1) · 无背光"
                    : "配置 \($0.profile + 1) · \(model?.effectName($0.lightingEffect) ?? "") · 亮度 \(LightingText.brightness($0.brightness))"
            },
            updatedAt: lastUpdated?.formatted(date: .omitted, time: .shortened)
        )
    }

    var lightingPresentation: MenuBarLightingPresentation? {
        guard let model, let configuration = desiredConfiguration else { return nil }
        let active = configuration.active.settings
        return MenuBarLightingPresentation(
            profiles: (0..<model.profileCount).map { .init(id: $0, title: "\($0 + 1)", isActive: $0 == configuration.activeProfile) },
            effects: model.lightingEffects.map {
                EffectOption(id: $0.rawValue, name: $0.name, symbol: $0.symbol, isSelected: $0.rawValue == active.effect)
            },
            brightness: min(active.brightness, 4),
            speed: active.speed,
            color: active.color,
            randomColor: active.randomColor,
            showsLighting: model.hasLighting,
            showsColor: model.hasColor,
            isEnabled: canConfigure,
            isProfileEnabled: canConfigure
        )
    }

    /// Text next to the status-item icon (hidden when turned off in Settings).
    var labelText: String? {
        guard showsBatteryInLabel else { return nil }
        return currentSnapshot?.battery.map { "\($0.percent)%" }
    }

    /// Spoken value of the status item; independent of whether the percentage is drawn.
    var labelAccessibilityValue: String {
        if let battery = currentSnapshot?.battery { return "\(battery.percent)%" }
        return keyboard == nil ? "未连接" : (model?.hasBattery == false ? "有线" : "—")
    }
}

