import CherryCore
import ComposableArchitecture
import Foundation
import Synchronization
import Testing
@testable import CherryFeatures

/// Records the patches a fake keyboard receives.
final class PatchLog: Sendable {
    private let entries = Mutex<[(profile: Int, patch: ProfilePatch)]>([])
    func append(_ profile: Int, _ patch: ProfilePatch) { entries.withLock { $0.append((profile, patch)) } }
    var all: [(profile: Int, patch: ProfilePatch)] { entries.withLock { $0 } }
}

private let base = KeyboardConfiguration.preview.active.settings

@Suite("ProfileEditor draft editing")
struct ProfileEditorTests {
    @Test func dirtyClearsWhenDraftReturnsToBase() {
        var editor = ProfileEditor(base: base)
        editor.edit { $0.brightness = 1 }
        #expect(editor.dirty == [.brightness])
        editor.edit { $0.brightness = base.brightness }
        #expect(editor == .viewing(base: base))
        #expect(!editor.hasUnsavedChanges)
    }

    @Test func unrelatedRemoteUpdateKeepsDirtyDraft() {
        var editor = ProfileEditor(base: base)
        editor.edit { $0.effect = 2 }
        editor.rebase(onto: base) // same values re-read (e.g. a poll)
        #expect(editor.draft.effect == 2 && editor.dirty == [.effect])
    }

    @Test func remoteUpdateMergesButPreservesDirtyFields() {
        var editor = ProfileEditor(base: base)
        editor.edit { $0.effect = 2 }
        var remote = base
        remote.effect = 18 // changed elsewhere too, but the user's edit wins
        remote.brightness = 1 // changed elsewhere only
        editor.rebase(onto: remote)
        #expect(editor.base == remote)
        #expect(editor.draft.effect == 2 && editor.draft.brightness == 1)
        #expect(editor.dirty == [.effect])
    }

    @Test func remoteUpdateEqualToDraftClearsDirty() {
        var editor = ProfileEditor(base: base)
        editor.edit { $0.speed = 0 }
        var remote = base
        remote.speed = 0
        editor.rebase(onto: remote)
        #expect(editor == .viewing(base: remote))
    }

    @Test func saveSendsOnlyDirtyFieldsAndFailurePreservesDraft() {
        var editor = ProfileEditor(base: base)
        editor.edit { $0.brightness = 1 }
        editor.edit { $0.sleepSeconds = 120 }
        let patch = editor.beginSave()
        #expect(patch?.fields == [.brightness, .sleepSeconds])
        #expect(editor.isSaving)
        editor.edit { $0.effect = 2 } // 保存期间继续编辑
        #expect(editor.draft.effect == 2)
        #expect(editor.beginSave() == nil) // no second save while one is running
        editor.saveFailed()
        #expect(!editor.isSaving && editor.dirty == [.brightness, .sleepSeconds, .effect] && editor.draft.sleepSeconds == 120)
    }

    @Test func nothingToSaveReturnsNil() {
        var editor = ProfileEditor(base: base)
        #expect(editor.beginSave() == nil)
        #expect(!editor.isSaving)
    }

    @Test func discardRestoresBase() {
        var editor = ProfileEditor(base: base)
        editor.edit { $0.color = LEDColor(r: 1, g: 2, b: 3) }
        _ = editor.beginSave()
        editor.discard()
        #expect(editor == .viewing(base: base))
    }
}

@MainActor
@Suite("ConfigurationFeature")
struct ConfigurationFeatureTests {
    static func loadedState() -> ConfigurationFeature.State {
        var state = ConfigurationFeature.State(keyboard: .preview)
        state.configuration = .loaded(.preview)
        state.selectedProfile = 1
        state.editor = ProfileEditor(base: base)
        state.presets = .loaded([.preview])
        return state
    }

