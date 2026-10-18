import Foundation
import Synchronization

/// 自动化入口（快捷指令、Spotlight，之后的 CLI / MCP）共用的用例：选键盘、按型号校验、只写请求的字段。
///
/// 写入经 App 共享的 `KeyboardConfigurationWriter` 执行，与菜单栏、主窗口排在同一个按设备合并的队列里；
/// 成功读回后经 `changes()` 广播，界面据此同步。配置档编号从 0 开始。
public struct KeyboardAutomation: Sendable {
    public struct Timing: Sendable {
        /// 冷启动（例如被系统拉起执行快捷指令）时等待首次发现的上限。
        public var discoveryTimeout: Duration
        /// 出现可配置键盘后再等的静默时间：IOKit 按接口逐个发布，第一份列表可能缺接口或缺第二把键盘。
        public var settle: Duration
        public var poll: Duration

        public init(discoveryTimeout: Duration = .seconds(3), settle: Duration = .milliseconds(300), poll: Duration = .milliseconds(100)) {
            self.discoveryTimeout = discoveryTimeout
            self.settle = settle
            self.poll = poll
        }
    }

    public typealias Snapshot = @Sendable (KeyboardSummary) async throws -> VendorSnapshot
    public typealias Battery = @Sendable (KeyboardSummary) async throws -> BatteryStatus
    public typealias Read = @Sendable (KeyboardSummary) async throws -> KeyboardConfiguration
    public typealias Apply = @Sendable (ConfigurationIntent, KeyboardSummary) async throws -> KeyboardConfiguration
    public typealias Presets = @Sendable () async throws -> [ProfilePreset]

    private let discovery: any KeyboardDiscoveryPort
    private let snapshot: Snapshot
    private let readBattery: Battery
    private let read: Read
    private let apply: Apply
    private let loadPresets: Presets
    private let feed: ConfigurationChangeFeed
    private let signals: any CrossProcessSignalPort
    private let activity: FirmwareActivity?
    private let timing: Timing
    private let clock: any Clock<Duration>
    private let sightings: KeyboardSightings
    private let discoveryState = DiscoveryState()

    public init(
        discovery: any KeyboardDiscoveryPort, snapshot: @escaping Snapshot, battery: @escaping Battery, configuration: @escaping Read,
        apply: @escaping Apply, presets: @escaping Presets, feed: ConfigurationChangeFeed = .init(),
        signals: any CrossProcessSignalPort = ProcessLocalSignals(), activity: FirmwareActivity? = nil,
        sightings: KeyboardSightings = .init(), timing: Timing = .init(), clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.discovery = discovery
        self.snapshot = snapshot
        readBattery = battery
        read = configuration
        self.apply = apply
        loadPresets = presets
        self.feed = feed
        self.signals = signals
        self.activity = activity
        self.sightings = sightings
        self.timing = timing
        self.clock = clock
    }

    // MARK: - Reading

    /// Connected keyboards of a known model.
    public func keyboards() async throws -> [KeyboardSummary] {
        let known = try await settledKeyboards().filter { $0.model != nil }
        sightings.record(known)
        return known
    }

    /// The keyboard `id` names, or the only (configurable) one when `id` is nil.
    ///
    /// A saved shortcut keeps the ID it was made with; the location part changes when the keyboard moves to another
    /// USB port, so an ID this app run has never seen still resolves when exactly one keyboard of that product is connected.
    /// An ID that was connected earlier in this run and is gone now is reported missing: with two keyboards of the same
    /// model, unplugging one must not retarget its commands to the other.
    public func keyboard(_ id: KeyboardID?) async throws -> KeyboardSummary {
        let known = try await keyboards()
        if let id {
            if let exact = known.first(where: { $0.id == id }) { return exact }
            // 刷写进入重启阶段时键盘会离线一会儿，仍报升级中，而不是未找到。
            if activity?.isBusy(id) == true { throw AutomationError.firmwareUpdateInProgress }
            guard !sightings.contains(id) else { throw CherryError.deviceNotFound(id) }
            let sameProduct = known.filter { $0.id.vendorID == id.vendorID && $0.id.productID == id.productID }
            guard sameProduct.count == 1 else { throw CherryError.deviceNotFound(id) }
            return sameProduct[0]
        }
        guard !known.isEmpty else { throw activity?.isAnyBusy == true ? AutomationError.firmwareUpdateInProgress : AutomationError.noKeyboard }
        if known.count == 1 { return known[0] }
        let configurable = known.filter(\.canConfigure)
        if configurable.count == 1 { return configurable[0] }
        throw AutomationError.ambiguousKeyboard(configurable.isEmpty ? known : configurable)
    }

