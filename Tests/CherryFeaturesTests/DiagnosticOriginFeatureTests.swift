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
    @Test func menuBarIntentsAreAttributedToTheMenuBar() async throws {
        let log = OriginLog()
        let record = log.record
        let store = TestStore(initialState: MenuBarBranchTests.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.configurationClient.applyIntent = { _, _ in record("intent"); return .preview }
        }
        store.exhaustivity = .off
        await store.send(.setBrightness(0))
        await store.receive(\.intentFinished)
        #expect(log.all == ["intent": .menuBar])
    }

    @Test func menuBarRecordsWhetherSnapshotsWereApplied() async {
        let events = Mutex<[DiagnosticEvent]>([])
        let store = TestStore(initialState: MenuBarBranchTests.loadedState()) { MenuBarFeature() } withDependencies: {
            $0.diagnostics = .recording { event in events.withLock { $0.append(event) } }
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        let id = KeyboardSummary.preview.id
        await store.send(.snapshotLoaded(id, .success(.preview)))
        await store.send(.snapshotLoaded(id, .failure(CherryError.disconnected)))
        await store.send(.snapshotLoaded(KeyboardID(vendorID: 1, productID: 1, locationID: 9), .success(.preview)))
        await store.finish()
        let recorded = events.withLock { $0.filter { [.resultApplied, .resultIgnored].contains($0.operation) } }
        #expect(recorded.map(\.operation) == [.resultApplied, .resultApplied, .resultIgnored])
        #expect(recorded.map(\.outcome) == [.success, .failed, .ignored])
        #expect(recorded.allSatisfy { $0.context.origin == .menuBar })
    }

    /// reducer 决定结果采用与否，记录由 effect 执行（G2）。
    @Test func deviceInfoRecordsWhetherResultsWereApplied() async {
        let events = Mutex<[DiagnosticEvent]>([])
        let store = TestStore(initialState: DeviceInfoFeature.State(keyboard: .preview)) { DeviceInfoFeature() } withDependencies: {
            $0.diagnostics = .recording { event in events.withLock { $0.append(event) } }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.vendorLoaded(.success(.preview)))
        await store.send(.vendorLoaded(.failure(CherryError.disconnected)))
        await store.send(.keyboardUpdated(nil))
        await store.send(.vendorLoaded(.success(.preview)))
        await store.finish()
        let recorded = events.withLock { $0.filter { [.resultApplied, .resultIgnored].contains($0.operation) } }
        #expect(recorded.map(\.operation) == [.resultApplied, .resultApplied, .resultIgnored])
        #expect(recorded.map(\.outcome) == [.success, .failed, .ignored])
        #expect(recorded.allSatisfy { $0.context.origin == .deviceInfo })
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