    @Test func firstLoadSelectsActiveProfile() async {
        let store = TestStore(initialState: ConfigurationFeature.State(keyboard: .preview)) {
            ConfigurationFeature()
        } withDependencies: {
            $0.configurationClient.configuration = { _ in .preview }
            $0.presetClient.presets = { [.preview] }
        }
        await store.send(.task) { $0.presets = .loading }
        await store.receive(\.refresh) { $0.configuration = .loading; $0.loadGeneration = 1 }
        await store.receive(\.presetsLoaded) { $0.presets = .loaded([.preview]) }
        await store.receive(\.configurationLoaded) {
            $0.configuration = .loaded(.preview)
            $0.selectedProfile = 1
            $0.editor = ProfileEditor(base: base)
        }
    }

    @Test func saveWritesOnlyDirtyFieldsToSelectedProfile() async {
        let log = PatchLog()
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.configurationClient.updateProfile = { n, _, patch in
                log.append(n, patch)
                return try ProfileConfig(profile: n, raw: KeyboardConfiguration.preview.profile(n)!.applying(patch))
            }
        }
        store.exhaustivity = .off

        await store.send(.selectProfile(2))
        await store.send(.edit(.brightness(1)))
        await store.send(.edit(.color(LEDColor(r: 0, g: 0x99, b: 0xFF))))
        await store.send(.saveTapped)
        await store.receive(\.saveFinished)
        await store.receive(\.delegate)

