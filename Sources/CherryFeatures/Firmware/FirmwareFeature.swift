import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct FirmwareFeature: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case flashing(sent: Int, total: Int, percent: Int)
        case verifyingImage
        case waitingForReboot(FlashOutcome)
        case finished(outcome: FlashOutcome, firmware: DeviceFirmwareStatus, matches: Bool)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .flashing, .verifyingImage, .waitingForReboot: true
            default: false
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboard: KeyboardSummary
        public var isConnected = true
        public var latest: Loadable<FirmwareRelease?> = .idle
        public var package: Loadable<FirmwarePackage> = .idle
        public var deviceFirmware: Loadable<DeviceFirmwareStatus> = .idle
        public var phase: Phase = .idle
        public var isImporting = false
        @Presents public var alert: AlertState<Action.Alert>?

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
        }

        public var isBusy: Bool { phase.isBusy }

        public var incompatibilities: [String] {
            guard let package = package.value else { return [] }
            return FirmwareUpdateService.incompatibilities(of: package, with: keyboard)
        }

        /// true when the device already runs exactly the package's image.
        public var deviceMatchesPackage: Bool? {
            guard let package = package.value, let device = deviceFirmware.value else { return nil }
            return device.crc == package.image.embeddedCRC
        }

        /// Device reports the package's version number but a different image (e.g. a patched build).
        public var deviceRunsModifiedFirmware: Bool {
            guard deviceMatchesPackage == false, case .catalog(let release) = package.value?.source else { return false }
            return release.version == keyboard.firmwareVersion
        }

        public var canFlash: Bool {
            isConnected && !isBusy && package.value != nil && incompatibilities.isEmpty
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case refreshLatest
        case latestLoaded(Result<FirmwareRelease?, any Error>)
        case downloadTapped
        case importTapped
        case localFileSelected(Result<URL, any Error>)
        case packageLoaded(Result<FirmwarePackage, any Error>)
        case readDeviceFirmware
        case deviceFirmwareLoaded(Result<DeviceFirmwareStatus, any Error>)
        case flashTapped
        case flashProgress(FlashProgress)
        case flashFinished(Result<FlashOutcome, any Error>)
        case verifyFinished(outcome: FlashOutcome, Result<DeviceFirmwareStatus, any Error>)
        case keyboardUpdated(KeyboardSummary?)
        case alert(PresentationAction<Alert>)

        public enum Alert: Equatable, Sendable {
            case confirmFlash
        }
    }

    enum CancelID { case latest, package, device, flash }

    @Dependency(\.firmwareClient) var client

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                return state.latest == .idle ? .send(.refreshLatest) : .none

            case .refreshLatest:
                guard let model = state.keyboard.model else {
                    state.latest = .failed(CherryError.unsupportedModel.userMessage)
                    return .none
                }
                state.latest = .loading
                return .run { send in
                    await send(.latestLoaded(Result { try await client.latestRelease(model) }))
                }
                .cancellable(id: CancelID.latest, cancelInFlight: true)

            case .latestLoaded(let result):
                state.latest = Loadable(result)
                return .none

            case .downloadTapped:
                guard let release = state.latest.value ?? nil, !state.isBusy else { return .none }
                state.package = .loading
                return .run { send in
                    await send(.packageLoaded(Result { try await client.download(release) }))
                }
                .cancellable(id: CancelID.package, cancelInFlight: true)

            case .importTapped:
                guard !state.isBusy else { return .none }
                state.isImporting = true
                return .none

            case .localFileSelected(.success(let url)):
                guard !state.isBusy else { return .none }
                state.package = .loading
                return .run { send in
                    await send(.packageLoaded(Result { try await client.loadLocal(url) }))
                }
                .cancellable(id: CancelID.package, cancelInFlight: true)

            case .localFileSelected(.failure(let error)):
                guard !state.isBusy else { return .none }
                state.package = .failed(error.userMessage)
                return .none

            case .packageLoaded(let result):
                guard !state.isBusy else { return .none }
                state.package = Loadable(result)
                state.phase = .idle
                return state.package.value != nil ? .send(.readDeviceFirmware) : .none

            case .readDeviceFirmware:
                guard let package = state.package.value, state.isConnected, !state.isBusy,
                      state.keyboard.hasInterface(usagePage: package.image.usagePage) else { return .none }
                state.deviceFirmware = .loading
                let id = state.keyboard.id
                return .run { send in
                    await send(.deviceFirmwareLoaded(Result { try await client.deviceFirmware(id, package) }))
                }
                .cancellable(id: CancelID.device, cancelInFlight: true)

            case .deviceFirmwareLoaded(let result):
                state.deviceFirmware = Loadable(result)
                return .none

            case .flashTapped:
                guard state.canFlash, let package = state.package.value else { return .none }
                state.alert = Self.confirmation(
                    package: package, keyboard: state.keyboard, sameImage: state.deviceMatchesPackage == true,
                    replacesModified: state.deviceRunsModifiedFirmware
                )
                return .none

            case .alert(.presented(.confirmFlash)):
                guard state.canFlash, let package = state.package.value else { return .none }
                let keyboard = state.keyboard
                state.phase = .flashing(sent: 0, total: 0, percent: 0)
                // Not tied to any view and never cancelled from the UI: aborting mid-transfer only wastes the
                // attempt (the device keeps its old image), but there is no reason to offer it.
                return .run { send in
                    let result = await Result {
                        try await client.flash(keyboard, package) { progress in await send(.flashProgress(progress)) }
                    }
                    await send(.flashFinished(result))
                }
                .cancellable(id: CancelID.flash)

            case .alert:
                return .none

            case .flashProgress(let progress):
                switch progress {
                case .started(let total): state.phase = .flashing(sent: 0, total: total, percent: 0)
                case .transferred(let sent, let total, let percent): state.phase = .flashing(sent: sent, total: total, percent: percent)
                case .verifying: state.phase = .verifyingImage
                }
                return .none

            case .flashFinished(.success(let outcome)):
                guard let package = state.package.value else { return .none }
                state.phase = .waitingForReboot(outcome)
                let id = state.keyboard.id
                return .run { send in
                    await send(.verifyFinished(outcome: outcome, Result { try await client.verifyAfterFlash(id, package) }))
                }
                .cancellable(id: CancelID.flash)

            case .flashFinished(.failure(let error)):
                state.phase = .failed(error.userMessage)
                return .send(.readDeviceFirmware)

            case .verifyFinished(let outcome, .success(let firmware)):
                let matches = state.package.value.map { firmware.crc == $0.image.embeddedCRC } ?? false
                state.deviceFirmware = .loaded(firmware)
                state.phase = .finished(outcome: outcome, firmware: firmware, matches: matches)
                return .none

            case .verifyFinished(_, .failure(let error)):
                state.phase = .failed("刷写已完成，但重新读取设备固件失败：\(error.userMessage)")
                return .none

            case .keyboardUpdated(let keyboard):
                let wasConnected = state.isConnected
                state.isConnected = keyboard != nil
                if let keyboard { state.keyboard = keyboard }
                if state.isBusy { return .none }
                return !wasConnected && state.isConnected ? .send(.readDeviceFirmware) : .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    static func confirmation(
        package: FirmwarePackage, keyboard: KeyboardSummary, sameImage: Bool, replacesModified: Bool = false
    ) -> AlertState<Action.Alert> {
        AlertState {
            TextState(sameImage ? "设备已是该固件，确定重新刷写？" : "确定升级固件？")
        } actions: {
            ButtonState(role: .destructive, action: .confirmFlash) { TextState("开始升级") }
            ButtonState(role: .cancel) { TextState("取消") }
        } message: {
            TextState(
                "将向 \(keyboard.displayName) 写入 \(package.displayName)（\(package.image.firmware.count) 字节）。"
                    + (replacesModified ? "设备当前运行的是同版本号的修改版固件，刷写后将恢复为原厂镜像。" : "")
                    + "升级约需 30 秒，期间请勿拔线、断电或让电脑休眠。完成后键盘会自动重启。"
            )
        }
    }
}
