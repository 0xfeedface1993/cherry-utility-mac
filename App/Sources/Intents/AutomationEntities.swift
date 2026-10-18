import AppIntents
import CherryCore
import CherryFeatures
import CherryPresentation
import Foundation

/// 已连接（或快捷指令里保存过）的键盘。ID 为 `046A:01E2@03100000`；换 USB 口后同型号唯一时仍能找到。
struct KeyboardEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "CHERRY 键盘"
    static let defaultQuery = KeyboardEntityQuery()

    let id: String
    let name: String
    let detail: String

    init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }

    init(_ keyboard: KeyboardSummary) {
        self.init(id: keyboard.id.description, name: keyboard.displayName,
                  detail: "\(keyboard.transport) · \(String(format: "%08X", keyboard.id.locationID))")
    }

    var keyboardID: KeyboardID? { KeyboardID(id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
}

struct KeyboardEntityQuery: EntityQuery {
    @AppDependency private var automation: KeyboardAutomation

    func entities(for identifiers: [String]) async throws -> [KeyboardEntity] {
        let connected = (try? await automation.keyboards()) ?? []
        return identifiers.compactMap { identifier in
            if let keyboard = connected.first(where: { $0.id.description == identifier }) { return KeyboardEntity(keyboard) }
            // 保存过的快捷指令引用的键盘现在没连接：仍显示可读的名字，执行时再报错。
            guard let id = KeyboardID(identifier) else { return nil }
            let name = KeyboardModel.matching(vendorID: id.vendorID, productID: id.productID)?.name ?? "CHERRY 键盘"
            return KeyboardEntity(id: identifier, name: "\(name)（未连接）", detail: String(format: "%08X", id.locationID))
        }
    }

    func suggestedEntities() async throws -> [KeyboardEntity] {
        try await automation.keyboards().map(KeyboardEntity.init)
    }
}

/// 本机保存的灯光预设（`~/Library/Application Support/CherryUtility/Presets`）。
struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "灯光预设"
    static let defaultQuery = PresetEntityQuery()

    let id: UUID
    let name: String
    let modelName: String?

    init(_ preset: ProfilePreset) {
        id = preset.id
        name = preset.name
        modelName = preset.productID.flatMap { KeyboardModel.matching(vendorID: KeyboardModel.cherryVendorID, productID: $0)?.name }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(modelName ?? "适用于任何型号")")
    }
}

struct PresetEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @AppDependency private var automation: KeyboardAutomation

    func allEntities() async throws -> [PresetEntity] {
        try await automated { try await automation.presets() }.map(PresetEntity.init)
    }

    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PresetEntity] {
        try await allEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

/// 「获取键盘状态」的结果：快捷指令里可以取出各项（例如电量）继续使用。
struct KeyboardStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "键盘状态"

    @Property(title: "名称") var name: String
    @Property(title: "型号") var model: String
    @Property(title: "电量（%）") var batteryPercent: Int?
    @Property(title: "充电中") var isCharging: Bool?
    @Property(title: "连接方式") var connection: String
    @Property(title: "固件版本") var firmware: String
    @Property(title: "当前配置档") var activeProfile: Int?
    @Property(title: "灯效") var effect: String?
    @Property(title: "亮度（0–4）") var brightness: Int?
    @Property(title: "速度（1–5）") var speed: Int?
    @Property(title: "颜色") var color: String?
    @Property(title: "休眠（秒，0 为不休眠）") var sleepSeconds: Int?
    @Property(title: "深度休眠（分钟，0 为不休眠）") var deepSleepMinutes: Int?
    @Property(title: "摘要") var summary: String

    init() {
        name = ""
        model = ""
        connection = ""
        firmware = ""
        summary = ""
    }

    init(_ report: KeyboardStatusReport) {
        self.init()
        name = report.keyboard.displayName
        model = report.model.name
        connection = AutomationText.connection(report)
        firmware = report.keyboard.firmwareVersion.description
        summary = AutomationText.status(report)
        if let battery = report.snapshot?.battery {
            batteryPercent = battery.percent
            isCharging = battery.charging == .charging
        }
        if let configuration = report.snapshot?.configuration {
            let settings = configuration.active.settings
            activeProfile = configuration.activeProfile + 1
            sleepSeconds = report.model.hasSleepSettings ? settings.sleepSeconds : nil
            deepSleepMinutes = report.model.hasSleepSettings ? settings.deepSleepMinutes : nil
            if report.model.hasLighting {
                effect = AutomationText.effect(settings.effect, model: report.model)
                brightness = settings.brightness
                speed = settings.speed + 1
                color = report.model.hasColor ? AutomationText.color(settings) : nil
            }
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }
}
