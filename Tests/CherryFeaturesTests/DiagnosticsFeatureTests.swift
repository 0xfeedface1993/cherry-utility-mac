import CherryCore
import ComposableArchitecture
import Foundation
import Synchronization
import Testing
@testable import CherryFeatures

@MainActor
@Suite("诊断窗口状态与取消")
struct DiagnosticsFeatureTests {
    nonisolated static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    nonisolated static var artifact: DiagnosticExport {
        .init(id: id, url: URL(fileURLWithPath: "/tmp/fixture.cherrydiag.zip"), bytes: 1024, events: 8, partial: true, dropped: 2)
    }

    @Test func exportPreviewAndSaveUsesSameArtifact() async {
        let artifact = Self.artifact
        let discarded = Mutex<[UUID]>([])
        let store = TestStore(initialState: DiagnosticsFeature.State()) { DiagnosticsFeature() } withDependencies: {
            $0.uuid = .constant(Self.id)
            $0.diagnosticsClient.status = { .init() }
            $0.diagnosticsClient.export = { range in #expect(range == .recent); return artifact }
            $0.diagnosticsClient.save = { value in #expect(value == artifact); return true }
            $0.diagnosticsClient.discard = { value in discarded.withLock { $0.append(value.id) } }
        }
        await store.send(.exportTapped) { $0.phase = .exporting; $0.requestID = Self.id }
        await store.receive(\.exportFinished) { $0.phase = .ready; $0.artifact = artifact }
        await store.send(.saveTapped) { $0.phase = .saving }
        await store.receive(\.saveFinished) { $0.phase = .saved; $0.artifact = nil }
        #expect(discarded.withLock { $0 } == [artifact.id])
    }

    @Test func cancellationBlocksDuplicateAndDiscardsLateResult() async {
        let clock = TestClock()
        let discarded = Mutex(0)
        let store = TestStore(initialState: DiagnosticsFeature.State()) { DiagnosticsFeature() } withDependencies: {
            $0.uuid = .constant(Self.id)
            $0.diagnosticsClient.status = { .init() }
            $0.diagnosticsClient.export = { _ in try await clock.sleep(for: .seconds(10)); return Self.artifact }
            $0.diagnosticsClient.discard = { _ in discarded.withLock { $0 += 1 } }
        }
        await store.send(.exportTapped) { $0.phase = .exporting; $0.requestID = Self.id }
        await store.send(.exportTapped)
        await store.send(.rangeChanged(.day))
        await store.send(.cancelTapped) { $0.phase = .cancelled; $0.requestID = nil }
        await store.send(.exportFinished(Self.id, .success(Self.artifact)))
        #expect(discarded.withLock { $0 } == 1)
        await store.finish()
    }

    @Test func failedExportCanRetryAndSavePanelCancellationKeepsPreview() async {
        var state = DiagnosticsFeature.State()
        state.phase = .exporting; state.requestID = Self.id
        let store = TestStore(initialState: state) { DiagnosticsFeature() } withDependencies: {
            $0.uuid = .constant(Self.id)
            $0.diagnosticsClient.status = { .init() }
            $0.diagnosticsClient.export = { _ in Self.artifact }
            $0.diagnosticsClient.save = { _ in false }
            $0.diagnosticsClient.discard = { _ in }
        }
        await store.send(.exportFinished(Self.id, .failure(.timedOut))) { $0.phase = .failed; $0.error = DiagnosticExportError.timedOut.message }
        await store.send(.exportTapped) { $0.phase = .exporting; $0.error = nil }
        await store.receive(\.exportFinished) { $0.phase = .ready; $0.artifact = Self.artifact }
        await store.send(.saveTapped) { $0.phase = .saving }
        await store.receive(\.saveFinished) { $0.phase = .ready }
        await store.send(.dismissed) { $0.phase = .cancelled; $0.requestID = nil; $0.artifact = nil }
    }

    @Test func visibleStatusTimerStopsOnDismissalAndReflectsExpiry() async {
        let clock = TestClock()
        let status = Mutex(DiagnosticStatus(mode: .profile))
        let store = TestStore(initialState: DiagnosticsFeature.State()) { DiagnosticsFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.diagnosticsClient.status = { status.withLock { $0 } }
            $0.diagnosticsClient.setMode = { mode in status.withLock { $0.mode = mode } }
        }
        await store.send(.task) { $0.status.mode = .profile }
        status.withLock { $0.mode = .standard }
        await clock.advance(by: .seconds(1))
        await store.receive(\.refreshStatus) { $0.status.mode = .standard }
        await store.send(.modeChanged(.detailed)) { $0.status.mode = .detailed }
        await store.send(.dismissed) { $0.phase = .cancelled }
        await store.finish()
    }
}
