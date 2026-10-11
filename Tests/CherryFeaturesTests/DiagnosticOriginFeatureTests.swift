import CherryCore
import ComposableArchitecture
import Foundation
import Synchronization
import Testing
@testable import CherryFeatures

/// 来源由发起操作的界面声明；客户端背后的 Core 服务和适配器只继承 `DiagnosticOrigin.current`。
@MainActor
@Suite("界面声明观测来源")
struct DiagnosticOriginFeatureTests {
    @Test func menuBarWritesAndActivationsAreAttributedToTheMenuBar() async throws {
        let seen = Mutex<[DiagnosticOrigin?]>([])
        let store = TestStore(initialState: MenuBarBranchTests.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.configurationClient.updateProfile = { n, _, patch in
                seen.withLock { $0.append(DiagnosticOrigin.current) }
                return try ProfileConfig(profile: n, raw: KeyboardConfiguration.preview.profile(n)!.applying(patch))
            }
            $0.configurationClient.activateProfile = { n, _ in
                seen.withLock { $0.append(DiagnosticOrigin.current) }
                return try KeyboardConfiguration(activeProfile: n, profiles: KeyboardConfiguration.preview.profiles)
            }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(0))
        await store.receive(\.writeFinished)
        await store.send(.activateProfile(0))
        await store.receive(\.activationFinished)
        #expect(seen.withLock { $0 } == [.menuBar, .menuBar])
    }

    @Test func eachScreenAttributesItsOwnReads() async throws {
        let log = OriginLog()
        let record = log.record

        let info = TestStore(initialState: DeviceInfoFeature.State(keyboard: .preview)) { DeviceInfoFeature() } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in record("info.vendor"); return .preview }
            $0.keyboardClient.firmwareStatus = { _ in .init(version: 0, crc: 0) }
            $0.firmwareClient.latestRelease = { _ in record("info.catalog"); return nil }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        info.exhaustivity = .off
        await info.send(.refresh)
        await info.finish()

        let configuration = TestStore(initialState: ConfigurationFeature.State(keyboard: .preview)) { ConfigurationFeature() } withDependencies: {
            $0.configurationClient.configuration = { _ in record("configuration"); return .preview }
        }
        configuration.exhaustivity = .off
        await configuration.send(.refresh)
        await configuration.finish()

        let firmware = TestStore(initialState: FirmwareFeature.State(keyboard: .preview)) { FirmwareFeature() } withDependencies: {
            $0.firmwareClient.latestRelease = { _ in record("firmware.catalog"); return nil }
        }
        firmware.exhaustivity = .off
        await firmware.send(.refreshLatest)
        await firmware.finish()

        #expect(log.all == [
            "info.vendor": .deviceInfo, "info.catalog": .deviceInfo,
            "configuration": .configuration, "firmware.catalog": .firmware,
        ])
    }
}

/// 客户端被调用时所在任务的 origin。
final class OriginLog: Sendable {
    private let seen = Mutex<[String: DiagnosticOrigin?]>([:])
    @Sendable func record(_ key: String) { seen.withLock { $0[key] = DiagnosticOrigin.current } }
    var all: [String: DiagnosticOrigin?] { seen.withLock { $0 } }
}
