import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct DeviceInfoFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        public var keyboard: KeyboardSummary
        public var isConnected = true
        public var vendor: Loadable<VendorSnapshot> = .idle
        public var firmware: Loadable<DeviceFirmwareStatus> = .idle
        public var latestRelease: Loadable<FirmwareRelease?> = .idle
        public var lastUpdated: Date?
        public var refreshError: String?
        var configurationRevision: UInt64 = 0
        var loadGeneration: UInt64 = 0
        var pendingConfiguration: [ConfigurationChange] = []

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
        }

        public var model: KeyboardModel? { keyboard.model }

        /// Cloud release newer than the running firmware (bcdDevice), if any.
        public var updateAvailable: Bool? {
            guard let release = latestRelease.value else { return nil }
            guard let version = release?.version else { return false }
            return version > keyboard.firmwareVersion
        }
    }

    public enum Action {
        case task
        case refresh
        case batteryTick
        case vendorLoaded(Result<VendorSnapshot, any Error>, revision: UInt64? = nil, generation: UInt64? = nil)
        case configurationSynchronized(ConfigurationChange)
        case batteryLoaded(Result<BatteryStatus, any Error>)
        case firmwareLoaded(Result<DeviceFirmwareStatus, any Error>, keyboard: KeyboardID? = nil, generation: UInt64? = nil)
        case releaseLoaded(Result<FirmwareRelease?, any Error>, keyboard: KeyboardID? = nil, generation: UInt64? = nil)
        case keyboardUpdated(KeyboardSummary?)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// Shortcut buttons on the overview jump to another section.
            case show(KeyboardFeature.Section)
        }
    }

    enum CancelID { case refresh, battery, release }

    static let batteryInterval: Duration = .seconds(30)

    @Dependency(\.keyboardClient) var keyboardClient
    @Dependency(\.firmwareClient) var firmwareClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.diagnostics) var diagnostics

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // Tied to the view's lifetime: initial load, then a battery poll while the screen is visible.
                let initial: Effect<Action> = state.vendor == .idle ? .send(.refresh) : .none
                return .merge(
                    initial,
                    .run { send in
                        for await _ in clock.timer(interval: Self.batteryInterval) {
                            try Task.checkCancellation()
                            await send(.batteryTick)
                        }
                    }
                )

            case .refresh:
                guard state.isConnected else { return .none }
                let keyboard = state.keyboard
                guard let model = keyboard.model else {
                    state.vendor = .failed(CherryError.unsupportedModel.userMessage)
                    state.firmware = .failed(CherryError.unsupportedModel.userMessage)
                    return .none
                }
                if state.vendor.value == nil {
                    if !state.vendor.isLoading { state.pendingConfiguration = [] }
                    state.vendor = .loading
                }
                if state.firmware.value == nil { state.firmware = .loading }
                state.refreshError = nil
                let revision = state.configurationRevision
                state.loadGeneration &+= 1
                let generation = state.loadGeneration
                if state.latestRelease.value == nil { state.latestRelease = .loading }
                return .merge(
                    // Sequential: both channels are short-lived, and this keeps a single HID exchange in flight.
                    .run(origin: .deviceInfo) { send in
                        let span = diagnostics.begin(.refresh)
                        await TraceContext.$current.withValue(span.context) {
                            let vendor = await Result { try await keyboardClient.vendorSnapshot(keyboard) }
                            let firmware = await Result { try await keyboardClient.firmwareStatus(keyboard) }
                            if Task.isCancelled { span.finish(error: CancellationError()); return }
                            if case .failure(let error) = vendor { span.finish(error: error) }
                            else if case .failure(let error) = firmware { span.finish(error: error) }
                            else { span.finish() }
                            await send(.vendorLoaded(vendor, revision: revision, generation: generation))
                            await send(.firmwareLoaded(firmware, keyboard: keyboard.id, generation: generation))
                        }
                    }
                    .cancellable(id: CancelID.refresh, cancelInFlight: true),
                    .run(origin: .deviceInfo) { send in
                        let result = await Result { try await firmwareClient.latestRelease(model) }
                        guard !Task.isCancelled else { return }
                        await send(.releaseLoaded(result, keyboard: keyboard.id, generation: generation))
                    }
                    .cancellable(id: CancelID.release, cancelInFlight: true)
                )

            case .batteryTick:
                guard state.isConnected, state.keyboard.model != nil, !state.vendor.isLoading,
                      state.vendor.value != nil else { return .none }
                let keyboard = state.keyboard
                return .run(origin: .deviceInfo) { send in
                    let result = await Result { try await diagnostics.measure(.refresh) {
                        try await keyboardClient.battery(keyboard)
                    } }
                    guard !Task.isCancelled else { return }
                    await send(.batteryLoaded(result))
                }
                .cancellable(id: CancelID.battery, cancelInFlight: true)

            case .configurationSynchronized(let change):
                state.configurationRevision &+= 1
                if let current = state.vendor.value {
                    state.vendor = .loaded(current.with(configuration: change.applied(to: current.configuration)))
                } else if state.vendor.isLoading {
                    // 首次读取仍提供电量 / 状态；仅以最新读回覆盖其配置部分。
                    if case .configuration = change { state.pendingConfiguration = [change] }
                    else {
                        if case .profile(let profile) = change {
                            state.pendingConfiguration.removeAll {
                                if case .profile(let previous) = $0 { return previous.profile == profile.profile }
                                return false
                            }
                        }
                        state.pendingConfiguration.append(change)
                    }
                }
                return .none

            case .vendorLoaded(let result, let revision, let generation):
                guard generation == nil || generation == state.loadGeneration else { return .none }
                guard state.isConnected, revision == nil || revision == state.configurationRevision || state.vendor.value == nil else {
                    return .record(.resultIgnored, origin: .deviceInfo, outcome: .ignored, with: diagnostics)
                }
                switch result {
                case .success(var snapshot):
                    for change in state.pendingConfiguration {
                        snapshot = snapshot.with(configuration: change.applied(to: snapshot.configuration))
                    }
                    state.pendingConfiguration = []
                    state.vendor = .loaded(snapshot)
                    state.lastUpdated = now
                    state.refreshError = nil
                    return .record(.resultApplied, origin: .deviceInfo, outcome: .success, with: diagnostics)
                case .failure(let error):
                    if state.vendor.value == nil { state.vendor = .failed(error.userMessage) }
                    state.refreshError = error.userMessage
                    return .record(.resultApplied, origin: .deviceInfo, outcome: .failed, with: diagnostics)
                }

            case .batteryLoaded(.success(let battery)):
                guard state.isConnected else { return .none }
                if let v = state.vendor.value {
                    state.vendor = .loaded(v.with(battery: battery))
                    state.lastUpdated = now
                }
                return .none

            case .batteryLoaded(.failure):
                // A missed poll is not worth surfacing; the next tick or a manual refresh will retry.
                return .none

            case .firmwareLoaded(let result, let keyboard, let generation):
                guard generation == nil || generation == state.loadGeneration else { return .none }
                guard state.isConnected, keyboard == nil || keyboard == state.keyboard.id else { return .none }
                if case .failure = result, state.firmware.value != nil { return .none }
                state.firmware = Loadable(result)
                return .none

            case .releaseLoaded(let result, let keyboard, let generation):
                guard generation == nil || generation == state.loadGeneration else { return .none }
                guard state.isConnected, keyboard == nil || keyboard == state.keyboard.id else { return .none }
                if case .failure = result, state.latestRelease.value != nil { return .none }
                state.latestRelease = Loadable(result)
                return .none

            case .delegate:
                return .none

            case .keyboardUpdated(let keyboard):
                let wasConnected = state.isConnected
                state.isConnected = keyboard != nil
                if let keyboard { state.keyboard = keyboard }
                if !state.isConnected {
                    state.configurationRevision &+= 1
                    state.loadGeneration &+= 1
                    state.pendingConfiguration = []
                    return .merge(.cancel(id: CancelID.refresh), .cancel(id: CancelID.battery), .cancel(id: CancelID.release))
                }
                return wasConnected ? .none : .send(.refresh)
            }
        }
    }
}
