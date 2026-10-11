import CherryCore
import Foundation
import Synchronization
import Testing
@testable import CherryAdapters

@Suite("目录有效期与独立消费者取消", .timeLimit(.minutes(1)))
struct CachedFirmwareCatalogTests {
    @Test func cachesEmptySuccessExpiresAndDoesNotCacheFailure() async throws {
        let instant = Mutex(ContinuousClock.now)
        let source = CountingCatalog()
        let cache = CachedFirmwareCatalog(base: source, now: { instant.withLock { $0 } })
        #expect(try await cache.releases().isEmpty)
        #expect(try await cache.releases().isEmpty)
        #expect(await source.calls == 1)
        instant.withLock { $0 = $0.advanced(by: .seconds(301)) }
        await source.failNext()
        await #expect(throws: CherryError.self) { try await cache.releases() }
        #expect(try await cache.releases().isEmpty)
        #expect(await source.calls == 3)
    }

    @Test func concurrentConsumersShareRequestAndOneCancellationIsIndependent() async throws {
        let source = SuspendedCatalog(), cache = CachedFirmwareCatalog(base: source)
        let first = Task { try await cache.releases() }
        await source.waitForCalls(1)
        let second = Task { try await cache.releases() }
        // 让 actor 接收两个请求；底层仍由显式 continuation 控制。
        for _ in 0..<100 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await source.calls == 1)
        await source.succeed(1)
        #expect(try await second.value.isEmpty)
        #expect(try await cache.releases().isEmpty)
        #expect(await source.calls == 1)
    }

    @Test func lastCancellationAllowsNewFlightAndLateOldResultCannotPoisonCache() async throws {
        let source = SuspendedCatalog(), cache = CachedFirmwareCatalog(base: source)
        let first = Task { try await cache.releases() }
        await source.waitForCalls(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let next = Task { try await cache.releases() }
        await source.waitForCalls(2)
        await source.succeed(1) // 底层故意忽略取消，旧结果仍不能被缓存。
        await source.succeed(2)
        #expect(try await next.value.isEmpty)
        #expect(try await cache.releases().isEmpty)
        #expect(await source.calls == 2)
    }
}

private actor CountingCatalog: FirmwareCatalogPort {
    var calls = 0
    private var shouldFail = false
    func failNext() { shouldFail = true }
    func releases() async throws -> [FirmwareRelease] {
        calls += 1
        if shouldFail { shouldFail = false; throw CherryError.network("fixture") }
        return []
    }
}

private actor SuspendedCatalog: FirmwareCatalogPort {
    var calls = 0
    private var pending: [Int: CheckedContinuation<[FirmwareRelease], any Error>] = [:]
    func releases() async throws -> [FirmwareRelease] {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        while calls < count { await Task.yield() }
    }
    func succeed(_ call: Int) { pending.removeValue(forKey: call)?.resume(returning: []) }
}
