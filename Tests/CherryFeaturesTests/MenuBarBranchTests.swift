import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("菜单栏连续操作与设备上下文")
struct MenuBarBranchTests {
    static func loadedState() -> MenuBarFeature.State {
        var state = MenuBarFeature.State()
        state.keyboards = [.preview]
        state.snapshot = .loaded(.preview)
        state.snapshotID = KeyboardSummary.preview.id
        return state
    }

    @Test func rapidBrightnessRevertIsQueuedEvenBeforeFirstReadBack() async {
        var state = Self.loadedState()
        state.pendingWrites = 1 // 上一次亮度修改尚未读回，设备快照仍显示旧值。
        let log = PatchLog()
        let store = TestStore(initialState: state) { MenuBarFeature() } withDependencies: {
            $0.configurationClient.updateProfile = { n, _, patch in
                log.append(n, patch)
                return try ProfileConfig(profile: n, raw: KeyboardConfiguration.preview.profile(n)!.applying(patch))
            }
        }
        await store.send(.setBrightness(VendorSnapshot.preview.profile.brightness)) { $0.pendingWrites = 2 }
        await store.receive(\.writeFinished) { $0.pendingWrites = 1 }
        await store.receive(\.delegate)
        #expect(log.all.count == 1 && log.all.first?.patch.fields == [.brightness])
    }

    @Test func rapidProfileRevertIsQueuedBeforeFirstActivationCompletes() async throws {
        var state = Self.loadedState()
        state.pendingWrites = 1
        let store = TestStore(initialState: state) { MenuBarFeature() } withDependencies: {
            $0.configurationClient.activateProfile = { n, _ in
                try KeyboardConfiguration(activeProfile: n, profiles: KeyboardConfiguration.preview.profiles)
            }
        }
        await store.send(.activateProfile(KeyboardConfiguration.preview.activeProfile)) { $0.pendingWrites = 2 }
        await store.receive(\.activationFinished) { $0.pendingWrites = 1 }
        await store.receive(\.delegate)
    }

    @Test func oldKeyboardWriteFailureDoesNotChangeCurrentKeyboardError() async {
        var state = Self.loadedState()
        state.pendingWrites = 1
        state.errorMessage = "当前设备的错误"
        let old = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 2)
        let store = TestStore(initialState: state) { MenuBarFeature() }
        await store.send(.writeFinished(old, .failure(CherryError.disconnected))) { $0.pendingWrites = 0 }
    }

    @Test func oldKeyboardActivationFailureDoesNotChangeCurrentKeyboardError() async {
        var state = Self.loadedState()
        state.pendingWrites = 1
        state.errorMessage = "当前设备的错误"
        let old = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 2)
        let store = TestStore(initialState: state) { MenuBarFeature() }
        await store.send(.activationFinished(old, .failure(CherryError.disconnected))) { $0.pendingWrites = 0 }
    }

    @Test func oldKeyboardWriteSuccessPreservesCurrentErrorAndNotifiesParent() async {
        var state = Self.loadedState()
        state.pendingWrites = 1
        state.errorMessage = "当前设备的错误"
        let old = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 2)
        let store = TestStore(initialState: state) { MenuBarFeature() }
        await store.send(.writeFinished(old, .success(KeyboardConfiguration.preview.active))) { $0.pendingWrites = 0 }
        await store.receive(\.delegate, .configurationChanged(old))
    }

    @Test func quickControlsWriteOnlyIntendedFields() async {
        let log = PatchLog()
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.configurationClient.updateProfile = { n, _, patch in
                log.append(n, patch)
                return try ProfileConfig(profile: n, raw: KeyboardConfiguration.preview.profile(n)!.applying(patch))
            }
        }
        store.exhaustivity = .off
        let actions: [(MenuBarFeature.Action, Set<ProfileField>)] = [
            (.setEffect(2), [.effect]), (.setSpeed(0), [.speed]),
            (.setColor(LEDColor(r: 1, g: 2, b: 3)), [.color, .randomColor]), (.setRandomColor, [.randomColor]),
        ]
        for (action, fields) in actions {
            await store.send(action)
            await store.receive(\.writeFinished)
            await store.receive(\.delegate)
            #expect(log.all.last?.profile == KeyboardConfiguration.preview.activeProfile)
            #expect(log.all.last?.patch.fields == fields)
            #expect(store.state.pendingWrites == 0)
        }
        #expect(log.all.count == 4)
    }

    @Test func staleSnapshotsAndUnknownPresetAreIgnored() async {
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() }
        let old = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 2)
        await store.send(.snapshotLoaded(old, .success(.preview)))
        await store.send(.snapshotLoaded(old, .failure(CherryError.disconnected)))
        await store.send(.applyPreset(UUID()))
    }
}
