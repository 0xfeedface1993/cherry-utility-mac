import CherryCore
import Foundation
import Synchronization
import Testing
@testable import CherryAdapters

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let handlers = Mutex<[String: Handler]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let id = request.value(forHTTPHeaderField: "X-Test-ID") ?? ""
            let handler = Self.handlers.withLock { $0[id] }
            let respond = try #require(handler)
            let (code, data) = try respond(request)
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class HTTPFixture: Sendable {
    let id = UUID().uuidString
    let session: URLSession
    let cache: URL
    let requests = Mutex(0)
    var client: CherryFirmwareCatalog { CherryFirmwareCatalog(session: session, cacheDirectory: cache) }
    var count: Int { requests.withLock { $0 } }

    init(handler: @escaping FixtureURLProtocol.Handler) throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("CherryTests-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-ID": id]
        session = URLSession(configuration: configuration)
        FixtureURLProtocol.handlers.withLock { $0[id] = { [weak self] request in
            self?.requests.withLock { $0 += 1 }
            return try handler(request)
        } }
    }
    deinit {
        session.invalidateAndCancel()
        FixtureURLProtocol.handlers.withLock { _ = $0.removeValue(forKey: id) }
        try? FileManager.default.removeItem(at: cache)
    }
}

@Suite("固件目录、HTTP 与磁盘缓存")
struct CatalogTests {
    static func release(md5: String) -> FirmwareRelease {
        FirmwareRelease(name: "test", deviceIndex: 60, versionCode: "0117", versionName: "0.1.1.7", downloadURL: URL(string: "https://example.invalid/test.exe")!, md5: md5, isForced: false)
    }
    static func entry(_ name: String, url: String) -> [String: Any] {
        ["Desc": name, "DeviceIndex": 60, "DownloadURL": url, "HashCode": "ab", "VersionCode": "0117", "VersionName": "0.1.1.7"]
    }

    @Test func parsesCatalogUpgradesHTTPAndDeduplicatesValidEntries() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": [Self.entry("x", url: "http://example.invalid/x.exe"), Self.entry("x", url: "https://example.invalid/duplicate.exe")]])
        let fixture = try HTTPFixture { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "WinHTTP Client/1.0")
            return (200, data)
        }
        let releases = try await fixture.client.releases()
        #expect(releases.count == 1)
        #expect(releases.first?.downloadURL.scheme == "https")
        #expect(releases.first?.md5 == "AB")
        #expect(releases.first?.isForced == false)
    }

    @Test func invalidFirstEntryDoesNotHideValidDuplicate() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": [Self.entry("x", url: "http://["), Self.entry("x", url: "https://example.invalid/x.exe")]])
        let fixture = try HTTPFixture { _ in (200, data) }
        #expect(try await fixture.client.releases().count == 1)
    }

    @Test(arguments: ["relative/path.exe", "file:///tmp/x.exe", "ftp://example.invalid/x.exe", "https:/x.exe"])
    func rejectsNonHTTPDownloadLocations(_ value: String) {
        #expect(CherryFirmwareCatalog.secureURL(value) == nil)
    }

    @Test func urlSessionCancellationRetainsCancellationMeaning() async throws {
        let fixture = try HTTPFixture { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await fixture.client.releases() }
    }

    @Test func catalogErrorsAndHTTPFailureAreSurfaced() async throws {
        for body in [Data("invalid".utf8), Data("{\"code\":7,\"data\":[]}".utf8)] {
            let fixture = try HTTPFixture { _ in (200, body) }
            await #expect(throws: CherryError.self) { try await fixture.client.releases() }
        }
        let http = try HTTPFixture { _ in (503, Data()) }
        await #expect(throws: CherryError.network("HTTP 503")) { try await http.client.releases() }
        let transport = try HTTPFixture { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: CherryError.self) { try await transport.client.releases() }
    }

    @Test func downloadsCachesAndReplacesCorruptedCache() async throws {
        let data = Data("official updater fixture".utf8)
        let fixture = try HTTPFixture { _ in (200, data) }
        let release = Self.release(md5: CherryFirmwareCatalog.md5(data).lowercased())
        #expect(try await fixture.client.download(release) == data)
        #expect(try await fixture.client.download(release) == data)
        #expect(fixture.count == 1)
        try Data("corrupt".utf8).write(to: fixture.cache.appendingPathComponent("test.exe"))
        #expect(try await fixture.client.download(release) == data)
        #expect(fixture.count == 2)
    }

    @Test func badDownloadHashDoesNotPopulateCache() async throws {
        let fixture = try HTTPFixture { _ in (200, Data("wrong".utf8)) }
        await #expect(throws: CherryError.self) { try await fixture.client.download(Self.release(md5: "00")) }
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("test.exe").path))
    }
}

