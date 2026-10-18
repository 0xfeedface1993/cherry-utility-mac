import CherryControl
import CherryCore
import CherryPresentation
import Foundation

/// 控制协议（CLI / MCP）的请求处理：交给 `KeyboardAutomation`，与快捷指令同一套选键盘、校验和写入规则，文案也相同。
/// 线上数值用界面单位（配置档 1 起、速度 1…5），这里换算成 Core 的 0 起编号。不提供任何固件操作。
///
/// App 进程里它处理 socket 上的请求；命令行在 App 没运行时直连键盘，同一个类型在命令行进程内处理同样的请求。
/// 两处都先经 `AutomationEntries` 核对入口开关（`ping` / `version` 除外），处理完记下这次调用。
public struct ControlService: Sendable {
    private let automation: KeyboardAutomation
    private let entries: AutomationEntries?
    private let version: ControlVersion

    /// `entries` 为 nil 时不核对开关、不记录（只在测试里这样用）。
    public init(automation: KeyboardAutomation, entries: AutomationEntries? = nil, appVersion: String, build: String) {
        self.automation = automation
        self.entries = entries
        version = ControlVersion(app: appVersion, build: build)
    }

    public func handle(_ request: ControlRequest, reply: @escaping @Sendable (ControlResponse) -> Void) async {
        await DiagnosticOrigin.$current.withValue(.automation) {
            let entry = Self.entry(request.client)
            let tracked = ![.ping, .version].contains(request.method)
            // 先记录再回复：调用方拿到响应时，这次调用已经在共享记录里。
            if tracked, let entries {
                do { try entries.authorize(entry) } catch {
                    entries.record(entry, operation: request.method.rawValue, succeeded: false)
                    reply(.failure(request.id, ControlFailure(error)))
                    return
                }
            }
            if request.method == .watch {
                entries?.record(entry, operation: request.method.rawValue, succeeded: true)
                await watch(request.id, entry: entry, reply: reply)
                return
            }
            let response: ControlResponse
            do {
                response = .success(request.id, try await result(for: request))
            } catch {
                response = .failure(request.id, ControlFailure(error))
            }
            if tracked { entries?.record(entry, operation: request.method.rawValue, succeeded: response.ok) }
            reply(response)
        }
    }

    /// 线上的 `client` 映射为入口；没有或不认识时按命令行处理（旧版 cherry 不带这个字段）。
    static func entry(_ client: String?) -> AutomationEntry {
        client == ControlClientKind.mcp ? .mcp : .commandLine
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
            let result = try await automation.activate(profile: try Self.zeroBased(profile, "profile"), on: try Self.keyboardID(params))
            return Self.written(result, message: AutomationText.activated(result))
        case .update:
            let settings = try Self.settings(params)
            let result = try await automation.update(settings, profile: try Self.profile(params), on: try Self.keyboardID(params))
            return Self.written(result, message: AutomationText.updated(result, request: settings))
        case .applyPreset:
            let preset = try await preset(named: try Self.required(params.preset, "preset"))
            let result = try await automation.applyPreset(id: preset.id, profile: try Self.profile(params), on: try Self.keyboardID(params))
            return Self.written(result, message: AutomationText.presetApplied(preset.name, result))
        case .watch:
            return ControlResult()
        }
    }

    /// 先订阅再确认，确认之后的写入都不会漏掉；连接关闭时 worker 被取消，循环随之结束。
    /// 每个事件前重新核对开关：用户在设置里关掉这个入口后，回一条失败并结束。
    private func watch(_ id: Int, entry: AutomationEntry, reply: @escaping @Sendable (ControlResponse) -> Void) async {
        let changes = automation.changes()
        reply(.success(id, ControlResult(message: "开始监听快捷指令、命令行等自动化入口写入的配置")))
        for await external in changes {
            guard !Task.isCancelled else { break }
            if let entries {
                do { try entries.authorize(entry) } catch {
                    reply(.failure(id, ControlFailure(error)))
                    break
                }
            }
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

    /// 线上 1 起的编号换成 Core 的 0 起。范围由 Core 按型号校验（文案相同）；只有减 1 会溢出的值（Int.min）在这里拒绝，
    /// 否则同一用户的任何进程发一个极端值就能让 App 崩溃。
    static func zeroBased(_ value: Int, _ name: String) throws -> Int {
        let (result, overflow) = value.subtractingReportingOverflow(1)
        guard !overflow else { throw ControlFailure(code: "invalidArgument", message: "参数 \(name) 的值 \(value) 无效") }
        return result
    }

    static func profile(_ params: ControlParams) throws -> Int? {
        try params.profile.map { try zeroBased($0, "profile") }
    }

    static func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw ControlFailure(code: "invalidArgument", message: "缺少参数 \(name)") }
        return value
    }

    static func settings(_ params: ControlParams) throws -> SettingsRequest {
        SettingsRequest(
            effect: params.effect, brightness: params.brightness, speed: try params.speed.map { try Self.zeroBased($0, "speed") },
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
