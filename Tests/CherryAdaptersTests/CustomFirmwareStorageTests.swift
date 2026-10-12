import CherryAdapters
import CherryCore
import Foundation
import Testing

@Suite("自定义固件存储")
struct CustomFirmwareStorageTests {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CherryCustomFirmware-\(UUID())", isDirectory: true)
    }

    static let shippedDefinitions = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../App/Resources/FirmwareDefinitions").standardizedFileURL

    @Test func definitionDirectoriesYieldOnlyDefinitionFiles() async throws {
        let bundled = Self.temporaryDirectory(), user = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: bundled.appendingPathComponent("b.cherryfw"))
        try Data("a".utf8).write(to: bundled.appendingPathComponent("a.cherryfw"))
        try Data("x".utf8).write(to: bundled.appendingPathComponent("notes.json"))
        // A directory with the extension cannot be read as a file: it is passed on empty, for the core to report.
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("c.cherryfw"), withIntermediateDirectories: true)

        let source = DirectoryFirmwareDefinitionSource(directories: [(bundled, .bundled), (user, .user)])
        let documents = try await source.documents()
        #expect(documents.map(\.name) == ["a.cherryfw", "b.cherryfw", "c.cherryfw"])
        #expect(documents.map(\.data) == [Data("a".utf8), Data("b".utf8), Data()])
        #expect(documents.allSatisfy { $0.origin == .bundled })

        let file = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        await #expect(throws: CherryError.self) { try await DirectoryFirmwareDefinitionSource(directories: [(file, .user)]).documents() }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: shippedDefinitions.path)))
    func shippedDefinitionsLoadThroughTheAdapter() async throws {
        let documents = try await DirectoryFirmwareDefinitionSource(directories: [(Self.shippedDefinitions, .bundled)]).documents()
        #expect(!documents.isEmpty)
        for document in documents {
            let definition = try FirmwareDefinition.decode(document.data, source: document.name)
            #expect(KeyboardModel.all.contains { definition.applies(to: $0) }, "\(document.name)")
        }
    }

    @Test func variantStoreRoundTripsAndSkipsDamagedFiles() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileFirmwareVariantStore(directory: directory)
        #expect(try await store.variants().isEmpty)

        let variant = FirmwareVariant(name: "方案", definitionID: "d", selections: ["a": "b"], createdAt: Date(timeIntervalSince1970: 0), builtCRC: 0xCAFE_F00D)
        try await store.save(variant)
        var renamed = variant
        renamed.name = "改名"
        try await store.save(renamed)
        try Data("{".utf8).write(to: directory.appendingPathComponent("bad.cherryfirmware"))
        try Data().write(to: directory.appendingPathComponent("other.txt"))
        #expect(try await store.variants() == [renamed])

        try await store.delete(id: variant.id)
        try await store.delete(id: variant.id)
        #expect(try await store.variants().isEmpty)

        let file = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        await #expect(throws: CherryError.self) { try await FileFirmwareVariantStore(directory: file).variants() }
        await #expect(throws: CherryError.self) { try await FileFirmwareVariantStore(directory: file).save(variant) }
    }

    static func record(_ seconds: TimeInterval, crc: UInt32 = 1) -> FirmwareFlashRecord {
        FirmwareFlashRecord(
            date: Date(timeIntervalSince1970: seconds), keyboard: KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 1),
            definitionID: "d", crc: crc, variantID: nil, variantName: nil, selections: [:]
        )
    }

    @Test func flashLogKeepsNewestRecordsUpToItsLimit() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("flash-history.json")
        let log = FileFirmwareFlashLog(file: file, limit: 2)
        #expect(try await log.records().isEmpty)
        for seconds in [10.0, 30, 20] { try await log.append(Self.record(seconds)) }
        #expect(try await log.records().map(\.date.timeIntervalSince1970) == [30, 20])

        try Data("garbage".utf8).write(to: file)
        #expect(try await log.records().isEmpty)
        try await log.append(Self.record(40))
        #expect(try await log.records().count == 1)
    }

    @Test func concurrentAppendsAreAllKept() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileFirmwareFlashLog(file: directory.appendingPathComponent("flash-history.json"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 20 { group.addTask { try await log.append(Self.record(Double(i), crc: UInt32(i))) } }
            try await group.waitForAll()
        }
        #expect(Set(try await log.records().map(\.crc)) == Set(0 ..< 20))
    }
}
