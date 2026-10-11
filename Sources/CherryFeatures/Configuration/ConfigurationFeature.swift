import CherryCore
import ComposableArchitecture
import Foundation

/// "灯效与配置" screen: onboard profiles, lighting / sleep editing with save & discard, and the local preset library.
@Reducer
public struct ConfigurationFeature: Sendable {
    public enum Edit: Equatable, Sendable {
        case effect(UInt8)
        case brightness(Int)
        case speed(Int)
        case randomColor(Bool)
        case color(LEDColor)
        case sleepSeconds(Int)
        case deepSleepMinutes(Int)

        func apply(to s: inout ProfileSettings) {
            switch self {
            case .effect(let v): s.effect = v
            case .brightness(let v): s.brightness = v
            case .speed(let v): s.speed = v
            case .randomColor(let v): s.randomColor = v
            case .color(let v): s.color = v
            case .sleepSeconds(let v): s.sleepSeconds = v
            case .deepSleepMinutes(let v): s.deepSleepMinutes = v
            }
        }
    }

    public struct Banner: Equatable, Sendable {
        public let message: String
        public let isError: Bool
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboard: KeyboardSummary
        public var isConnected = true
        public var configuration: Loadable<KeyboardConfiguration> = .idle
        /// Profile shown in the editor (not necessarily the active one).
        public var selectedProfile: Int?
        public var editor: ProfileEditor?
        public var activatingProfile: Int?
        public var presets: Loadable<[ProfilePreset]> = .idle
        public var presetName = ""
        public var banner: Banner?
        public var isImporting = false
        public var exportingPreset: ProfilePreset?
        @Presents public var alert: AlertState<Action.Alert>?

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
        }

        public var model: KeyboardModel? { keyboard.model }
        public var effects: [LightingEffect] { model?.lightingEffects ?? [] }
        public var profileCount: Int { model?.profileCount ?? 0 }
        public var activeProfile: Int? { configuration.value?.activeProfile }
        public var selectedConfig: ProfileConfig? { selectedProfile.flatMap { configuration.value?.profile($0) } }
        public var isSaving: Bool { editor?.isSaving ?? false }
        public var hasUnsavedChanges: Bool { editor?.hasUnsavedChanges ?? false }
        public var isBusy: Bool { isSaving || activatingProfile != nil }
        public var canEdit: Bool { isConnected && editor != nil && !isBusy }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case refresh
        case configurationLoaded(Result<KeyboardConfiguration, any Error>)
        case keyboardUpdated(KeyboardSummary?)
        case selectProfile(Int)
        case activateProfile(Int)
        case activationFinished(Result<KeyboardConfiguration, any Error>)
        case edit(Edit)
        case saveTapped
        case saveFinished(Result<ProfileConfig, any Error>)
        case discardTapped
        case presetsLoaded(Result<[ProfilePreset], any Error>)
        case savePresetTapped
        case presetSaved(Result<ProfilePreset, any Error>)
        case loadPresetTapped(ProfilePreset.ID)
        case deletePresetTapped(ProfilePreset.ID)
        case presetDeleted(Result<ProfilePreset.ID, any Error>)
        case importTapped
        case importFileSelected(Result<URL, any Error>)
        case presetImported(Result<ProfilePreset, any Error>)
        case exportTapped(ProfilePreset.ID)
        case exportFinished(Result<URL, any Error>)
        case dismissBanner
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {
            case confirmDelete(ProfilePreset.ID)
            case discardAndSelect(Int)
        }

