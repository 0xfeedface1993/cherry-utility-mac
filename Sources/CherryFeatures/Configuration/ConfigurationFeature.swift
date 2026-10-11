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
        var configurationRevision: UInt64 = 0
        var loadGeneration: UInt64 = 0
        var pendingProfiles: [Int: ProfileConfig] = [:]
        public var selectedProfile: Int?
        public var editor: ProfileEditor?
        public var activatingProfile: Int?
        var queuedActivation: Int?
        var savingPatch: ProfilePatch?
        var queuedSave: ProfilePatch?
        var saveGeneration: UInt64 = 0
        var activationGeneration: UInt64 = 0
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
        public var activeProfile: Int? { queuedActivation ?? activatingProfile ?? configuration.value?.activeProfile }
        public var selectedConfig: ProfileConfig? { selectedProfile.flatMap { configuration.value?.profile($0) } }
        public var isSaving: Bool { editor?.isSaving ?? false }
        public var hasUnsavedChanges: Bool { editor?.hasUnsavedChanges ?? false }
        public var isBusy: Bool { isSaving || activatingProfile != nil }
        public var canEdit: Bool { isConnected && keyboard.canConfigure && editor != nil }
        public var canSubmit: Bool {
            guard canEdit, let editor else { return false }
            if let submitted = queuedSave ?? savingPatch {
                return editor.draft != submitted.applied(to: editor.base)
            }
            return hasUnsavedChanges
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case refresh
        case configurationLoaded(Result<KeyboardConfiguration, any Error>, revision: UInt64? = nil, generation: UInt64? = nil)
        case configurationSynchronized(ConfigurationChange)
        case keyboardUpdated(KeyboardSummary?)
        case selectProfile(Int)
        case activateProfile(Int)
        case activationFinished(Result<KeyboardConfiguration, any Error>, generation: UInt64? = nil)
        case edit(Edit)
        case saveTapped
        case saveFinished(Result<ProfileConfig, any Error>, generation: UInt64? = nil)
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
            case configurationChanged(KeyboardID, ConfigurationChange)
        }
    }

    enum CancelID { case load, save, activate, presets }

    @Dependency(\.configurationClient) var client
    @Dependency(\.presetClient) var presetClient
    @Dependency(\.date.now) var now

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
                if state.configuration.value == nil {
                    if !state.configuration.isLoading { state.pendingProfiles = [:] }
                    state.configuration = .loading
                }
                let keyboard = state.keyboard
                let revision = state.configurationRevision
                state.loadGeneration &+= 1
                let generation = state.loadGeneration
                return .run(origin: .configuration) { send in
                    let result = await Result { try await client.configuration(keyboard) }
                    guard !Task.isCancelled else { return }
                    await send(.configurationLoaded(result, revision: revision, generation: generation))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case .configurationSynchronized(let change):
                state.configurationRevision &+= 1
                if let current = state.configuration.value {
                    state.configuration = .loaded(change.applied(to: current))
                    syncEditor(&state)
                    return .cancel(id: CancelID.load)
                }
                if state.configuration.isLoading {
                    switch change {
                    case .profile(let profile): state.pendingProfiles[profile.profile] = profile
                    case .configuration(let configuration):
                        state.configuration = .loaded(configuration)
                        state.pendingProfiles = [:]
                        syncEditor(&state)
                        return .cancel(id: CancelID.load)
                    }
                }
                return .none

            case .configurationLoaded(.success(let configuration), let revision, let generation):
                guard generation == nil || generation == state.loadGeneration else { return .none }
                guard state.isConnected, revision == nil || revision == state.configurationRevision || state.configuration.value == nil else { return .none }
                let merged = state.pendingProfiles.values.reduce(configuration) { $0.replacing($1) }
                state.pendingProfiles = [:]
                state.configuration = .loaded(merged)
                syncEditor(&state)
                return .none

            case .configurationLoaded(.failure(let error), let revision, let generation):
                guard generation == nil || generation == state.loadGeneration else { return .none }
                guard state.isConnected, revision == nil || revision == state.configurationRevision || state.configuration.value == nil else { return .none }
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
                if !state.isConnected {
                    state.loadGeneration &+= 1
                    state.saveGeneration &+= 1
                    state.activationGeneration &+= 1
                    state.pendingProfiles = [:]
                    state.savingPatch = nil
                    state.queuedSave = nil
                    state.activatingProfile = nil
                    state.queuedActivation = nil
                    state.editor?.saveFailed()
                    return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.save), .cancel(id: CancelID.activate))
                }
                return wasConnected ? .none : .send(.refresh)

            case .selectProfile(let n):
                guard n != state.selectedProfile else { return .none }
                if state.hasUnsavedChanges || state.isSaving {
                    state.alert = Self.discardAlert(switchingTo: n)
                    return .none
                }
                select(n, in: &state)
                return .none

            case .activateProfile(let n):
                guard state.isConnected, state.keyboard.canConfigure, (0..<state.profileCount).contains(n),
                      n != state.activeProfile else { return .none }
                if state.activatingProfile != nil {
                    state.queuedActivation = n
                    return .none
                }
                return startActivation(n, state: &state)

            case .activationFinished(.success(let configuration), let generation):
                guard generation == nil || generation == state.activationGeneration, state.isConnected else { return .none }
                state.configurationRevision &+= 1
                state.activatingProfile = nil
                state.configuration = .loaded(configuration)
                syncEditor(&state)
                state.banner = Banner(message: "已切换到配置 \(configuration.activeProfile + 1)", isError: false)
                return .merge(startQueuedActivation(&state), .send(.delegate(.configurationChanged(state.keyboard.id, .configuration(configuration)))))

            case .activationFinished(.failure(let error), let generation):
                guard generation == nil || generation == state.activationGeneration, state.isConnected else { return .none }
                state.activatingProfile = nil
                state.banner = Banner(message: "切换配置失败：\(error.userMessage)", isError: true)
                return .merge(startQueuedActivation(&state), .send(.refresh))

            case .edit(let edit):
                guard state.canEdit else { return .none }
                state.editor?.edit { edit.apply(to: &$0) }
                return .none

            case .saveTapped:
                guard state.canSubmit, let editor = state.editor else { return .none }
                if state.isSaving {
                    // 改回原始值也必须提交，否则第一次写入仍会留下旧意图。
                    let fields = editor.dirty.union(state.savingPatch?.fields ?? []).union(state.queuedSave?.fields ?? [])
                    state.queuedSave = ProfilePatch(editor.draft, fields: fields)
                    return .none
                }
                return startSave(&state)

            case .saveFinished(.success(let saved), let generation):
                guard generation == nil || generation == state.saveGeneration, state.isConnected else { return .none }
                state.configurationRevision &+= 1
                if let configuration = state.configuration.value {
                    state.configuration = .loaded(configuration.replacing(saved))
                }
                if saved.profile == state.selectedProfile {
                    state.editor?.saveSucceeded(saved.settings)
                }
                state.savingPatch = nil
                state.banner = Banner(message: "已写入配置 \(saved.profile + 1)", isError: false)
                return .merge(startQueuedSave(&state), .send(.delegate(.configurationChanged(state.keyboard.id, .profile(saved)))))

            case .saveFinished(.failure(let error), let generation):
                guard generation == nil || generation == state.saveGeneration, state.isConnected else { return .none }
                state.editor?.saveFailed()
                state.savingPatch = nil
                state.banner = Banner(message: "写入失败：\(error.userMessage)", isError: true)
                return startQueuedSave(&state)

            case .discardTapped:
                let wasSaving = state.isSaving
                state.saveGeneration &+= 1
                state.savingPatch = nil
                state.queuedSave = nil
                state.editor?.discard()
                // A cancelled save may or may not have reached the keyboard: re-read what it holds.
                return wasSaving ? .merge(.cancel(id: CancelID.save), .send(.refresh)) : .none

            case .presetsLoaded(let result):
                state.presets = Loadable(result)
                return .none

            case .savePresetTapped:
                guard let settings = state.editor?.draft else { return .none }
                // 默认名称属于界面文案：未填写时按当前时间生成。
                let typed = state.presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = typed.isEmpty ? "预设 \(now.formatted(date: .numeric, time: .shortened))" : typed
                let keyboard = state.keyboard
                return .run(origin: .configuration) { send in
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
                return .run(origin: .configuration) { send in
                    await send(.presetDeleted(Result { try await presetClient.delete(id); return id }))
                }

            case .alert(.presented(.discardAndSelect(let n))):
                let wasSaving = state.isSaving
                state.saveGeneration &+= 1
                state.savingPatch = nil
                state.queuedSave = nil
                state.editor?.discard()
                select(n, in: &state)
                return wasSaving ? .merge(.cancel(id: CancelID.save), .send(.refresh)) : .none

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
                return .run(origin: .configuration) { send in
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
        return .run(origin: .configuration) { send in
            await send(.presetsLoaded(Result { try await presetClient.presets() }))
        }
        .cancellable(id: CancelID.presets, cancelInFlight: true)
    }

    private func startSave(_ state: inout State, including fields: Set<ProfileField> = []) -> Effect<Action> {
        guard let profile = state.selectedProfile, let patch = state.editor?.beginSave(including: fields) else { return .none }
        state.savingPatch = patch
        state.saveGeneration &+= 1
        let generation = state.saveGeneration
        let keyboard = state.keyboard
        return .run(origin: .configuration) { send in
            let result = await Result { try await client.updateProfile(profile, keyboard, patch) }
            guard !Task.isCancelled else { return }
            await send(.saveFinished(result, generation: generation))
        }.cancellable(id: CancelID.save)
    }

    private func startActivation(_ n: Int, state: inout State) -> Effect<Action> {
        state.activatingProfile = n
        state.activationGeneration &+= 1
        let generation = state.activationGeneration
        let keyboard = state.keyboard
        return .run(origin: .configuration) { send in
            let result = await Result { try await client.activateProfile(n, keyboard) }
            guard !Task.isCancelled else { return }
            await send(.activationFinished(result, generation: generation))
        }.cancellable(id: CancelID.activate)
    }

    private func startQueuedActivation(_ state: inout State) -> Effect<Action> {
        guard let profile = state.queuedActivation else { return .none }
        state.queuedActivation = nil
        return startActivation(profile, state: &state)
    }

    private func startQueuedSave(_ state: inout State) -> Effect<Action> {
        guard let queued = state.queuedSave else { return .none }
        state.queuedSave = nil
        // 使用再次提交时冻结的值；提交后产生的草稿修改仍保留，不能被自动写入。
        guard let profile = state.selectedProfile else { return .none }
        let submitted = state.editor.map { queued.applied(to: $0.base) }
        _ = state.editor?.beginSave(including: queued.fields, submitted: submitted)
        state.savingPatch = queued
        state.saveGeneration &+= 1
        let generation = state.saveGeneration
        let keyboard = state.keyboard
        return .run(origin: .configuration) { send in
            let result = await Result { try await client.updateProfile(profile, keyboard, queued) }
            guard !Task.isCancelled else { return }
            await send(.saveFinished(result, generation: generation))
        }.cancellable(id: CancelID.save)
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