@Suite("HID 报文邮箱生命周期")
struct MailboxTests {
    @Test func bufferIsFIFOAndDropsOldestAtCapacity() async throws {
        let mailbox = ReportMailbox()
        for i in 0...ReportMailbox.capacity { mailbox.push([UInt8(truncatingIfNeeded: i)]) }
        #expect(try await mailbox.next(timeout: .seconds(1)) == [1])
        mailbox.drain()
        #expect(try await mailbox.next(timeout: .milliseconds(1)) == nil)
        mailbox.push([9])
        #expect(try await mailbox.next(timeout: .seconds(1)) == [9])
    }

    @Test func closeDiscardsBufferAndRejectsFurtherReports() async throws {
        let mailbox = ReportMailbox()
        mailbox.push([1]); mailbox.close(); mailbox.close(); mailbox.push([2])
        #expect(mailbox.isClosed)
        await #expect(throws: CherryError.disconnected) { try await mailbox.next(timeout: .seconds(1)) }
    }

    @Test func waitingConsumerReceivesPushOrDisconnect() async throws {
        let mailbox = ReportMailbox()
        let task = Task { try await mailbox.next(timeout: .seconds(1)) }
        await Task.yield()
        mailbox.push([4])
        #expect(try await task.value == [4])
        let waiting = Task { try await mailbox.next(timeout: .seconds(1)) }
        await Task.yield()
        mailbox.close()
        await #expect(throws: CherryError.disconnected) { try await waiting.value }
    }

    @Test func cancellationReleasesWaiterForNextConsumer() async throws {
        let mailbox = ReportMailbox()
        let task = Task { try await mailbox.next(timeout: .seconds(1)) }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        mailbox.push([7])
        #expect(try await mailbox.next(timeout: .seconds(1)) == [7])
    }
}

@Suite("本机预设存储")
struct PresetStorageTests {
    static let settings = ProfileSettings(effect: 0x0A, brightness: 2, speed: 3, randomColor: false, color: .white, sleepSeconds: 300, deepSleepMinutes: 30)

    @Test func persistsSortsSkipsCorruptedFilesAndDeletesIdempotently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CherryPresets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileProfilePresetStore(directory: directory)
        #expect(try await store.presets().isEmpty)
        let old = ProfilePreset(name: "旧预设", createdAt: Date(timeIntervalSince1970: 0), productID: nil, settings: Self.settings)
        let new = ProfilePreset(name: "新预设", createdAt: Date(timeIntervalSince1970: 100), productID: 0x01E2, settings: Self.settings)
        try await store.save(old); try await store.save(new)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("bad.cherryprofile"))
        try Data().write(to: directory.appendingPathComponent("ignored.txt"))
        #expect(try await store.presets() == [new, old])
        #expect(try ProfilePreset.decode(new.encoded()) == new)
        try await store.delete(id: new.id); try await store.delete(id: new.id)
        #expect(try await store.presets() == [old])
    }

    @Test func libraryNormalizesNamesAndImportsWithFreshIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CherryPresets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileProfilePresetStore(directory: directory)
        let library = PresetLibrary(store: store, now: { Date(timeIntervalSince1970: 0) })
        let keyboard = KeyboardSummary(id: KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 1), product: "PIXIU75", manufacturer: "CHERRY", serialNumber: nil, transport: "USB", releaseNumber: 0x0117, interfaces: [])
        var settings = Self.settings; settings.brightness = 20
        let saved = try await library.save(name: "  游戏  ", settings: settings, from: keyboard)
        #expect(saved.name == "游戏" && saved.settings.brightness == 4)
        #expect(saved.isCompatible(with: keyboard))
        let imported = try await library.importPreset(saved.encoded())
        #expect(imported.id != saved.id && imported.settings == saved.settings)
        // 默认名称由界面生成；Core 不接受空名称。
        await #expect(throws: CherryError.presetFormat("预设名称为空")) { try await library.save(name: " \n ", settings: settings, from: keyboard) }
        #expect(try await library.presets().count == 2)
        try await library.delete(id: imported.id)
        #expect(try await library.presets().count == 1)
        #expect(throws: CherryError.presetFormat("无法解析预设文件")) { try ProfilePreset.decode(Data()) }
    }

    @Test func storageErrorsAreReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CherryPresets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let store = FileProfilePresetStore(directory: directory)
        await #expect(throws: CherryError.self) { try await store.presets() }
        let preset = ProfilePreset(name: "测试", createdAt: Date(timeIntervalSince1970: 0), productID: nil, settings: Self.settings)
        await #expect(throws: CherryError.self) { try await store.save(preset) }
    }
}
