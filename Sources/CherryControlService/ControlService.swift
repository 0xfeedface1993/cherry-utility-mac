import CherryControl
import CherryCore
import CherryFeatures
import Foundation

/// 控制协议（CLI / MCP）的请求处理：交给 `KeyboardAutomation`，与快捷指令同一套选键盘、校验和写入规则，文案也相同。
/// 线上数值用界面单位（配置档 1 起、速度 1…5），这里换算成 Core 的 0 起编号。不提供任何固件操作。
public struct ControlService: Sendable {
    private let automation: KeyboardAutomation
    private let version: ControlVersion

    public init(automation: KeyboardAutomation, appVersion: String, build: String) {
        self.automation = automation
        version = ControlVersion(app: appVersion, build: build)
    }

    public func handle(_ request: ControlRequest, reply: @escaping @Sendable (ControlResponse) -> Void) async {
        await DiagnosticOrigin.$current.withValue(.automation) {
            if request.method == .watch {
                await watch(request.id, reply: reply)
                return
            }
            do {
                reply(.success(request.id, try await result(for: request)))
            } catch {
                reply(.failure(request.id, ControlFailure(error)))
            }
        }
    }

    func result(for request: ControlRequest) async throws -> ControlResult {
        let params = request.params ?? ControlParams()
        switch request.method {
        case .ping:
            return ControlResult(message: "pong")
        case .version:
            return ControlResult(version: version)
        case .keyboards:
            return ControlResult(keyboards: try await automation.keyboards().map(ControlKeyboard.init))
        case .status:
            let report = try await automation.status(of: try Self.keyboardID(params))
            return ControlResult(message: AutomationText.status(report), status: ControlStatus(report))
        case .battery:
            let (keyboard, battery) = try await automation.battery(of: try Self.keyboardID(params))
            return ControlResult(message: AutomationText.battery(keyboard, battery), keyboard: ControlKeyboard(keyboard), battery: ControlBattery(battery))
        case .effects:
            let (keyboard, effects) = try await automation.lightingEffects(of: try Self.keyboardID(params))
            return ControlResult(keyboard: ControlKeyboard(keyboard), effects: effects.map { ControlEffect(name: $0.name, englishName: $0.englishName) })
        case .presets:
            return ControlResult(presets: try await automation.presets().map(ControlPreset.init))
        case .activateProfile:
            let profile = try Self.required(params.profile, "profile")
            let result = try await automation.activate(profile: profile - 1, on: try Self.keyboardID(params))
            return Self.written(result, message: AutomationText.activated(result))
        case .update:
            let settings = try Self.settings(params)
            let result = try await automation.update(settings, profile: params.profile.map { $0 - 1 }, on: try Self.keyboardID(params))
            return Self.written(result, message: AutomationText.updated(result, request: settings))
        case .applyPreset:
            let preset = try await preset(named: try Self.required(params.preset, "preset"))
            let result = try await automation.applyPreset(id: preset.id, profile: params.profile.map { $0 - 1 }, on: try Self.keyboardID(params))
            return Self.written(result, message: AutomationText.presetApplied(preset.name, result))
        case .watch:
            return ControlResult()
        }
    }

    /// 先订阅再确认，确认之后的写入都不会漏掉；连接关闭时 worker 被取消，循环随之结束。
    private func watch(_ id: Int, reply: @escaping @Sendable (ControlResponse) -> Void) async {
        let changes = automation.changes()
        reply(.success(id, ControlResult(message: "开始监听快捷指令、命令行等自动化入口写入的配置")))
        for await external in changes {
            guard !Task.isCancelled else { break }
            reply(.success(id, ControlResult(change: ControlChange(external))))
        }
    }

    /// 预设可以按 ID 或名称（不区分大小写）指定；重名时要求用 ID。
    private func preset(named query: String) async throws -> ProfilePreset {
        let presets = try await automation.presets()
        if let id = UUID(uuidString: query), let preset = presets.first(where: { $0.id == id }) { return preset }
        let matches = presets.filter { $0.name.compare(query, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
        guard let preset = matches.first else {
            throw ControlFailure(code: "presetNotFound", message: "没有名为「\(query)」的预设")
        }
        guard matches.count == 1 else {
            throw ControlFailure(code: "ambiguousPreset", message: "有 \(matches.count) 个名为「\(query)」的预设，请用 ID 指定：\(matches.map(\.id.uuidString).joined(separator: "、"))")
        }
        return preset
    }

    static func keyboardID(_ params: ControlParams) throws -> KeyboardID? {
        guard let text = params.keyboard else { return nil }
        guard let id = KeyboardID(text) else {
            throw ControlFailure(code: "invalidArgument", message: "键盘 ID「\(text)」格式不对，应为 046A:01E2@03100000 这样的形式")
        }
        return id
    }

    static func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw ControlFailure(code: "invalidArgument", message: "缺少参数 \(name)") }
        return value
    }

    static func settings(_ params: ControlParams) throws -> SettingsRequest {
        SettingsRequest(
            effect: params.effect, brightness: params.brightness, speed: params.speed.map { $0 - 1 },
            color: try params.color.map(SettingsRequest.Color.init(parsing:)), sleepSeconds: params.sleepSeconds,
            deepSleepMinutes: params.deepSleepMinutes
        )
    }

    static func written(_ result: AutomationResult, message: String) -> ControlResult {
        ControlResult(
            message: message, keyboard: ControlKeyboard(result.keyboard),
            profile: result.configuration.profile(result.profile).map { ControlProfile($0, model: result.model) }
        )
    }
}
