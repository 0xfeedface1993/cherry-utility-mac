import Foundation
import CherryCore
import ComposableArchitecture
import Testing
import Synchronization
@testable import CherryFeatures

@MainActor
@Suite("读回同步与晚到读取")
struct ConfigurationSynchronizationTests {
    static func saved() throws -> ProfileConfig {
        let base = KeyboardConfiguration.preview.active
        return try ProfileConfig(profile: base.profile, raw: base.applying(.set(\.effect, 2, field: .effect, on: base.settings)))
    }

    @Test func infoPreservesLoadedValuesDuringRefreshAndFailure() async {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loaded(.preview)
        state.firmware = .loaded(.init(version: 0, crc: 0))
        state.latestRelease = .loaded(nil)
        let store = TestStore(initialState: state) { DeviceInfoFeature() } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in throw CherryError.disconnected }
            $0.keyboardClient.firmwareStatus = { _ in throw CherryError.disconnected }
            $0.firmwareClient.latestRelease = { _ in throw CherryError.network("fixture") }
        }
        store.exhaustivity = .off
        await store.send(.refresh)
        #expect(store.state.vendor == state.vendor && store.state.firmware == state.firmware)
        await store.finish()
        await store.skipReceivedActions()
        #expect(store.state.vendor == state.vendor && store.state.latestRelease == state.latestRelease)
        #expect(store.state.refreshError != nil)
    }

    @Test func infoRejectsOldRefreshAndMergesReadBackIntoInitialSnapshot() async throws {
        let saved = try Self.saved()
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loading
        let store = TestStore(initialState: state) { DeviceInfoFeature() } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.configurationSynchronized(.profile(saved)))
        await store.send(.vendorLoaded(.success(.preview), revision: 0))
        #expect(store.state.vendor.value?.profile == saved)
        #expect(store.state.vendor.value?.battery == VendorSnapshot.preview.battery)
        await store.send(.vendorLoaded(.success(.preview), revision: 0))
        #expect(store.state.vendor.value?.profile == saved)
    }

    @Test func initialConfigurationReadKeepsAuthoritativePatchAndAlwaysSettles() async throws {
        var state = ConfigurationFeature.State(keyboard: .preview)
        state.configuration = .loading
        let saved = try Self.saved()
        let store = TestStore(initialState: state) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.configurationSynchronized(.profile(saved)))
        await store.send(.configurationLoaded(.success(.preview), revision: 0))
        #expect(store.state.configuration.value?.active == saved)
        #expect(store.state.editor != nil)
    }

    @Test func oldConnectionGenerationCannotSupplyInitialSnapshot() async {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loading
        state.loadGeneration = 2
        let store = TestStore(initialState: state) { DeviceInfoFeature() }
        await store.send(.vendorLoaded(.success(.preview), revision: 0, generation: 1))
        await store.send(.firmwareLoaded(.success(.init(version: 0, crc: 0)), generation: 1))
        await store.send(.releaseLoaded(.success(nil), generation: 1))
    }

    @Test func refreshFailureClosesRootSpanWithFailure() async {
        let events = Mutex<[DiagnosticEvent]>([])
        let store = TestStore(initialState: DeviceInfoFeature.State(keyboard: .preview)) { DeviceInfoFeature() } withDependencies: {
            $0.diagnostics = .recording { event in events.withLock { $0.append(event) } }
            $0.keyboardClient.vendorSnapshot = { _ in throw CherryError.disconnected }
            $0.keyboardClient.firmwareStatus = { _ in .init(version: 0, crc: 0) }
            $0.firmwareClient.latestRelease = { _ in nil }
        }
        store.exhaustivity = .off
        await store.send(.refresh)
        await store.finish()
        await store.skipReceivedActions()
        let roots = events.withLock { $0.filter { $0.operation == .refresh && $0.phase == .finished } }
        #expect(roots.count == 1 && roots.first?.outcome == .disconnected)
    }

    @Test func ownSaveRejectsEarlierConfigurationRead() async throws {
        let saved = try Self.saved()
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.saveFinished(.success(saved)))
        await store.receive(\.delegate, .configurationChanged(KeyboardSummary.preview.id, .profile(saved)))
        await store.send(.configurationLoaded(.success(.preview), revision: 0))
        #expect(store.state.configuration.value?.active == saved)
    }

    @Test func editorRejectsRefreshFromBeforeAuthoritativeReadBack() async throws {
        let saved = try Self.saved()
        let store = TestStore(initialState: ConfigurationFeatureTests.loadedState()) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.edit(.brightness(0)))
        await store.send(.configurationSynchronized(.profile(saved)))
        await store.send(.configurationLoaded(.success(.preview), revision: 0))
        #expect(store.state.configuration.value?.active == saved)
        #expect(store.state.editor?.draft.brightness == 0)
        #expect(store.state.editor?.draft.effect == saved.settings.effect)
    }
}