        #expect(log.all.count == 1)
        #expect(log.all.first?.profile == 2)
        #expect(log.all.first?.patch.fields == [.brightness, .color])
        #expect(store.state.editor?.hasUnsavedChanges == false)
        #expect(store.state.configuration.value?.profile(2)?.brightness == 1)
        #expect(store.state.banner?.isError == false)
    }

    @Test func failedSaveKeepsDraftAndDirtySet() async {
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.configurationClient.updateProfile = { _, _, _ in throw CherryError.disconnected }
        }
        store.exhaustivity = .off
        await store.send(.edit(.speed(0)))
        await store.send(.saveTapped)
        await store.receive(\.saveFinished)
        #expect(store.state.editor?.dirty == [.speed])
        #expect(store.state.editor?.draft.speed == 0)
        #expect(store.state.isSaving == false)
        #expect(store.state.banner?.isError == true)
    }

    @Test func discardDuringSaveCancelsAndRereadsKeyboard() async {
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.configurationClient.updateProfile = { _, _, _ in try await Task.never() }
            $0.configurationClient.configuration = { _ in .preview }
        }
        store.exhaustivity = .off
        await store.send(.edit(.effect(2)))
        await store.send(.saveTapped)
        #expect(store.state.isSaving)
        await store.send(.discardTapped)
        #expect(store.state.editor == ProfileEditor(base: base))
        await store.receive(\.refresh)
        await store.receive(\.configurationLoaded)
        await store.finish()
    }

    @Test func remoteChangeWhileEditingKeepsUserEdits() async {
        var changed = KeyboardConfiguration.preview.active.raw
        changed[2] = 1 // brightness changed from the menu bar
        changed[1] = 18
        let remote = KeyboardConfiguration.preview.replacing(try! ProfileConfig(profile: 1, raw: changed))
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.configurationClient.configuration = { _ in remote }
        }
        store.exhaustivity = .off
        await store.send(.edit(.effect(2)))
        await store.send(.refresh)
        await store.receive(\.configurationLoaded)
        #expect(store.state.editor?.draft.effect == 2)
        #expect(store.state.editor?.draft.brightness == 1)
        #expect(store.state.editor?.dirty == [.effect])
    }

    @Test func switchingProfilesWithUnsavedChangesAsksFirst() async {
        let store = TestStore(initialState: Self.loadedState()) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.edit(.brightness(0)))
        await store.send(.selectProfile(0))
        #expect(store.state.selectedProfile == 1)
        #expect(store.state.alert != nil)
        await store.send(.alert(.presented(.discardAndSelect(0))))
        #expect(store.state.selectedProfile == 0)
        #expect(store.state.editor == ProfileEditor(base: KeyboardConfiguration.preview.profile(0)!.settings))
    }

    @Test func activatingProfileUpdatesConfigurationAndNotifiesParent() async {
        let activated = try! KeyboardConfiguration(activeProfile: 2, profiles: KeyboardConfiguration.preview.profiles)
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.configurationClient.activateProfile = { _, _ in activated }
        }
        await store.send(.activateProfile(2)) { $0.activatingProfile = 2; $0.activationGeneration = 1 }
        await store.receive(\.activationFinished) {
            $0.configurationRevision += 1
            $0.activatingProfile = nil
            $0.configuration = .loaded(activated)
            $0.banner = .init(message: "已切换到配置 3", isError: false)
        }
        await store.receive(\.delegate, .configurationChanged(KeyboardSummary.preview.id, .configuration(activated)))
    }

    @Test func loadingPresetFillsDraftWithoutWriting() async {
        let store = TestStore(initialState: Self.loadedState()) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.loadPresetTapped(ProfilePreset.preview.id))
        #expect(store.state.editor?.draft == ProfilePreset.preview.settings)
        #expect(store.state.hasUnsavedChanges)
    }

    @Test func presetFromOtherModelIsRefused() async {
        var state = Self.loadedState()
        var foreign = ProfilePreset.preview
        foreign.productID = 0x0001
        state.presets = .loaded([foreign])
        let store = TestStore(initialState: state) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.loadPresetTapped(foreign.id))
        #expect(store.state.hasUnsavedChanges == false)
        #expect(store.state.banner?.isError == true)
    }

    /// 默认名称是界面文案：未填写名称时由 Feature 按当前时间生成，Core 只接收非空名称。
    @Test func savingPresetWithoutNameUsesTimestampedDefault() async {
        let names = Mutex<[String]>([])
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.date.now = now
            $0.presetClient.save = { name, settings, keyboard in
                names.withLock { $0.append(name) }
                return ProfilePreset(name: name, createdAt: now, productID: keyboard.id.productID, settings: settings)
            }
        }
        store.exhaustivity = .off
        await store.send(.binding(.set(\.presetName, "  \n ")))
        await store.send(.savePresetTapped)
        await store.receive(\.presetSaved)
        await store.send(.binding(.set(\.presetName, "  游戏 ")))
        await store.send(.savePresetTapped)
        await store.receive(\.presetSaved)
        #expect(names.withLock { $0 } == ["预设 \(now.formatted(date: .numeric, time: .shortened))", "游戏"])
    }

    @Test func savingPresetUsesDraftAndPrependsIt() async {
        let saved = Mutex<ProfileSettings?>(nil)
        let store = TestStore(initialState: Self.loadedState()) {
            ConfigurationFeature()
        } withDependencies: {
            $0.presetClient.save = { name, settings, keyboard in
                saved.withLock { $0 = settings }
                return ProfilePreset(name: name, createdAt: Date(timeIntervalSince1970: 0), productID: keyboard.id.productID, settings: settings)
            }
        }
        store.exhaustivity = .off
        await store.send(.edit(.brightness(2)))
        await store.send(.binding(.set(\.presetName, "办公")))
        await store.send(.savePresetTapped)
        await store.receive(\.presetSaved)
        #expect(saved.withLock { $0 }?.brightness == 2)
        #expect(store.state.presets.value?.first?.name == "办公")
        #expect(store.state.presetName.isEmpty)
    }
}

@MainActor
@Suite("MenuBarFeature")
struct MenuBarFeatureTests {
    @Test func newKeyboardTriggersStatusRead() async {
        let store = TestStore(initialState: MenuBarFeature.State()) {
            MenuBarFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.date.now = Date(timeIntervalSince1970: 10)
        }
        await store.send(.keyboardsUpdated([.preview])) {
            $0.keyboards = [.preview]
            $0.snapshotRevision += 1
            $0.label = .init(isConnected: true, batteryText: nil, accessibilityValue: "—")
        }
        await store.receive(\.refresh) { $0.snapshot = .loading }
        await store.receive(\.snapshotLoaded) {
            $0.snapshot = .loaded(.preview)
            $0.snapshotID = KeyboardSummary.preview.id
            $0.lastUpdated = Date(timeIntervalSince1970: 10)
            $0.label = .init(isConnected: true, batteryText: "95%", accessibilityValue: "95%")
        }
        #expect(store.state.labelText == "95%")
        #expect(store.state.lightingPresentation?.profiles.first(where: \.isActive)?.id == 1)
    }

