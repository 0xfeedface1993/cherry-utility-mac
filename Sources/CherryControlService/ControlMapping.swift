import CherryControl
import CherryCore
import CherryPresentation
import Foundation

// 领域类型 → 线上类型。型号不支持的字段留空，CLI 与 MCP 客户端据此判断能力。

extension ControlKeyboard {
    init(_ keyboard: KeyboardSummary) {
        self.init(
            id: keyboard.id.description, name: keyboard.displayName, model: keyboard.model?.name, transport: keyboard.transport,
            firmware: keyboard.firmwareVersion.description, configurable: keyboard.canConfigure
        )
    }
}

extension ControlBattery {
    init(_ battery: BatteryStatus) {
        let charging: Bool? = switch battery.charging {
        case .charging: true
        case .notCharging: false
        case .other: nil
        }
        self.init(percent: battery.percent, charging: charging)
    }
}

extension ControlProfile {
    init(_ config: ProfileConfig, model: KeyboardModel) {
        let settings = config.settings
        self.init(profile: config.profile + 1)
        if model.hasLighting {
            effect = AutomationText.effect(settings.effect, model: model)
            effectEnglishName = model.effect(settings.effect)?.englishName
            brightness = settings.brightness
            speed = settings.speed + 1
        }
        if model.hasColor {
            color = settings.color.description
            randomColor = settings.randomColor
        }
        if model.hasSleepSettings {
            sleepSeconds = settings.sleepSeconds
            deepSleepMinutes = settings.deepSleepMinutes
        }
    }
}

extension ControlStatus {
    init(_ report: KeyboardStatusReport) {
        let configuration = report.snapshot?.configuration
        self.init(
            keyboard: ControlKeyboard(report.keyboard), battery: report.snapshot?.battery.map(ControlBattery.init),
            connection: AutomationText.connection(report), activeProfile: configuration.map { $0.activeProfile + 1 },
            profiles: configuration?.profiles.map { ControlProfile($0, model: report.model) }, summary: AutomationText.status(report)
        )
    }
}

extension ControlPreset {
    init(_ preset: ProfilePreset) {
        let model = preset.productID.flatMap { KeyboardModel.matching(vendorID: KeyboardModel.cherryVendorID, productID: $0) }
        self.init(id: preset.id.uuidString, name: preset.name, model: model?.name, createdAt: preset.createdAt)
    }
}

extension ControlChange {
    init(_ external: ExternalConfigurationChange) {
        let id = external.keyboardID
        let configuration: KeyboardConfiguration? = switch external.change {
        case .configuration(let configuration): configuration
        case .profile: nil
        }
        let model = KeyboardModel.matching(vendorID: id.vendorID, productID: id.productID)
        self.init(
            keyboard: id.description, activeProfile: (configuration?.activeProfile ?? 0) + 1,
            profiles: model.map { model in configuration?.profiles.map { ControlProfile($0, model: model) } ?? [] } ?? []
        )
    }
}

extension ControlFailure {
    /// `code` 稳定、供程序判断；`message` 与界面和快捷指令的中文文案一致。
    init(_ error: any Error) {
        if let failure = error as? ControlFailure {
            self = failure
            return
        }
        var candidates: [ControlKeyboard]?
        let code: String
        switch error {
        case let automation as AutomationError:
            switch automation {
            case .noKeyboard: code = "noKeyboard"
            case .ambiguousKeyboard(let keyboards):
                code = "ambiguousKeyboard"
                candidates = keyboards.map(ControlKeyboard.init)
            case .fieldUnsupported: code = "unsupportedSetting"
            case .unknownEffect: code = "unknownEffect"
            case .valueOutOfRange, .profileOutOfRange, .invalidColor: code = "invalidArgument"
            case .noBattery: code = "noBattery"
            case .presetNotFound: code = "presetNotFound"
            case .presetIncompatible: code = "presetIncompatible"
            case .nothingToChange: code = "nothingToChange"
            case .firmwareUpdateInProgress: code = "firmwareUpdateInProgress"
            case .entryDisabled: code = "automationDisabled"
            }
        case let device as CherryError:
            switch device {
            case .deviceNotFound: code = "keyboardNotFound"
            case .accessDenied: code = "accessDenied"
            case .disconnected: code = "disconnected"
            case .interfaceNotFound: code = "interfaceNotFound"
            case .unsupportedModel: code = "unsupportedModel"
            case .timeout: code = "timeout"
            case .unsupportedSetting: code = "unsupportedSetting"
            case .writeNotApplied: code = "writeNotApplied"
            case .deviceBusy(.updatingFirmware): code = "firmwareUpdateInProgress"
            case .deviceBusy(.inUse): code = "deviceBusy"
            default: code = "deviceError"
            }
        default:
            code = "internalError"
        }
        self.init(code: code, message: error.userMessage, candidates: candidates)
    }
}