        public enum Delegate: Equatable, Sendable {
            /// The keyboard's configuration was changed from this screen.
            case configurationChanged(KeyboardID)
        }
    }

    enum CancelID { case load, save, activate, presets }

    @Dependency(\.configurationClient) var client
    @Dependency(\.presetClient) var presetClient

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                let load: Effect<Action> = state.configuration == .idle ? .send(.refresh) : .none
                let presets: Effect<Action> = state.presets == .idle ? loadPresets(&state) : .none
                return .merge(load, presets)

            case .refresh:
                guard state.isConnected else { return .none }
                guard state.model != nil else {
                    state.configuration = .failed(CherryError.unsupportedModel.userMessage)
                    return .none
                }
                if state.configuration.value == nil { state.configuration = .loading }
                let keyboard = state.keyboard
                return .run { send in
                    await send(.configurationLoaded(Result { try await client.configuration(keyboard) }))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case .configurationLoaded(.success(let configuration)):
                state.configuration = .loaded(configuration)
                syncEditor(&state)
                return .none

            case .configurationLoaded(.failure(let error)):
                // Keep showing the last good values; only a first load turns into an error screen.
                if state.configuration.value == nil {
                    state.configuration = .failed(error.userMessage)
                } else {
                    state.banner = Banner(message: "刷新失败：\(error.userMessage)", isError: true)
                }
                return .none

            case .keyboardUpdated(let keyboard):
                let wasConnected = state.isConnected
                state.isConnected = keyboard != nil
                if let keyboard { state.keyboard = keyboard }
                if !state.isConnected { return .cancel(id: CancelID.load) }
                return wasConnected ? .none : .send(.refresh)

            case .selectProfile(let n):
                guard n != state.selectedProfile, !state.isBusy else { return .none }
                if state.hasUnsavedChanges {
                    state.alert = Self.discardAlert(switchingTo: n)
                    return .none
                }
                select(n, in: &state)
                return .none

            case .activateProfile(let n):
                guard state.isConnected, !state.isBusy, n != state.activeProfile else { return .none }
                state.activatingProfile = n
                let keyboard = state.keyboard
                return .run { send in
                    await send(.activationFinished(Result { try await client.activateProfile(n, keyboard) }))
                }
                .cancellable(id: CancelID.activate)

            case .activationFinished(.success(let configuration)):
                state.activatingProfile = nil
                state.configuration = .loaded(configuration)
                syncEditor(&state)
                state.banner = Banner(message: "已切换到配置 \(configuration.activeProfile + 1)", isError: false)
                return .send(.delegate(.configurationChanged(state.keyboard.id)))

            case .activationFinished(.failure(let error)):
                state.activatingProfile = nil
                state.banner = Banner(message: "切换配置失败：\(error.userMessage)", isError: true)
                return .send(.refresh)

            case .edit(let edit):
                guard state.canEdit else { return .none }
                state.editor?.edit { edit.apply(to: &$0) }
                return .none

            case .saveTapped:
                guard state.isConnected, let profile = state.selectedProfile,
                      let patch = state.editor?.beginSave() else { return .none }
                let keyboard = state.keyboard
                return .run { send in
                    await send(.saveFinished(Result { try await client.updateProfile(profile, keyboard, patch) }))
                }
                .cancellable(id: CancelID.save)

            case .saveFinished(.success(let saved)):
                if let configuration = state.configuration.value {
                    state.configuration = .loaded(configuration.replacing(saved))
                }
                if saved.profile == state.selectedProfile {
                    state.editor?.saveSucceeded(saved.settings)
                }
                state.banner = Banner(message: "已写入配置 \(saved.profile + 1)", isError: false)
                return .send(.delegate(.configurationChanged(state.keyboard.id)))

            case .saveFinished(.failure(let error)):
                state.editor?.saveFailed()
                state.banner = Banner(message: "写入失败：\(error.userMessage)", isError: true)
                return .none

            case .discardTapped:
                let wasSaving = state.isSaving
                state.editor?.discard()
                // A cancelled save may or may not have reached the keyboard: re-read what it holds.
                return wasSaving ? .merge(.cancel(id: CancelID.save), .send(.refresh)) : .none

            case .presetsLoaded(let result):
                state.presets = Loadable(result)
                return .none

            case .savePresetTapped:
                guard let settings = state.editor?.draft else { return .none }
                let name = state.presetName
                let keyboard = state.keyboard
                return .run { send in
                    await send(.presetSaved(Result { try await presetClient.save(name, settings, keyboard) }))
                }

            case .presetSaved(.success(let preset)):
                state.presetName = ""
                state.presets = .loaded([preset] + (state.presets.value ?? []).filter { $0.id != preset.id })
                state.banner = Banner(message: "已保存预设「\(preset.name)」", isError: false)
                return .none

            case .presetSaved(.failure(let error)), .presetImported(.failure(let error)):
                state.banner = Banner(message: error.userMessage, isError: true)
                return .none

            case .loadPresetTapped(let id):
                guard state.canEdit, let preset = state.presets.value?.first(where: { $0.id == id }) else { return .none }
                guard preset.isCompatible(with: state.keyboard) else {
                    state.banner = Banner(message: "预设「\(preset.name)」来自其他型号，无法载入", isError: true)
                    return .none
                }
                state.editor?.replaceDraft(with: preset.settings)
                state.banner = Banner(
                    message: state.hasUnsavedChanges
                        ? "已载入预设「\(preset.name)」，点击「写入键盘」后生效"
                        : "预设「\(preset.name)」与当前配置相同",
                    isError: false
                )
                return .none

            case .deletePresetTapped(let id):
                guard let preset = state.presets.value?.first(where: { $0.id == id }) else { return .none }
                state.alert = Self.deleteAlert(preset)
                return .none

            case .alert(.presented(.confirmDelete(let id))):
                return .run { send in
                    await send(.presetDeleted(Result { try await presetClient.delete(id); return id }))
                }

            case .alert(.presented(.discardAndSelect(let n))):
                state.editor?.discard()
                select(n, in: &state)
                return .none

            case .alert:
                return .none

            case .presetDeleted(.success(let id)):
                state.presets = .loaded((state.presets.value ?? []).filter { $0.id != id })
                return .none

            case .presetDeleted(.failure(let error)):
                state.banner = Banner(message: "删除失败：\(error.userMessage)", isError: true)
                return .none

            case .importTapped:
                state.isImporting = true
                return .none

            case .importFileSelected(.success(let url)):
                return .run { send in
                    await send(.presetImported(Result { try await presetClient.importFile(url) }))
                }

            case .importFileSelected(.failure(let error)):
                state.banner = Banner(message: "导入失败：\(error.userMessage)", isError: true)
                return .none

            case .presetImported(.success(let preset)):
                state.presets = .loaded([preset] + (state.presets.value ?? []))
                state.banner = Banner(message: "已导入预设「\(preset.name)」", isError: false)
                return .none

            case .exportTapped(let id):
                state.exportingPreset = state.presets.value?.first { $0.id == id }
                return .none

            case .exportFinished(let result):
                state.exportingPreset = nil
                switch result {
                case .success(let url): state.banner = Banner(message: "已导出到 \(url.lastPathComponent)", isError: false)
                case .failure(let error): state.banner = Banner(message: "导出失败：\(error.userMessage)", isError: true)
                }
                return .none

            case .dismissBanner:
                state.banner = nil
                return .none

            case .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func loadPresets(_ state: inout State) -> Effect<Action> {
        state.presets = .loading
        return .run { send in
            await send(.presetsLoaded(Result { try await presetClient.presets() }))
        }
        .cancellable(id: CancelID.presets, cancelInFlight: true)
    }

    /// Points the editor at the selected profile (the active one by default) after the configuration changed.
    private func syncEditor(_ state: inout State) {
        guard let configuration = state.configuration.value else { return }
        let n = state.selectedProfile.flatMap { configuration.profile($0) != nil ? $0 : nil } ?? configuration.activeProfile
        guard let remote = configuration.profile(n)?.settings else { return }
        if n == state.selectedProfile, state.editor != nil {
            state.editor?.rebase(onto: remote)
        } else {
            state.selectedProfile = n
            state.editor = ProfileEditor(base: remote)
        }
    }

    private func select(_ n: Int, in state: inout State) {
        guard let config = state.configuration.value?.profile(n) else { return }
        state.selectedProfile = n
        state.editor = ProfileEditor(base: config.settings)
    }

    static func deleteAlert(_ preset: ProfilePreset) -> AlertState<Action.Alert> {
        AlertState {
            TextState("删除预设「\(preset.name)」？")
        } actions: {
            ButtonState(role: .destructive, action: .confirmDelete(preset.id)) { TextState("删除") }
            ButtonState(role: .cancel) { TextState("取消") }
        } message: {
            TextState("只会删除这台 Mac 上保存的预设，不影响键盘上的配置。")
        }
    }

    static func discardAlert(switchingTo n: Int) -> AlertState<Action.Alert> {
        AlertState {
            TextState("放弃未写入的修改？")
        } actions: {
            ButtonState(role: .destructive, action: .discardAndSelect(n)) { TextState("放弃并切换") }
            ButtonState(role: .cancel) { TextState("继续编辑") }
        } message: {
            TextState("当前配置档还有修改没有写入键盘。")
        }
    }
}
