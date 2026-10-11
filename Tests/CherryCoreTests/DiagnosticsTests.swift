import Foundation
import Synchronization
import Testing
@testable import CherryCore

@Suite struct DiagnosticsTests {
    @Test func cancellationClosesOnceAndKeepsOriginalError() async throws {
        let events = Mutex<[DiagnosticEvent]>([])
        let port = Diagnostics.recording { event in events.withLock { $0.append(event) } }
        let task = Task {
            try await port.measure(.configurationWrite) {
                try await port.measure(.configurationReadBack) { try await Task.sleep(for: .seconds(20)) }
            }
        }
        while events.withLock({ $0.count }) < 2 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let recorded = events.withLock { $0 }
        #expect(recorded.count == 4)
        #expect(recorded.filter { $0.phase == .finished }.allSatisfy { $0.outcome == .cancelled })
        #expect(recorded[0].context.traceID == recorded[1].context.traceID)
        #expect(recorded[1].context.parentSpanID == recorded[0].context.spanID)
    }

    @Test func racingFinishAndDeinitProduceOneEnd() async {
        let calls = Mutex(0)
        var span: DiagnosticSpan? = DiagnosticSpan(context: TraceContext()) { _, _, _ in calls.withLock { $0 += 1 } }
        if let span {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<100 { group.addTask { span.finish() } }
            }
        }
        span = nil
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func failureNeverEncodesDescriptionOrDeviceIdentity() throws {
        let failure = DiagnosticFailure(CherryError.storage("/Users/person/token=SECRET"))
        #expect(failure == .storage)
        let event = DiagnosticEvent(operation: .presetIO, phase: .finished, context: TraceContext(),
                                    outcome: .failed, failure: failure, elapsedNs: 0)
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!json.contains("SECRET"))
        #expect(!json.contains("/Users"))
        #expect(!json.contains("locationID"))
    }

    @Test func injectedClockMeasuresElapsedTime() {
        let clock = Mutex<UInt64>(10)
        let events = Mutex<[DiagnosticEvent]>([])
        let port = Diagnostics.recording(clock: .init(now: { clock.withLock { $0 } })) { e in events.withLock { $0.append(e) } }
        let span = port.begin(.channelOpen)
        clock.withLock { $0 = 35 }
        span.finish()
        #expect(events.withLock { $0.last?.metrics.durationNs } == 25)
    }

    @Test func grantedCallbackPrecedesResumeAndRunsOutsideLock() async throws {
        let gate = ChannelGate<String>()
        let granted = Mutex(false)
        try await gate.acquire("keyboard", resolved: { result in
            if case .success = result { granted.withLock { $0 = gate.isHeld("keyboard") } }
        })
        #expect(granted.withLock { $0 })
        gate.release("keyboard")
    }

    @Test func explicitCallbackContextSurvivesDetachedBoundary() async {
        let parent = TraceContext(origin: .configuration)
        let events = Mutex<[DiagnosticEvent]>([])
        let port = Diagnostics.recording { e in events.withLock { $0.append(e) } }
        await Task.detached {
            let span = port.begin(.hidSend, context: parent)
            span.finish()
        }.value
        #expect(events.withLock { $0.allSatisfy { $0.context.traceID == parent.traceID && $0.context.origin == .configuration } })
    }
}

@Suite("OTA 诊断终态")
struct FirmwareDiagnosticTests {
    @Test(arguments: [DiagnosticOutcome.success, .unconfirmed, .deviceRebooted, .failed])
    func finalResultStageReportsActualOutcome(_ expected: DiagnosticOutcome) async throws {
        let events = Mutex<[DiagnosticEvent]>([])
        let port = Diagnostics.recording(sink: { event in events.withLock { $0.append(event) } })
        let image = try TestFirmware.updaterImage(size: 320)
        let channel = SimulatedChannel(inputReportIDs: [5]) { report in
            guard report[2] == 6 else { return .reports([report]) }
            switch expected {
            case .unconfirmed: return .reports([])
            case .deviceRebooted: return .disconnect
            default: return .reports([[5, 2, 3, 0, 6, 0xFF, expected == .failed ? 1 : 0] + [UInt8](repeating: 0xFF, count: 57)])
            }
        }
        let flasher = try FirmwareFlasher(channel: channel, reportID: 5, timeouts: ServiceBranchTests.fast, diagnostics: port)
        if expected == .failed {
            await #expect(throws: CherryError.otaFailed(status: 1)) { try await flasher.flash(image) { _ in } }
        } else { _ = try await flasher.flash(image) { _ in } }
        let ends = events.withLock { $0.filter { $0.operation == .otaResult && $0.phase == .finished } }
        #expect(ends.count == 1 && ends.first?.outcome == expected)
        let all = events.withLock { $0 }
        #expect(Set(all.filter { $0.phase == .began }.map { $0.context.spanID }) == Set(all.filter { $0.phase == .finished }.map { $0.context.spanID }))
    }
}

extension FirmwareDiagnosticTests {
    @Test func missingStartAckIsTimeoutInBothStages() async throws {
        let events = Mutex<[DiagnosticEvent]>([])
        let port = Diagnostics.recording(sink: { event in events.withLock { $0.append(event) } })
        let image = try TestFirmware.updaterImage(size: 320)
        let channel = SimulatedChannel(inputReportIDs: [5]) { _ in .reports([]) }
        let flasher = try FirmwareFlasher(channel: channel, reportID: 5, timeouts: ServiceBranchTests.fast, diagnostics: port)
        await #expect(throws: CherryError.self) { try await flasher.flash(image) { _ in } }
        let ends = events.withLock { $0.filter { $0.phase == .finished && [.otaACK, .otaStart].contains($0.operation) } }
        #expect(ends.count == 2 && ends.allSatisfy { $0.outcome == .timeout })
    }
}
