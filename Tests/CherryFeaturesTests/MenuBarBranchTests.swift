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
    static var second: KeyboardSummary {
        let first = KeyboardSummary.preview
        return .init(id: .init(vendorID: first.id.vendorID, productID: first.id.productID, locationID: 2), product: first.product, manufacturer: first.manufacturer, serialNumber: nil, transport: first.transport, releaseNumber: first.releaseNumber, interfaces: first.interfaces)
    }

    @Test func profileAndLightingStayEnabledAndTrackLatestIntentDuringSlowWrites() async throws {
        let clock = TestClock()
        let log = PatchLog()
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.configurationClient.applyIntent = { intent, _ in
                for (profile, patch) in intent.patches { log.append(profile, patch) }
                try await clock.sleep(for: .seconds(1))
                return intent.applied(to: .preview)
            }
        }
        store.exhaustivity = .off
        await store.send(.activateProfile(0))
        #expect(store.state.lightingPresentation?.profiles.first(where: \.isActive)?.id == 0)
        await store.send(.setBrightness(1))
        await store.send(.activateProfile(2))
        await store.send(.setEffect(2))
        #expect(store.state.desiredConfiguration?.activeProfile == 2)
        #expect(store.state.desiredConfiguration?.profile(0)?.brightness == 1)
        #expect(store.state.desiredSettings?.effect == 2)
        #expect(store.state.lightingPresentation?.isEnabled == true)
        #expect(store.state.lightingPresentation?.isProfileEnabled == true)
        #expect(store.state.pendingWrites == 4)
        #expect(log.all.map(\.profile) == [0, 2])
        await clock.advance(by: .seconds(1))
        await store.finish()
        await store.skipReceivedActions()
        #expect(!store.state.isApplying)
    }

    @Test func rapidRevertIsAnIntentEvenWhileDeviceStillHasOriginalValue() async {
        let clock = TestClock()
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.configurationClient.applyIntent = { intent, _ in
                try await clock.sleep(for: .seconds(1))
                return intent.applied(to: .preview)
            }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(0))
        await store.send(.setBrightness(4))
        await store.send(.activateProfile(0))
        await store.send(.activateProfile(1))
        #expect(store.state.pendingWrites == 4)
        #expect(store.state.desiredSettings?.brightness == 4)
        #expect(store.state.desiredConfiguration?.activeProfile == 1)
        await clock.advance(by: .seconds(1))
        await store.finish()
        await store.skipReceivedActions()
    }

    @Test func lateEarlierCompletionCannotOverrideNewerConfirmedConfiguration() async throws {
        var state = Self.loadedState()
        let oldID = UUID(), newerID = UUID(), keyboard = KeyboardSummary.preview.id
        state.requests = [
            .init(id: oldID, keyboardID: keyboard, intent: .activate(0), sequence: 1),
            .init(id: newerID, keyboardID: keyboard, intent: .activate(2), sequence: 2),
        ]
        let store = TestStore(initialState: state) { MenuBarFeature() }
        store.exhaustivity = .off
        await store.send(.intentFinished(newerID, keyboard, .success(ConfigurationIntent.activate(2).applied(to: .preview))))
        await store.receive(\.delegate)
        #expect(store.state.desiredConfiguration?.activeProfile == 2)
        await store.send(.intentFinished(oldID, keyboard, .success(ConfigurationIntent.activate(0).applied(to: .preview))))
        #expect(store.state.currentSnapshot?.configuration.activeProfile == 2)
        #expect(!store.state.isApplying)
    }

    @Test func twoDevicesRejectOldSnapshotsAndKeepWritesBoundToTheirDevice() async {
        var state = Self.loadedState()
        state.keyboards.append(Self.second)
        let clock = TestClock()
        let store = TestStore(initialState: state) { MenuBarFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.configurationClient.applyIntent = { intent, _ in
                try await clock.sleep(for: .seconds(1))
                return intent.applied(to: .preview)
            }
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(0))
        await store.send(.selectKeyboard(Self.second.id))
        await store.receive(\.refresh)
        await store.receive(\.snapshotLoaded)
        #expect(store.state.keyboard?.id == Self.second.id && !store.state.isApplying)
        #expect(store.state.desiredSettings?.brightness == 4)
        await store.send(.snapshotLoaded(KeyboardSummary.preview.id, .success(.preview)))
        #expect(store.state.snapshotID == Self.second.id)
        await clock.advance(by: .seconds(1))
        await store.receive(\.intentFinished)
        await store.receive(\.delegate)
        #expect(store.state.desiredSettings?.brightness == 4)
    }

    @Test func disconnectInvalidatesControlsAndOldWriteEvenAfterSameIDReconnects() async {
        let clock = TestClock()
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.configurationClient.applyIntent = { intent, _ in
                try await clock.sleep(for: .seconds(1))
                return intent.applied(to: .preview)
            }
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(0))
        await store.send(.keyboardsUpdated([]))
        await store.receive(\.refresh)
        #expect(store.state.keyboard == nil && store.state.currentSnapshot == nil)
        #expect(store.state.lightingPresentation == nil && !store.state.canConfigure)
        await store.send(.activateProfile(0))
        await store.send(.setEffect(2))
        #expect(store.state.pendingWrites == 0)
        await store.send(.keyboardsUpdated([.preview]))
        await store.receive(\.refresh)
        await store.receive(\.snapshotLoaded)
        await clock.advance(by: .seconds(1))
        await store.receive(\.intentFinished)
        #expect(store.state.desiredSettings?.brightness == 4)
    }

    @Test func lossOfVendorInterfaceDisablesConfigurationWithoutShowingUnknownMetadata() async {
        let first = KeyboardSummary.preview
        let partial = KeyboardSummary(id: first.id, product: first.product, manufacturer: first.manufacturer, serialNumber: nil, transport: "USB", releaseNumber: first.releaseNumber, interfaces: [])
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() }
        store.exhaustivity = .off
        await store.send(.keyboardsUpdated([partial]))
        await store.receive(\.refresh)
        #expect(store.state.lightingPresentation == nil && !store.state.canConfigure)
        #expect(store.state.statusPresentation?.connection == "USB")
    }

    @Test func unchangedReadBackDoesNotBroadcastAndUnknownRequestIsIgnored() async {
        var state = Self.loadedState()
        let request = UUID(), keyboard = KeyboardSummary.preview.id
        state.requests = [.init(id: request, keyboardID: keyboard, intent: .activate(1), sequence: 1)]
        let store = TestStore(initialState: state) { MenuBarFeature() }
        store.exhaustivity = .off
        await store.send(.intentFinished(request, keyboard, .success(.preview)))
        await store.send(.intentFinished(UUID(), keyboard, .failure(CherryError.disconnected)))
        #expect(store.state.errorMessage == nil && !store.state.isApplying)
    }

    @Test func staleSnapshotsAndUnknownPresetAreIgnored() async {
        let store = TestStore(initialState: Self.loadedState()) { MenuBarFeature() }
        let old = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 2)
        await store.send(.snapshotLoaded(old, .success(.preview)))
        await store.send(.snapshotLoaded(old, .failure(CherryError.disconnected)))
        await store.send(.applyPreset(UUID()))
    }

    @Test func fallbackSelectionStaysOnSurvivingDeviceWhenAnotherDeviceReturns() async {
        var state = Self.loadedState()
        state.keyboards.append(Self.second)
        let store = TestStore(initialState: state) { MenuBarFeature() } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.keyboardsUpdated([Self.second]))
        await store.receive(\.refresh)
        await store.receive(\.snapshotLoaded)
        #expect(store.state.selectedID == Self.second.id)
        await store.send(.keyboardsUpdated([.preview, Self.second]))
        #expect(store.state.keyboard?.id == Self.second.id && store.state.snapshotID == Self.second.id)
    }

    @Test func appTreatsNewInterfaceForSameKeyboardAsNewConnection() async {
        var state = AppFeature.State()
        state.keyboards = [.preview]
        state.detail = KeyboardFeature.State(keyboard: .preview)
        let old = KeyboardSummary.preview
        let replacement = KeyboardSummary(id: old.id, product: old.product, manufacturer: old.manufacturer, serialNumber: nil, transport: old.transport, releaseNumber: old.releaseNumber,
            interfaces: [.init(id: 999, usages: [.init(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.keyboardClient.firmwareStatus = { _ in .init(version: 0, crc: 0) }
            $0.firmwareClient.latestRelease = { _ in nil }
            $0.configurationClient.configuration = { _ in .preview }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.keyboardsUpdated([replacement]))
        await store.finish()
        await store.skipReceivedActions()
        #expect(store.state.detail?.isConnected == true)
        #expect(store.state.detail?.configuration.saveGeneration == 1)
        #expect(store.state.detail?.info.loadGeneration == 2)
        #expect(store.state.detail?.keyboard.configurationInterfaceIDs == [999])
    }
}
