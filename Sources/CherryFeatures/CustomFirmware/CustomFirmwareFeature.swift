import CherryCore
import ComposableArchitecture
import Foundation

@Reducer
public struct CustomFirmwareFeature: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case flashing(sent: Int, total: Int, percent: Int)
        case verifyingImage
        case waitingForReboot
        /// The keyboard came back with exactly the expected image.
        case finished(target: String, status: DeviceFirmwareStatus)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .preparing, .flashing, .verifyingImage, .waitingForReboot: true
            case .idle, .finished, .failed: false
            }
        }
    }

    public struct Library: Equatable, Sendable {
        public var variants: [FirmwareVariant]
        public var records: [FirmwareFlashRecord]

        public init(variants: [FirmwareVariant], records: [FirmwareFlashRecord]) {
            self.variants = variants
            self.records = records
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var keyboard: KeyboardSummary
        public var isConnected = true
        public var catalog: Loadable<DefinitionCatalog> = .idle
        public var definitionID: String?
        public var stock: Loadable<FirmwarePackage> = .idle
        public var library: Loadable<Library> = .idle
        public var device: Loadable<DeviceFirmwareStatus> = .idle
        public var selectedVariantID: UUID?
        public var editor: VariantEditor?
        /// The image being flashed (prepared, awaiting confirmation, or in flight).
        public var install: CustomFirmwareInstall?
        public var phase: Phase = .idle
        /// Last failure of a variant operation (create, save, delete).
        public var notice: String?
        public var isImporting = false
        @Presents public var alert: AlertState<Action.Alert>?

        public init(keyboard: KeyboardSummary) {
            self.keyboard = keyboard
        }

        public var isBusy: Bool { phase.isBusy }

        /// Definitions for this keyboard's model, newest firmware first.
        public var definitions: [FirmwareDefinition] {
            guard let model = keyboard.model else { return [] }
            return catalog.value?.definitions(for: model) ?? []
        }

        public var definition: FirmwareDefinition? { definitions.first { $0.id == definitionID } }

        /// Variants of the selected definition, oldest first.
        public var variants: [FirmwareVariant] {
            guard let definitionID else { return [] }
            return (library.value?.variants ?? []).filter { $0.definitionID == definitionID }
        }

        public var installed: InstalledFirmware? {
            guard let status = device.value, let catalog = catalog.value else { return nil }
            return InstalledFirmware.identify(
                crc: status.crc, definitions: catalog.definitions,
                variants: library.value?.variants ?? [], records: library.value?.records ?? []
            )
        }

        public var hasOTAInterface: Bool {
            keyboard.model?.ota.map { keyboard.hasInterface(usagePage: $0.usagePage) } ?? false
        }

        /// Selections of the edited variant that the definition does not know.
        public var unknownSelections: [String] {
            guard let definition, let editor else { return [] }
            return definition.resolve(editor.draft.selections).unknown
        }

        public var canInstall: Bool {
            guard let editor else { return false }
            return canRestore && !editor.hasUnsavedChanges && !editor.isSaving && unknownSelections.isEmpty
        }

        public var canRestore: Bool {
            isConnected && !isBusy && hasOTAInterface && definition != nil && stock.value != nil
        }

        mutating func select(_ id: UUID?) {
            selectedVariantID = id
            editor = variants.first { $0.id == id }.map(VariantEditor.init)
        }

        mutating func replaceVariant(_ variant: FirmwareVariant) {
            guard var library = library.value else { return }
            if let index = library.variants.firstIndex(where: { $0.id == variant.id }) {
                library.variants[index] = variant
            } else {
                library.variants.append(variant)
            }
            self.library = .loaded(library)
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case catalogLoaded(Result<DefinitionCatalog, any Error>)
        case reloadLibrary
        case libraryLoaded(Result<Library, any Error>)
        case readDevice
        case deviceLoaded(Result<DeviceFirmwareStatus, any Error>)
        case selectDefinition(String)
        case fetchStockTapped
        case importStockTapped
        case stockFileSelected(Result<URL, any Error>)
        case stockLoaded(definitionID: String, Result<FirmwarePackage, any Error>)
        case selectVariant(UUID?)
        case newVariantTapped
        case duplicateVariantTapped
        case deleteVariantTapped
        case variantCreated(Result<FirmwareVariant, any Error>)
        case variantDeleted(Result<UUID, any Error>)
        case nameChanged(String)
        case optionChanged(optionID: String, valueID: String)
        case removeUnknownSelectionsTapped
        case discardTapped
        case saveTapped
        case variantSaved(Result<FirmwareVariant, any Error>)
        case installTapped
        case restoreStockTapped
        case installPrepared(Result<CustomFirmwareInstall, any Error>)
        case flashProgress(FlashProgress)
        case flashFinished(Result<FlashOutcome, any Error>)
        case verifyFinished(Result<DeviceFirmwareStatus, any Error>)
        case keyboardUpdated(KeyboardSummary?)
        case alert(PresentationAction<Alert>)

        public enum Alert: Equatable, Sendable {
            case confirmInstall
            case confirmDelete(UUID)
            case discardAndSelect(UUID?)
        }
    }

    enum CancelID { case catalog, library, device, stock, variant, flash }

    @Dependency(\.customFirmwareClient) var client

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Every appearance re-reads the keyboard (another page may have flashed it); failed loads are retried.
                var effects: [Effect<Action>] = [.send(.readDevice)]
                if state.catalog == .idle || state.catalog.errorMessage != nil {
                    state.catalog = .loading
                    effects.append(.run(origin: .firmware) { send in
                        await send(.catalogLoaded(Result { try await client.loadDefinitions() }))
                    }
                    .cancellable(id: CancelID.catalog, cancelInFlight: true))
                }
                if state.library == .idle || state.library.errorMessage != nil { effects.append(.send(.reloadLibrary)) }
                return .merge(effects)

            case .catalogLoaded(let result):
                state.catalog = Loadable(result)
                if state.definition == nil {
                    state.definitionID = state.definitions.first?.id
                    state.select(state.variants.first?.id)
                }
                return .none

            case .reloadLibrary:
                if state.library.value == nil { state.library = .loading }
                return .run(origin: .firmware) { send in
                    await send(.libraryLoaded(Result { Library(variants: try await client.variants(), records: try await client.flashRecords()) }))
                }
                .cancellable(id: CancelID.library, cancelInFlight: true)

            case .libraryLoaded(.success(let library)):
                state.library = .loaded(library)
                if let editor = state.editor, let saved = library.variants.first(where: { $0.id == editor.base.id }) {
                    var rebased = editor
                    if !editor.isSaving { rebased.rebase(onto: saved) }
                    state.editor = rebased
                } else {
                    let keep = state.variants.contains { $0.id == state.selectedVariantID }
                    state.select(keep ? state.selectedVariantID : state.variants.first?.id)
                }
                return .none

            case .libraryLoaded(.failure(let error)):
                state.library = .failed(error.userMessage)
                return .none

            case .readDevice:
                guard state.isConnected, !state.isBusy else { return .none }
                guard state.hasOTAInterface else {
                    state.device = .failed(CustomFirmwarePresentation.needsWiredConnection)
                    return .none
                }
                state.device = .loading
                let keyboard = state.keyboard
                return .run(origin: .firmware) { send in
                    await send(.deviceLoaded(Result { try await client.deviceFirmware(keyboard) }))
                }
                .cancellable(id: CancelID.device, cancelInFlight: true)

            case .deviceLoaded(let result):
                state.device = Loadable(result)
                return .none

            case .selectDefinition(let id):
                guard !state.isBusy, id != state.definitionID, state.definitions.contains(where: { $0.id == id }) else { return .none }
                state.definitionID = id
                state.stock = .idle
                state.install = nil
                state.select(state.variants.first?.id)
                return .cancel(id: CancelID.stock)

            case .fetchStockTapped:
                guard let definition = state.definition, !state.isBusy, !state.stock.isLoading else { return .none }
                state.stock = .loading
                return .run(origin: .firmware) { send in
                    await send(.stockLoaded(definitionID: definition.id, Result { try await client.stockPackage(definition) }))
                }
                .cancellable(id: CancelID.stock, cancelInFlight: true)

            case .importStockTapped:
                guard state.definition != nil, !state.isBusy else { return .none }
                state.isImporting = true
                return .none

            case .stockFileSelected(.success(let url)):
                guard let definition = state.definition, !state.isBusy else { return .none }
                state.stock = .loading
                return .run(origin: .firmware) { send in
                    await send(.stockLoaded(definitionID: definition.id, Result { try await client.importStock(definition, url) }))
                }
                .cancellable(id: CancelID.stock, cancelInFlight: true)

            case .stockFileSelected(.failure(let error)):
                state.stock = .failed(error.userMessage)
                return .none

            case .stockLoaded(let definitionID, let result):
                guard definitionID == state.definitionID else { return .none }
                state.stock = Loadable(result)
                return .none

            case .selectVariant(let id):
                guard !state.isBusy, id != state.selectedVariantID else { return .none }
                if state.editor?.hasUnsavedChanges == true {
                    state.alert = CustomFirmwarePresentation.discardAlert(selecting: id)
                    return .none
                }
                state.select(id)
                return .none

            case .newVariantTapped, .duplicateVariantTapped:
                guard let definition = state.definition, !state.isBusy, state.editor?.isSaving != true else { return .none }
                let source: FirmwareVariant? = if case .duplicateVariantTapped = action { state.editor?.base } else { nil }
                if case .duplicateVariantTapped = action, source == nil { return .none }
                let name = source.map { CustomFirmwarePresentation.copyName(of: $0.name, existing: state.variants) }
                    ?? CustomFirmwarePresentation.newVariantName(existing: state.variants)
                state.notice = nil
                return .run(origin: .firmware) { send in
                    await send(.variantCreated(Result { try await client.createVariant(name, definition, source) }))
                }
                .cancellable(id: CancelID.variant)

            case .variantCreated(.success(let variant)):
                state.replaceVariant(variant)
                if state.editor?.hasUnsavedChanges != true { state.select(variant.id) }
                return .none

            case .deleteVariantTapped:
                guard let id = state.selectedVariantID, !state.isBusy else { return .none }
                state.alert = CustomFirmwarePresentation.deleteAlert(state.editor?.base.name ?? "", id: id)
                return .none

            case .variantDeleted(.success(let id)):
                if var library = state.library.value {
                    library.variants.removeAll { $0.id == id }
                    state.library = .loaded(library)
                }
                if state.selectedVariantID == id { state.select(state.variants.first?.id) }
                return .none

            case .variantCreated(.failure(let error)), .variantDeleted(.failure(let error)):
                state.notice = error.userMessage
                return .none

            case .nameChanged(let name):
                guard !state.isBusy else { return .none }
                state.editor?.setName(name)
                return .none

            case .optionChanged(let optionID, let valueID):
                guard !state.isBusy, let option = state.definition?.option(optionID) else { return .none }
                state.editor?.select(valueID, for: option)
                return .none

            case .removeUnknownSelectionsTapped:
                guard !state.isBusy, let definition = state.definition else { return .none }
                state.editor?.removeUnknownSelections(in: definition)
                return .none

            case .discardTapped:
                state.editor?.discard()
                return .none

            case .saveTapped:
                guard !state.isBusy, let definition = state.definition, var editor = state.editor,
                      let variant = editor.beginSave() else { return .none }
                state.editor = editor
                state.notice = nil
                let stock = state.stock.value
                return .run(origin: .firmware) { send in
                    await send(.variantSaved(Result { try await client.saveVariant(variant, definition, stock) }))
                }
                .cancellable(id: CancelID.variant)

            case .variantSaved(.success(let saved)):
                state.replaceVariant(saved)
                if state.editor?.base.id == saved.id { state.editor?.saveSucceeded(saved) }
                return .none

            case .variantSaved(.failure(let error)):
                state.editor?.saveFailed()
                state.notice = error.userMessage
                return .none

            case .installTapped, .restoreStockTapped:
                let restoring = if case .restoreStockTapped = action { true } else { false }
                guard restoring ? state.canRestore : state.canInstall,
                      let definition = state.definition, let stock = state.stock.value else { return .none }
                let variant = restoring ? nil : state.editor?.base
                state.phase = .preparing
                return .run(origin: .firmware) { send in
                    await send(.installPrepared(Result { try await client.prepareInstall(variant, definition, stock) }))
                }
                .cancellable(id: CancelID.flash)

            case .installPrepared(.success(let install)):
                state.phase = .idle
                state.install = install
                state.alert = CustomFirmwarePresentation.installAlert(
                    install, keyboard: state.keyboard, sameImage: state.device.value?.crc == install.expectedCRC
                )
                return .none

            case .installPrepared(.failure(let error)):
                state.phase = .failed(error.userMessage)
                return .none

            case .alert(.presented(.confirmInstall)):
                guard let install = state.install, state.isConnected, state.hasOTAInterface, !state.isBusy else { return .none }
                let keyboard = state.keyboard
                state.phase = .flashing(sent: 0, total: 0, percent: 0)
                // Never cancelled from the UI: aborting only wastes the attempt, the keyboard keeps its image.
                return .run(origin: .firmware) { send in
                    let result = await Result { try await client.flash(install, keyboard) { await send(.flashProgress($0)) } }
                    await send(.flashFinished(result))
                }
                .cancellable(id: CancelID.flash)

            case .alert(.presented(.confirmDelete(let id))):
                return .run(origin: .firmware) { send in
                    await send(.variantDeleted(Result { try await client.deleteVariant(id); return id }))
                }
                .cancellable(id: CancelID.variant)

            case .alert(.presented(.discardAndSelect(let id))):
                state.editor?.discard()
                state.select(id)
                return .none

            case .alert(.dismiss):
                if !state.isBusy { state.install = nil }
                return .none

            case .alert:
                return .none

            case .flashProgress(let progress):
                switch progress {
                case .started(let total): state.phase = .flashing(sent: 0, total: total, percent: 0)
                case .transferred(let sent, let total, let percent): state.phase = .flashing(sent: sent, total: total, percent: percent)
                case .verifying: state.phase = .verifyingImage
                }
                return .none

            case .flashFinished(.success):
                guard let install = state.install else { return .none }
                state.phase = .waitingForReboot
                let id = state.keyboard.id
                return .run(origin: .firmware) { send in
                    await send(.verifyFinished(Result { try await client.verify(install, id) }))
                }
                .cancellable(id: CancelID.flash)

            case .flashFinished(.failure(let error)):
                state.phase = .failed(error.userMessage)
                state.install = nil
                return .send(.readDevice)

            case .verifyFinished(.success(let status)):
                state.device = .loaded(status)
                state.phase = .finished(target: state.install.map(CustomFirmwarePresentation.targetName) ?? "", status: status)
                state.install = nil
                return .send(.reloadLibrary)

            case .verifyFinished(.failure(let error)):
                state.phase = .failed(CustomFirmwarePresentation.verificationFailed(error.userMessage))
                state.install = nil
                return .merge(.send(.reloadLibrary), .send(.readDevice))

            case .keyboardUpdated(let keyboard):
                let wasConnected = state.isConnected
                state.isConnected = keyboard != nil
                if let keyboard { state.keyboard = keyboard }
                if state.isBusy { return .none }
                return !wasConnected && state.isConnected ? .send(.readDevice) : .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