    public func status(of id: KeyboardID?) async throws -> KeyboardStatusReport {
        let keyboard = try await keyboard(id)
        let model = try supportedModel(keyboard)
        try requireIdle(keyboard)
        guard keyboard.canConfigure else { return KeyboardStatusReport(keyboard: keyboard, model: model, snapshot: nil) }
        return KeyboardStatusReport(keyboard: keyboard, model: model, snapshot: try await snapshot(keyboard))
    }

    public func battery(of id: KeyboardID?) async throws -> (keyboard: KeyboardSummary, battery: BatteryStatus) {
        let keyboard = try await keyboard(id)
        let model = try supportedModel(keyboard)
        guard model.hasBattery else { throw AutomationError.noBattery(model: model) }
        try Self.requireConfigurationInterface(keyboard, model)
        try requireIdle(keyboard)
        return (keyboard, try await readBattery(keyboard))
    }

    public func lightingEffects(of id: KeyboardID?) async throws -> (keyboard: KeyboardSummary, effects: [LightingEffect]) {
        let keyboard = try await keyboard(id)
        return (keyboard, try supportedModel(keyboard).lightingEffects)
    }

    public func presets() async throws -> [ProfilePreset] {
        try await loadPresets()
    }

    /// Configurations written by automation and read back, for every subscriber. Writes made through another process
    /// (the app or a `cherry` command connected directly) arrive here while `relayChangesFromOtherProcesses()` runs.
    public func changes() -> AsyncStream<ExternalConfigurationChange> {
        feed.changes()
    }

    /// 另一个进程经自动化入口写入后，这里读一次在线可配置键盘的配置，作为外部变更推给本进程的订阅者。
    /// 由组合根在受监管的 Task 里运行，直到被取消；信号不带内容，所以读所有在线的可配置键盘（通常只有一把）。
    public func relayChangesFromOtherProcesses() async {
        for await _ in signals.signals(.configurationChanged) {
            guard !Task.isCancelled else { return }
            let keyboards = (try? await keyboards()) ?? []
            for keyboard in keyboards where keyboard.canConfigure && activity?.isBusy(keyboard.id) != true {
                guard !Task.isCancelled else { return }
                guard let configuration = try? await read(keyboard) else { continue }
                feed.publish(ExternalConfigurationChange(keyboardID: keyboard.id, change: .configuration(configuration)))
            }
        }
    }

    // MARK: - Writing

    public func activate(profile: Int, on id: KeyboardID?) async throws -> AutomationResult {
        let (keyboard, model) = try await writableKeyboard(id)
        try Self.validate(profile: profile, model: model)
        return try await submit(.activate(profile), profile: profile, keyboard, model)
    }

    /// Writes the fields present in `request` to `profile` (the active profile when nil); every other byte is kept.
    public func update(_ request: SettingsRequest, profile: Int?, on id: KeyboardID?) async throws -> AutomationResult {
        let (keyboard, model) = try await writableKeyboard(id)
        let patch = try Self.patch(for: request, model: model)
        return try await submit(patch, to: profile, keyboard, model)
    }

    /// Loads a saved preset into `profile` (the active profile when nil), the same way the menu bar does.
    public func applyPreset(id presetID: UUID, profile: Int?, on id: KeyboardID?) async throws -> AutomationResult {
        guard let preset = try await loadPresets().first(where: { $0.id == presetID }) else {
            throw AutomationError.presetNotFound(presetID)
        }
        let (keyboard, model) = try await writableKeyboard(id)
        guard preset.isCompatible(with: keyboard) else { throw AutomationError.presetIncompatible(name: preset.name) }
        let patch = preset.patch(for: model)
        guard !patch.isEmpty else { throw AutomationError.nothingToChange }
        return try await submit(patch, to: profile, keyboard, model)
    }

    // MARK: - Rules

