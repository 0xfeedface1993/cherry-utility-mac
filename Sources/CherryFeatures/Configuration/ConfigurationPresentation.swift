import CherryCore
import CherryPresentation
import Foundation

// UIModel → Presentation mapping for the configuration screen. Views only ever see these value types.

struct ProfileTabsPresentation: Equatable {
    struct Item: Equatable, Identifiable {
        let id: Int
        let title: String
        let summary: String
        let isActive: Bool
        let isSelected: Bool
        let isActivating: Bool
        /// Colour strip on the card; nil draws a rainbow (random colour).
        let swatch: LEDColor?
        let hasSwatch: Bool
    }

    let items: [Item]
    let isEnabled: Bool
}

struct LightingPresentation: Equatable {
    let effects: [EffectOption]
    let isEffectDirty: Bool
    let effectName: String
    let isCustomEffect: Bool
    /// Single-colour backlights have no colour row.
    let showsColor: Bool
    let brightness: Int
    let speed: Int
    let randomColor: Bool
    let color: LEDColor
    let dirty: Set<ProfileField>
    let isEnabled: Bool
}

struct PowerPresentation: Equatable {
    let sleepSeconds: Int
    let deepSleepMinutes: Int
    let dirty: Set<ProfileField>
    let isEnabled: Bool
}

struct SaveBarPresentation: Equatable {
    let dirtyCount: Int
    let isSaving: Bool
    let isConnected: Bool
    let hasPendingEdits: Bool

    var hasUnsavedChanges: Bool { dirtyCount > 0 }
    var canSave: Bool { hasPendingEdits && isConnected }
}

struct DeviceDetailsPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    let rows: [Row]
}

struct PresetLibraryPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let id: UUID
        let name: String
        let detail: String
        let isCompatible: Bool
    }

    let rows: [Row]
    let isLoading: Bool
    let errorMessage: String?
    let name: String
    let canLoad: Bool
    let canSave: Bool
}

extension ConfigurationFeature.State {
    var tabsPresentation: ProfileTabsPresentation {
        let configuration = configuration.value
        return ProfileTabsPresentation(
            items: (0..<profileCount).map { n in
                let config = configuration?.profile(n)
                let lit = model?.hasLighting != false
                return .init(
                    id: n,
                    title: "配置 \(n + 1)",
                    summary: config.map { lit ? "\(model?.effectName($0.lightingEffect) ?? "") · \(LightingText.brightness($0.brightness))" : "无背光" } ?? "—",
                    isActive: activeProfile == n,
                    isSelected: selectedProfile == n,
                    isActivating: activatingProfile == n,
                    swatch: config.flatMap { $0.randomColor ? nil : $0.color },
                    hasSwatch: config != nil && lit
                )
            },
            isEnabled: isConnected && keyboard.canConfigure
        )
    }

    var lightingPresentation: LightingPresentation? {
        guard let editor, model?.hasLighting == true else { return nil }
        let draft = editor.draft
        var effects = self.effects.map { EffectOption(id: $0.rawValue, name: $0.name, symbol: $0.symbol, isSelected: $0.rawValue == draft.effect) }
        if model?.effect(draft.effect) == nil {
            // Keep an unknown value visible instead of pretending another effect is selected.
            effects.append(EffectOption(id: draft.effect, name: String(format: "0x%02X", draft.effect), symbol: "questionmark", isSelected: true))
        }
        return LightingPresentation(
            effects: effects,
            isEffectDirty: editor.dirty.contains(.effect),
            effectName: model?.effectName(draft.effect) ?? "",
            isCustomEffect: model?.effect(draft.effect)?.isCustom == true,
            showsColor: model?.hasColor == true,
            brightness: draft.brightness,
            speed: draft.speed,
            randomColor: draft.randomColor,
            color: draft.color,
            dirty: editor.dirty,
            isEnabled: canEdit
        )
    }

    var powerPresentation: PowerPresentation? {
        guard let editor, model?.hasSleepSettings == true else { return nil }
        return PowerPresentation(
            sleepSeconds: editor.draft.sleepSeconds, deepSleepMinutes: editor.draft.deepSleepMinutes,
            dirty: editor.dirty, isEnabled: canEdit
        )
    }

    var saveBarPresentation: SaveBarPresentation {
        SaveBarPresentation(dirtyCount: editor?.dirty.count ?? 0, isSaving: isSaving, isConnected: isConnected, hasPendingEdits: canSubmit)
    }

    /// Read-only fields of the selected block that this app does not edit.
    var detailsPresentation: DeviceDetailsPresentation? {
        guard let config = selectedConfig else { return nil }
        var rows: [DeviceDetailsPresentation.Row] = [
            .init(title: "回报率档位", value: LightingText.polling(config)),
            .init(title: "按键锁定", value: config.keyLocks.isEmpty ? "无" : config.keyLocks.map(\.description).joined(separator: "、")),
        ]
        if model?.hasLighting != false { rows.append(.init(title: "灯效参数", value: String(format: "方向/参数 0x%02X", config.direction))) }
        // Indicator colours (pairing / mode LEDs) only exist on wireless boards.
        if model?.isWireless != false { rows.append(.init(title: "指示灯颜色", value: config.indicatorColors.map(\.description).joined(separator: " "))) }
        return DeviceDetailsPresentation(rows: rows)
    }

    var presetPresentation: PresetLibraryPresentation {
        PresetLibraryPresentation(
            rows: (presets.value ?? []).map { preset in
                PresetLibraryPresentation.Row(
                    id: preset.id,
                    name: preset.name,
                    detail: "\(model?.effectName(preset.settings.effect) ?? "") · 亮度 \(LightingText.brightness(preset.settings.brightness)) · "
                        + (preset.settings.randomColor ? "随机颜色" : preset.settings.color.description)
                        + " · " + preset.createdAt.formatted(date: .abbreviated, time: .shortened),
                    isCompatible: preset.isCompatible(with: keyboard)
                )
            },
            isLoading: presets.isLoading,
            errorMessage: presets.errorMessage,
            name: presetName,
            canLoad: canEdit,
            canSave: editor != nil
        )
    }
}
