import CherryCore
import Foundation
import Testing
@testable import CherryCore

@Suite("共享配置队列：合并、隔离与断连")
struct ConfigurationWriterTests {
    static let firstID = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 1)
    static func keyboard(_ id: KeyboardID = firstID) -> KeyboardSummary {
        KeyboardSummary(id: id, product: "PIXIU 75", manufacturer: "CHERRY", serialNumber: nil, transport: "USB", releaseNumber: 0x0117,
                        interfaces: [.init(id: UInt64(id.locationID), usages: [.init(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])])
    }
    static var configuration: KeyboardConfiguration {
        try! .init(activeProfile: 1, profiles: (0..<3).map { n in
            var raw = [UInt8](repeating: 0, count: 64)
            raw[1] = 0; raw[2] = 4; raw[3] = 2
            return try ProfileConfig(profile: n, raw: raw)
        })
    }
    static func waitForPending(_ count: Int, writer: KeyboardConfigurationWriter, id: KeyboardID = firstID) async throws {
        for _ in 0..<10_000 {
            if await writer.pendingRequestCount(for: id) == count { return }
            await Task.yield()
        }
        Issue.record("请求没有按预期入队")
        throw CancellationError()
    }

    @Test func mergesFieldsProfilesActivationAndRevertIntoNextBatch() async throws {
        let probe = WriteProbe()
        var calls = probe.calls.makeAsyncIterator()
        let writer = KeyboardConfigurationWriter(apply: probe.apply)
        let keyboard = Self.keyboard(), base = Self.configuration.active.settings
        let first = Task { try await writer.apply(.update(1, patch: .set(\.brightness, 0, field: .brightness, on: base)), on: keyboard) }
        let a = try #require(await calls.next())
        let second = Task { try await writer.apply(.update(1, patch: .set(\.speed, 0, field: .speed, on: base)), on: keyboard) }
        try await Self.waitForPending(1, writer: writer)
        let third = Task { try await writer.apply(.update(1, patch: .set(\.brightness, 4, field: .brightness, on: base)).merging(.activate(0)), on: keyboard) }
        try await Self.waitForPending(2, writer: writer)
        let fourth = Task { try await writer.apply(.update(2, patch: .set(\.effect, 2, field: .effect, on: base)).merging(.activate(2)), on: keyboard) }
        try await Self.waitForPending(3, writer: writer)
        await probe.finish(a.index)
        let b = try #require(await calls.next())
        #expect(b.intent.activeProfile == 2)
        #expect(b.intent.patches[1]?.fields == [.brightness, .speed])
        #expect(b.intent.patches[1]?.values?.brightness == 4)
        #expect(b.intent.patches[2]?.fields == [.effect])
        await probe.finish(b.index)
        _ = try await first.value
        let result = try await second.value
        #expect(try await third.value == result)
        #expect(try await fourth.value == result)
        #expect(result.activeProfile == 2 && result.profile(1)?.brightness == 4 && result.profile(1)?.speed == 0)
        #expect(await probe.count == 2)
    }

    /// 不指定配置档的补丁（自动化入口）在执行时才落到当前档；同批里有切换时落到切换后的那一档，叠在显式补丁之上。
    @Test func activeProfilePatchesResolveWhenTheBatchRuns() throws {
        let base = Self.configuration.active.settings
        let dim = ConfigurationIntent.updateActive(patch: .set(\.brightness, 1, field: .brightness, on: base))
        let fast = ConfigurationIntent.updateActive(patch: .set(\.speed, 4, field: .speed, on: base))
        let explicit = ConfigurationIntent.update(1, patch: .set(\.brightness, 3, field: .brightness, on: base))
        #expect(ConfigurationIntent.updateActive(patch: ProfilePatch(base, fields: [])).isEmpty)

        let merged = explicit.merging(dim).merging(fast)
        #expect(merged.activePatch?.fields == [.brightness, .speed] && merged.patches[1]?.values?.brightness == 3)
        let onCurrent = merged.resolved(currentProfile: 1)
        #expect(onCurrent.activePatch == nil && onCurrent.patches.keys.sorted() == [1])
        #expect(onCurrent.patches[1]?.values?.brightness == 1 && onCurrent.patches[1]?.fields == [.brightness, .speed])
        #expect(merged.applied(to: Self.configuration).profile(1)?.brightness == 1)

        let switched = dim.merging(.activate(2)).resolved(currentProfile: 1)
        #expect(switched.activeProfile == 2 && switched.patches.keys.sorted() == [2])
        let applied = dim.merging(.activate(2)).applied(to: Self.configuration)
        #expect(applied.activeProfile == 2 && applied.profile(2)?.brightness == 1 && applied.profile(1)?.brightness == 4)
    }

    @Test func devicesExecuteIndependentlyAndDoNotSharePatches() async throws {
        let probe = WriteProbe()
        var calls = probe.calls.makeAsyncIterator()
        let writer = KeyboardConfigurationWriter(apply: probe.apply)
        let secondID = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 2)
        let first = Task { try await writer.apply(.activate(0), on: Self.keyboard()) }
        let a = try #require(await calls.next())
        let second = Task { try await writer.apply(.activate(2), on: Self.keyboard(secondID)) }
        let b = try #require(await calls.next())
        #expect(a.keyboard.id != b.keyboard.id)
        await probe.finish(b.index)
        #expect(try await second.value.activeProfile == 2)
        await probe.finish(a.index)
        #expect(try await first.value.activeProfile == 0)
    }

    @Test func failureContinuesWithExplicitlySubmittedPendingBatch() async throws {
        let probe = WriteProbe()
        var calls = probe.calls.makeAsyncIterator()
        let writer = KeyboardConfigurationWriter(apply: probe.apply)
        let first = Task { try await writer.apply(.activate(0), on: Self.keyboard()) }
        let a = try #require(await calls.next())
        let second = Task { try await writer.apply(.activate(2), on: Self.keyboard()) }
        try await Self.waitForPending(1, writer: writer)
        await probe.finish(a.index, error: CherryError.timeout("fixture"))
        let b = try #require(await calls.next())
        await probe.finish(b.index)
        await #expect(throws: CherryError.self) { try await first.value }
        #expect(try await second.value.activeProfile == 2)
    }

    @Test func disconnectDropsPendingAndWaitsForOldWorkerBeforeReconnect() async throws {
        let probe = WriteProbe()
        var calls = probe.calls.makeAsyncIterator()
        let writer = KeyboardConfigurationWriter(apply: probe.apply)
        await writer.keyboardsUpdated([Self.keyboard()])
        let first = Task { try await writer.apply(.activate(0), on: Self.keyboard()) }
        let a = try #require(await calls.next())
        let second = Task { try await writer.apply(.activate(2), on: Self.keyboard()) }
        try await Self.waitForPending(1, writer: writer)
        await writer.keyboardsUpdated([])
        await #expect(throws: CherryError.disconnected) { try await first.value }
        await #expect(throws: CherryError.disconnected) { try await second.value }
        await #expect(throws: CherryError.disconnected) { try await writer.apply(.activate(1), on: Self.keyboard()) }
        await writer.keyboardsUpdated([Self.keyboard()])
        let reconnected = Task { try await writer.apply(.activate(1), on: Self.keyboard()) }
        try await Self.waitForPending(1, writer: writer)
        #expect(await probe.count == 1)
        await probe.finish(a.index) // 故意模拟不合作取消的底层，旧成功不能恢复旧请求。
        let b = try #require(await calls.next())
        #expect(b.intent.activeProfile == 1)
        await probe.finish(b.index)
        #expect(try await reconnected.value.activeProfile == 1)
        #expect(await probe.count == 2)
    }

    @Test func queuedWorkKeepsItsCallingOriginAndPageCancellationDoesNotAbortWrite() async throws {
        let probe = WriteProbe()
        var calls = probe.calls.makeAsyncIterator()
        let writer = KeyboardConfigurationWriter(apply: probe.apply)
        let first = Task { try await DiagnosticOrigin.$current.withValue(.menuBar) { try await writer.apply(.activate(0), on: Self.keyboard()) } }
        let a = try #require(await calls.next())
        let second = Task { try await DiagnosticOrigin.$current.withValue(.configuration) { try await writer.apply(.activate(2), on: Self.keyboard()) } }
        try await Self.waitForPending(1, writer: writer)
        first.cancel()
        await probe.finish(a.index)
        let b = try #require(await calls.next())
        #expect(a.origin == .menuBar && b.origin == .configuration)
        await probe.finish(b.index)
        #expect(try await first.value.activeProfile == 0)
        #expect(try await second.value.activeProfile == 2)
    }

    @Test func interfaceReplacementInvalidatesOldSessionWithoutAnEmptyDiscoveryList() async throws {
        let probe = WriteProbe()
        var calls = probe.calls.makeAsyncIterator()
        let writer = KeyboardConfigurationWriter(apply: probe.apply)
        let old = Self.keyboard()
        let replacement = KeyboardSummary(id: old.id, product: old.product, manufacturer: old.manufacturer, serialNumber: nil, transport: old.transport, releaseNumber: old.releaseNumber,
            interfaces: [.init(id: 999, usages: [.init(page: 0xFF1C, usage: 0x92)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])])
        await writer.keyboardsUpdated([old])
        let active = Task { try await writer.apply(.activate(0), on: old) }
        let a = try #require(await calls.next())
        let pending = Task { try await writer.apply(.activate(2), on: old) }
        try await Self.waitForPending(1, writer: writer)
        await writer.keyboardsUpdated([replacement])
        await #expect(throws: CherryError.disconnected) { try await active.value }
        await #expect(throws: CherryError.disconnected) { try await pending.value }
        await #expect(throws: CherryError.disconnected) { try await writer.apply(.activate(2), on: old) }
        let fresh = Task { try await writer.apply(.activate(1), on: replacement) }
        try await Self.waitForPending(1, writer: writer)
        await probe.finish(a.index)
        let b = try #require(await calls.next())
        #expect(b.keyboard.configurationInterfaceIDs == [999] && b.intent.activeProfile == 1)
        await probe.finish(b.index)
        #expect(try await fresh.value.activeProfile == 1)
    }
}

private actor WriteProbe {
    struct Call: Sendable {
        let index: Int
        let intent: ConfigurationIntent
        let keyboard: KeyboardSummary
        let origin: DiagnosticOrigin?
    }
    nonisolated let calls: AsyncStream<Call>
    private let events: AsyncStream<Call>.Continuation
    private var waiters: [Int: CheckedContinuation<KeyboardConfiguration, any Error>] = [:]
    private var intents: [Int: ConfigurationIntent] = [:]
    private(set) var count = 0
    init() { (calls, events) = AsyncStream.makeStream() }
    @Sendable func apply(_ intent: ConfigurationIntent, _ keyboard: KeyboardSummary) async throws -> KeyboardConfiguration {
        count += 1
        let index = count
        intents[index] = intent
        return try await withCheckedThrowingContinuation { continuation in
            waiters[index] = continuation
            events.yield(.init(index: index, intent: intent, keyboard: keyboard, origin: DiagnosticOrigin.current))
        }
    }
    func finish(_ index: Int, error: (any Error)? = nil) {
        guard let waiter = waiters.removeValue(forKey: index), let intent = intents.removeValue(forKey: index) else { return }
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume(returning: intent.applied(to: ConfigurationWriterTests.configuration)) }
    }
}
