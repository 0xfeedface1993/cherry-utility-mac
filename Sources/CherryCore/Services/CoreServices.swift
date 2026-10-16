import Foundation

/// Core 应用服务的唯一装配方式：给定被驱动端口，组合独占通道、读取、配置写入和固件服务。
/// App 组合根与 Profile 工具共用它，避免两处装配逐渐不一致；它只组合 Core 自己的类型，不认识具体适配器。
public struct CoreServices: Sendable {
    public let inspector: KeyboardInspector
    public let configurator: KeyboardConfigurator
    public let writer: KeyboardConfigurationWriter
    public let firmware: FirmwareUpdateService
    private let discovery: any KeyboardDiscoveryPort

    public init(
        discovery: any KeyboardDiscoveryPort,
        channels base: any ReportChannelProvider,
        catalog: any FirmwareCatalogPort,
        downloader: any FirmwareDownloadPort,
        timeouts: FirmwareFlasher.Timeouts = .init(),
        diagnostics: Diagnostics = .noop,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        // 每个键盘接口一个队列：菜单栏、各页面和固件页轮流使用，而不是因“接口被占用”失败。
        let channels = ExclusiveChannelProvider(base: base, diagnostics: diagnostics)
        inspector = KeyboardInspector(channels: channels, diagnostics: diagnostics)
        configurator = KeyboardConfigurator(channels: channels, diagnostics: diagnostics)
        writer = KeyboardConfigurationWriter(configurator: configurator)
        firmware = FirmwareUpdateService(
            catalog: catalog, downloader: downloader, channels: channels, discovery: discovery,
            timeouts: timeouts, diagnostics: diagnostics, clock: clock
        )
        self.discovery = discovery
    }

    /// 设备列表更新：先让写入队列知道连接集合（断连使旧批次失效、拒绝旧设备的新请求），再发布给调用方。
    public func keyboardUpdates() -> AsyncStream<[KeyboardSummary]> {
        let discovery = discovery, writer = writer
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await list in discovery.keyboardUpdates() {
                    guard !Task.isCancelled else { break }
                    await writer.keyboardsUpdated(list)
                    continuation.yield(list)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension CoreServices {
    /// 自动化入口的用例服务：读取经共享独占通道，写入经共享合并队列，与菜单栏和主窗口不互相穿插。
    /// `activity` 标记正在刷写固件的键盘，期间拒绝自动化写入。
    public func automation(
        presets: PresetLibrary, activity: FirmwareActivity? = nil, feed: ConfigurationChangeFeed = .init(),
        timing: KeyboardAutomation.Timing = .init(), clock: any Clock<Duration> = ContinuousClock()
    ) -> KeyboardAutomation {
        let inspector = inspector, configurator = configurator, writer = writer
        return KeyboardAutomation(
            discovery: discovery,
            snapshot: { try await inspector.vendorSnapshot(of: $0) },
            battery: { try await inspector.battery(of: $0) },
            configuration: { try await configurator.configuration(of: $0) },
            apply: { try await writer.apply($0, on: $1) },
            presets: { try await presets.presets() },
            feed: feed, activity: activity, timing: timing, clock: clock
        )
    }
}

extension KeyboardConfigurationWriter {
    /// 单个 profile 的补丁，经写入队列合并执行；返回该 profile 的读回。
    public func update(profile: Int, patch: ProfilePatch, on keyboard: KeyboardSummary) async throws -> ProfileConfig {
        let saved = try await apply(.update(profile, patch: patch), on: keyboard)
        guard let config = saved.profile(profile) else { throw CherryError.writeNotApplied("配置档读回缺失") }
        return config
    }
}
