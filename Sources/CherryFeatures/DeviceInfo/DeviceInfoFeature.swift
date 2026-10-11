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
        case vendorLoaded(Result<VendorSnapshot, any Error>)
        case batteryLoaded(Result<BatteryStatus, any Error>)
        case firmwareLoaded(Result<DeviceFirmwareStatus, any Error>)
        case releaseLoaded(Result<FirmwareRelease?, any Error>)
        case keyboardUpdated(KeyboardSummary?)
    }

    enum CancelID { case refresh, battery, release }

    static let batteryInterval: Duration = .seconds(30)

    @Dependency(\.keyboardClient) var keyboardClient
    @Dependency(\.firmwareClient) var firmwareClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now

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
                state.vendor = .loading
                state.firmware = .loading
                if state.latestRelease.value == nil { state.latestRelease = .loading }
                return .merge(
                    // Sequential: both channels are short-lived, and this keeps a single HID exchange in flight.
                    .run { send in
                        await send(.vendorLoaded(Result { try await keyboardClient.vendorSnapshot(keyboard) }))
                        await send(.firmwareLoaded(Result { try await keyboardClient.firmwareStatus(keyboard) }))
                    }
                    .cancellable(id: CancelID.refresh, cancelInFlight: true),
                    .run { send in
                        await send(.releaseLoaded(Result { try await firmwareClient.latestRelease(model) }))
                    }
                    .cancellable(id: CancelID.release, cancelInFlight: true)
                )

            case .batteryTick:
                guard state.isConnected, state.keyboard.model != nil, !state.vendor.isLoading,
                      state.vendor.value != nil else { return .none }
                let keyboard = state.keyboard
                return .run { send in
                    await send(.batteryLoaded(Result { try await keyboardClient.battery(keyboard) }))
                }
                .cancellable(id: CancelID.battery, cancelInFlight: true)

            case .vendorLoaded(let result):
                guard state.isConnected else { return .none }
                state.vendor = Loadable(result)
                state.lastUpdated = now
                return .none

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

            case .firmwareLoaded(let result):
                guard state.isConnected else { return .none }
                state.firmware = Loadable(result)
                return .none

            case .releaseLoaded(let result):
                state.latestRelease = Loadable(result)
                return .none

            case .keyboardUpdated(let keyboard):
                let wasConnected = state.isConnected
                state.isConnected = keyboard != nil
                if let keyboard { state.keyboard = keyboard }
                if !state.isConnected {
                    return .merge(.cancel(id: CancelID.refresh), .cancel(id: CancelID.battery))
                }
                return wasConnected ? .none : .send(.refresh)
            }
        }
    }
}
