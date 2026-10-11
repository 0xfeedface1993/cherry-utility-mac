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

    @Test func rapidRevertAndDifferentFieldsKeepOnlyOnePendingIntent() async throws {
        let clock = TestClock(), log = PatchLog()
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.configurationClient.updateProfile = { n, _, patch in
                log.append(n, patch)
                try await clock.sleep(for: .seconds(1))
                return try ProfileConfig(profile: n, raw: KeyboardConfiguration.preview.profile(n)!.applying(patch))
            }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(0))
        await store.send(.setBrightness(1))
        await store.send(.setSpeed(0))
        await store.send(.setBrightness(VendorSnapshot.preview.profile.brightness))
        #expect(store.state.pendingWrites == 2)
        #expect(store.state.desiredSettings?.brightness == VendorSnapshot.preview.profile.brightness)
        #expect(store.state.desiredSettings?.speed == 0)
        await clock.advance(by: .seconds(1))
        await store.receive(\.writeFinished)
        await store.receive(\.delegate)
        await clock.advance(by: .seconds(1))
        await store.receive(\.writeFinished)
        await store.receive(\.delegate)
        #expect(log.all.count == 2)
        #expect(log.all.last?.patch.fields == [.brightness, .speed])
        #expect(store.state.currentSnapshot?.profile.brightness == VendorSnapshot.preview.profile.brightness)
        #expect(store.state.currentSnapshot?.profile.speed == 0)
        #expect(store.state.pendingWrites == 0)
    }

    @Test func rapidProfileRevertIsQueuedBeforeFirstActivationCompletes() async throws {
        let clock = TestClock()
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.configurationClient.activateProfile = { n, _ in
                try await clock.sleep(for: .seconds(1))
                return try KeyboardConfiguration(activeProfile: n, profiles: KeyboardConfiguration.preview.profiles)
            }
        }
        store.exhaustivity = .off
        await store.send(.activateProfile(0))
        await store.send(.activateProfile(2))
        await store.send(.activateProfile(KeyboardConfiguration.preview.activeProfile))
        #expect(store.state.pendingWrites == 2)
        await clock.advance(by: .seconds(1))
        await store.receive(\.activationFinished)
        await store.receive(\.delegate)
        await clock.advance(by: .seconds(1))
        await store.receive(\.activationFinished)
        await store.receive(\.delegate)
        #expect(store.state.currentSnapshot?.configuration.activeProfile == KeyboardConfiguration.preview.activeProfile)
        #expect(store.state.pendingWrites == 0)
    }

    @Test func unchangedReadBackDoesNotBroadcast() async {
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() }
        await store.send(.writeFinished(KeyboardSummary.preview.id, .success(KeyboardConfiguration.preview.active))) {
            $0.snapshotRevision = 1
        }
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
        await store.receive(\.delegate, .configurationChanged(old, .profile(KeyboardConfiguration.preview.active)))
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