    /// The patch for `request`, validated against what `model` accepts. Values outside the ranges are refused here
    /// rather than silently clamped by `ProfileSettings.normalized`.
    static func patch(for request: SettingsRequest, model: KeyboardModel) throws -> ProfilePatch {
        guard !request.isEmpty else { throw AutomationError.nothingToChange }
        var values = ProfileSettings(effect: 0, brightness: 0, speed: 0, randomColor: false, color: .white, sleepSeconds: 0, deepSleepMinutes: 0)
        var fields = Set<ProfileField>()
        func take(_ field: ProfileField) throws {
            guard model.editableFields.contains(field) else { throw AutomationError.fieldUnsupported(field, model: model) }
            fields.insert(field)
        }
        func check(_ value: Int, _ field: ProfileField, in range: ClosedRange<Int>, allowingZero: Bool = false) throws {
            guard range.contains(value) || (allowingZero && value == 0) else { throw AutomationError.valueOutOfRange(field, value) }
        }

        if let name = request.effect {
            try take(.effect)
            guard let effect = model.lightingEffect(named: name) else { throw AutomationError.unknownEffect(name, model: model) }
            values.effect = effect.rawValue
        }
        if let brightness = request.brightness {
            try take(.brightness)
            try check(brightness, .brightness, in: ProfileSettings.brightnessRange)
            values.brightness = brightness
        }
        if let speed = request.speed {
            try take(.speed)
            try check(speed, .speed, in: ProfileSettings.speedRange)
            values.speed = speed
        }
        switch request.color {
        case .fixed(let color):
            // 与菜单栏一致：选定固定色同时关闭随机颜色。
            try take(.color)
            try take(.randomColor)
            values.color = color
        case .random:
            try take(.randomColor)
            values.randomColor = true
        case nil:
            break
        }
        if let seconds = request.sleepSeconds {
            try take(.sleepSeconds)
            try check(seconds, .sleepSeconds, in: ProfileSettings.sleepSecondsRange, allowingZero: true)
            values.sleepSeconds = seconds
        }
        if let minutes = request.deepSleepMinutes {
            try take(.deepSleepMinutes)
            try check(minutes, .deepSleepMinutes, in: ProfileSettings.deepSleepMinutesRange, allowingZero: true)
            values.deepSleepMinutes = minutes
        }
        return ProfilePatch(values, fields: fields)
    }

    static func validate(profile: Int, model: KeyboardModel) throws {
        guard (0..<model.profileCount).contains(profile) else { throw AutomationError.profileOutOfRange(profile, model: model) }
    }

    static func requireConfigurationInterface(_ keyboard: KeyboardSummary, _ model: KeyboardModel) throws {
        guard keyboard.canConfigure else { throw CherryError.interfaceNotFound(usagePage: model.vendorUsagePage) }
    }

    // MARK: - Steps

    private func writableKeyboard(_ id: KeyboardID?) async throws -> (KeyboardSummary, KeyboardModel) {
        let keyboard = try await keyboard(id)
        let model = try supportedModel(keyboard)
        try Self.requireConfigurationInterface(keyboard, model)
        try requireIdle(keyboard)
        return (keyboard, model)
    }

    /// 刷写固件期间键盘会重启，读写 0xFF1C 都可能与 OTA 交错，所以自动化的读取和写入都拒绝。
    private func requireIdle(_ keyboard: KeyboardSummary) throws {
        if activity?.isBusy(keyboard.id) == true { throw AutomationError.firmwareUpdateInProgress }
    }

    /// 未指定配置档时不先读当前档：补丁在写入事务内落到当前档，慢设备上并发的写入不必各自排队读一次。
    private func submit(_ patch: ProfilePatch, to profile: Int?, _ keyboard: KeyboardSummary, _ model: KeyboardModel) async throws -> AutomationResult {
        if let profile { try Self.validate(profile: profile, model: model) }
        let intent = profile.map { ConfigurationIntent.update($0, patch: patch) } ?? .updateActive(patch: patch)
        return try await submit(intent, profile: profile, keyboard, model)
    }

    /// `profile` 为 nil 时目标是写入后的当前档（与 `ConfigurationIntent.activePatch` 的落位一致）。
    private func submit(
        _ intent: ConfigurationIntent, profile: Int?, _ keyboard: KeyboardSummary, _ model: KeyboardModel
    ) async throws -> AutomationResult {
        let saved = try await apply(intent, keyboard)
        feed.publish(ExternalConfigurationChange(keyboardID: keyboard.id, change: .configuration(saved)))
        signals.post(.configurationChanged)
        return AutomationResult(keyboard: keyboard, model: model, configuration: saved, profile: profile ?? saved.activeProfile)
    }

    /// 第一次调用时等待发现稳定；此后发现结果由 App 生命周期内的 IOKit 管理器实时维护，直接读取。
    private func settledKeyboards() async throws -> [KeyboardSummary] {
        // 锁内只拷出标志，读取发现结果在锁外。
        let settled = discoveryState.settled.withLock { $0 }
        if settled { return await discovery.keyboards() }
        var list = await discovery.keyboards()
        var waited = Duration.zero
        while !list.contains(where: \.canConfigure), waited < timing.discoveryTimeout {
            try Task.checkCancellation()
            try await clock.sleep(for: timing.poll)
            waited += timing.poll
            list = await discovery.keyboards()
        }
        if list.contains(where: \.canConfigure), timing.settle > .zero {
            try await clock.sleep(for: timing.settle)
            list = await discovery.keyboards()
        }
        discoveryState.settled.withLock { $0 = true }
        return list
    }
}

/// 共享给结构体各副本的可变状态（`Mutex` 不可复制，不能直接存进结构体）。
private final class DiscoveryState: Sendable {
    let settled = Mutex(false)
}
