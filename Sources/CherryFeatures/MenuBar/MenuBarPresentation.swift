import CherryCore
import Foundation

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
    let isProfileEnabled: Bool

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
        let active = desiredConfiguration?.active
        return MenuBarStatusPresentation(
            deviceName: keyboard.displayName,
            connection: snapshot?.status.mode.displayName ?? keyboard.transportDescription,
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
            isEnabled: canConfigure,
            isProfileEnabled: canConfigure
        )
    }

    /// Text next to the status-item icon.
    var labelText: String? {
        currentSnapshot.map { "\($0.battery.percent)%" }
    }
}