    @Test func quickBrightnessWritesOnlyThatFieldToActiveProfile() async {
        let log = PatchLog()
        var state = MenuBarFeature.State()
        state.keyboards = [.preview]
        state.snapshot = .loaded(.preview)
        state.snapshotID = KeyboardSummary.preview.id
        let store = TestStore(initialState: state) {
            MenuBarFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.configurationClient.applyIntent = { intent, _ in
                for (profile, patch) in intent.patches { log.append(profile, patch) }
                return intent.applied(to: .preview)
            }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(1))
        await store.receive(\.intentFinished)
        await store.receive(\.delegate, .configurationChanged(KeyboardSummary.preview.id, .configuration(store.state.currentSnapshot!.configuration)))
        #expect(log.all.map(\.profile) == [1])
        #expect(log.all.first?.patch.fields == [.brightness])
        #expect(store.state.currentSnapshot?.profile.brightness == 1)

        // Same value again: nothing to write.
        await store.send(.setBrightness(1))
        #expect(log.all.count == 1)
    }

    @Test func pollTicksRefreshUntilCancelled() async {
        let clock = TestClock()
        var state = MenuBarFeature.State()
        state.keyboards = [.preview]
        let store = TestStore(initialState: state) {
            MenuBarFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        let task = await store.send(.task)
        await clock.advance(by: MenuBarFeature.pollInterval)
        await store.receive(\.tick)
        await store.receive(\.refresh)
        await store.receive(\.snapshotLoaded)
        await task.cancel()
    }

    @Test func failedReadShowsInputMonitoringHint() async {
        var state = MenuBarFeature.State()
        state.keyboards = [.preview]
        let store = TestStore(initialState: state) {
            MenuBarFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.keyboardClient.vendorSnapshot = { _ in throw CherryError.accessDenied }
        }
        store.exhaustivity = .off
        await store.send(.refresh)
        await store.receive(\.snapshotLoaded)
        #expect(store.state.needsInputMonitoring)
    }
}

@MainActor
@Suite("AppFeature menu-bar wiring")
struct AppMenuBarWiringTests {
    @Test func menuBarReadBackSynchronizesWithoutIOAndPreservesDraft() async throws {
        var state = AppFeature.State()
        state.keyboards = [.preview]
        var detail = KeyboardFeature.State(keyboard: .preview)
        detail.configuration = ConfigurationFeatureTests.loadedState()
        detail.configuration.editor?.edit { $0.brightness = 0 }
        detail.info.vendor = .loaded(.preview)
        state.detail = detail
        let saved = try ProfileConfig(profile: 1, raw: KeyboardConfiguration.preview.active.applying(
            .set(\.speed, 0, field: .speed, on: KeyboardConfiguration.preview.active.settings)))
        let store = TestStore(initialState: state) { AppFeature() }
        store.exhaustivity = .off
        // 所有 I/O 依赖保留 TestDependency 未实现状态；出现读取即失败。
        await store.send(.menuBar(.delegate(.configurationChanged(KeyboardSummary.preview.id, .profile(saved)))))
        await store.finish()
        await store.skipReceivedActions()
        #expect(store.state.detail?.info.vendor.value?.profile.speed == 0)
        #expect(store.state.detail?.configuration.editor?.draft.brightness == 0)
        #expect(store.state.detail?.configuration.editor?.draft.speed == 0)
        #expect(store.state.detail?.configuration.hasUnsavedChanges == true)
    }

    @Test func startIsIdempotent() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.keyboardClient.updates = { AsyncStream { $0.finish() } }
            $0.configurationChangeClient.changes = { AsyncStream { $0.finish() } }
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off
        let first = await store.send(.task)
        await store.send(.task)
        #expect(store.state.hasStarted)
        await first.cancel()
    }
}
