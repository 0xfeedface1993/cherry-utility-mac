import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("保存期间继续编辑与合并提交")
struct ConfigurationQueuedSaveTests {
    @Test func revertDuringSaveSurvivesRemoteReadBack() {
        let base = KeyboardConfiguration.preview.active.settings
        var editor = ProfileEditor(base: base)
        editor.edit { $0.brightness = 0 }
        let patch = editor.beginSave()!
        editor.edit { $0.brightness = base.brightness }
        editor.rebase(onto: patch.applied(to: base))
        #expect(editor.draft.brightness == base.brightness)
        editor.saveSucceeded(patch.applied(to: base))
        #expect(editor.draft.brightness == base.brightness && editor.dirty == [.brightness])
    }

    @Test func repeatedSubmissionMergesAndLaterUnsubmittedEditsStayDirty() async {
        let clock = TestClock(), log = PatchLog()
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() } withDependencies: {
            $0.configurationClient.updateProfile = { n, _, patch in
                log.append(n, patch)
                try await clock.sleep(for: .seconds(1))
                return try ProfileConfig(profile: n, raw: KeyboardConfiguration.preview.profile(n)!.applying(patch))
            }
        }
        store.exhaustivity = .off
        await store.send(.edit(.brightness(0)))
        await store.send(.saveTapped)
        #expect(store.state.isSaving && store.state.canEdit)
        await store.send(.edit(.brightness(1)))
        await store.send(.saveTapped)
        await store.send(.edit(.speed(0)))
        await store.send(.saveTapped)
        await store.send(.edit(.brightness(4)))
        await store.send(.saveTapped)
        await store.send(.edit(.color(.init(r: 1, g: 2, b: 3)))) // 不提交的修改不能被自动写入。
        await clock.advance(by: .seconds(1))
        await store.receive(\.saveFinished)
        await store.receive(\.delegate)
        #expect(store.state.isSaving && store.state.canEdit)
        await clock.advance(by: .seconds(1))
        await store.receive(\.saveFinished)
        await store.receive(\.delegate)
        #expect(log.all.count == 2)
        #expect(log.all.last?.patch.fields == [.brightness, .speed])
        #expect(log.all.last?.patch.values?.brightness == 4)
        #expect(store.state.editor?.draft.color == .init(r: 1, g: 2, b: 3))
        #expect(store.state.editor?.dirty == [.color])
        #expect(!store.state.isSaving)
    }

    @Test func discardedAndDisconnectedSaveResultsCannotRecreateDraft() async throws {
        var state = ConfigurationFeatureTests.loadedState()
        state.saveGeneration = 2
        let saved = try ProfileConfig(profile: 1, raw: KeyboardConfiguration.preview.active.applying(.set(\.brightness, 0, field: .brightness, on: KeyboardConfiguration.preview.active.settings)))
        let store = TestStore(initialState: state) { ConfigurationFeature() }
        await store.send(.saveFinished(.success(saved), generation: 1))
        #expect(!store.state.hasUnsavedChanges)
        store.exhaustivity = .off
        await store.send(.keyboardUpdated(nil))
        await store.send(.saveFinished(.success(saved), generation: 2))
        #expect(store.state.configuration.value == .preview)
    }

    @Test func repeatedActivationsKeepLatestSelectionWithoutDisablingEditor() async {
        let clock = TestClock()
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() } withDependencies: {
            $0.configurationClient.activateProfile = { n, _ in
                try await clock.sleep(for: .seconds(1))
                return ConfigurationIntent.activate(n).applied(to: .preview)
            }
        }
        store.exhaustivity = .off
        await store.send(.activateProfile(0))
        await store.send(.activateProfile(2))
        await store.send(.activateProfile(1))
        #expect(store.state.activeProfile == 1 && store.state.canEdit)
        #expect(store.state.tabsPresentation.isEnabled)
        await clock.advance(by: .seconds(1))
        await store.receive(\.activationFinished)
        await store.receive(\.delegate)
        #expect(store.state.activeProfile == 1)
        await clock.advance(by: .seconds(1))
        await store.receive(\.activationFinished)
        await store.receive(\.delegate)
        #expect(store.state.configuration.value?.activeProfile == 1)
    }
}
