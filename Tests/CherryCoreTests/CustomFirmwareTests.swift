import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import CherryCore

/// A definition written against `TestFirmware.make(size: 320)`.
enum CustomFirmwareFixture {
    static let size = 320
    static let stock = try! TestFirmware.updaterImage(size: size)

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    static func original(_ offset: Int, _ count: Int) -> String { hex(stock.firmware[offset ..< offset + count]) }

    /// "fix": toggle at 0x40 (4 bytes); "key": slot at 0x60 whose palette contains the stock bytes ("a");
    /// "bare": slot at 0x70 without a stock palette entry; "mode": two explicit values at 0x80.
    static func json(
        schema: Int = 1, id: String = "test-def", crc: UInt32? = nil, extraOptions: [String] = [], replacingOptions: [String]? = nil
    ) -> Data {
        let options = replacingOptions ?? [
            #"{"id":"fix","group":"g","name":"Fix","stability":"verified","values":[{"id":"on","name":"On","edits":[{"offset":"0x40","original":"\#(original(0x40, 4))","replacement":"DE AD BE EF"}]}]}"#,
            #"{"id":"key","group":"g","name":"Key","slot":{"offset":96,"original":"\#(original(0x60, 3))","palette":"p"}}"#,
            #"{"id":"bare","group":"g","name":"Bare","slot":{"offset":"0x70","original":"\#(original(0x70, 3))","palette":"q"}}"#,
            #"{"id":"mode","group":"g","name":"Mode","values":[{"id":"x","name":"X","edits":[{"offset":"0x80","original":"\#(original(0x80, 2))","replacement":"11 22"}]},{"id":"y","name":"Y","edits":[{"offset":"0x80","original":"\#(original(0x80, 2))","replacement":"33 44"}]}]}"#,
        ] + extraOptions
        return Data("""
        {"schema":\(schema),"id":"\(id)","name":"Test","firmware":{"vendorID":"046A","productID":"01E2","versionCode":"0117",
         "catalogName":"TEST_0117","size":\(size),"crc32":"\(String(format: "%08X", crc ?? stock.embeddedCRC))"},
         "palettes":[{"id":"p","items":[{"id":"a","name":"A","bytes":"\(original(0x60, 3))"},{"id":"b","name":"B","bytes":"01 02 03"},{"id":"c","name":"C","bytes":"04 05 06"}]},
                     {"id":"q","items":[{"id":"z","name":"Z","bytes":"07 08 09"}]}],
         "groups":[{"id":"g","name":"G"}],
         "options":[\(options.joined(separator: ","))]}
        """.utf8)
    }

    static let definition = try! FirmwareDefinition.decode(json(), source: "test.cherryfw")

    static func issues(_ data: Data) -> [DefinitionIssue] {
        do {
            _ = try FirmwareDefinition.decode(data, source: "x")
            return []
        } catch CustomFirmwareError.invalidDefinition(_, let issues) {
            return issues
        } catch {
            Issue.record("unexpected \(error)")
            return []
        }
    }
}

@Suite("自定义固件：定义文件")
struct FirmwareDefinitionTests {
    typealias F = CustomFirmwareFixture

    @Test func decodesExplicitAndSlotOptions() throws {
        let d = F.definition
        #expect(d.firmware == FirmwareFingerprint(vendorID: 0x046A, productID: 0x01E2, versionCode: 0x0117, catalogName: "TEST_0117", size: 320, crc: F.stock.embeddedCRC))
        #expect(d.options.map(\.id) == ["fix", "key", "bare", "mode"])

        let fix = try #require(d.option("fix"))
        #expect(fix.isToggle && fix.stability == .verified)
        #expect(fix.stockValue.id == FirmwareDefinition.stockValueID && fix.stockValue.edits.isEmpty)
        #expect(fix.value("on")?.edits == [ByteEdit(offset: 0x40, original: Array(F.stock.firmware[0x40 ..< 0x44]), replacement: [0xDE, 0xAD, 0xBE, 0xEF])])

        let key = try #require(d.option("key"))
        #expect(key.values.map(\.id) == ["a", "b", "c"] && key.stockValue.id == "a" && key.stockValue.name == "A")
        #expect(key.stability == .experimental)
        #expect(key.value("b")?.edits.first?.replacement == [1, 2, 3])

        let bare = try #require(d.option("bare"))
        #expect(bare.values.map(\.id) == [FirmwareDefinition.stockValueID, "z"] && bare.stockValue.name.isEmpty)
        // Slots stay choices even with a two-entry palette; explicit options are switches only with one alternative.
        #expect(!bare.isToggle && d.option("mode")?.isToggle == false)
        #expect(d.applies(to: .pixiu75))
    }

    static let broken: [(String, Data, DefinitionIssue)] = {
        typealias F = CustomFirmwareFixture
        let g = #""group":"g","name":"N""#
        return [
            ("schema", F.json(schema: 2), .unsupportedSchema(2)),
            ("duplicate", F.json(extraOptions: [#"{"id":"fix",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x90","original":"\#(F.original(0x90, 1))","replacement":"00"}]}]}"#]), .duplicateID("fix")),
            ("group", F.json(extraOptions: [#"{"id":"o","group":"nope","name":"N","values":[{"id":"v","name":"V","edits":[{"offset":"0x90","original":"\#(F.original(0x90, 1))","replacement":"00"}]}]}"#]), .unknownGroup(option: "o", group: "nope")),
            ("palette", F.json(extraOptions: [#"{"id":"o",\#(g),"slot":{"offset":"0x90","original":"00","palette":"nope"}}"#]), .unknownPalette(option: "o", palette: "nope")),
            ("range", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x13F","original":"00 00","replacement":"00 00"}]}]}"#]), .outOfRange(option: "o", offset: 0x13F)),
            ("header", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x18","original":"00","replacement":"01"}]}]}"#]), .protectedRange(option: "o", offset: 0x18)),
            ("trailer", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x13D","original":"00","replacement":"01"}]}]}"#]), .protectedRange(option: "o", offset: 0x13D)),
            ("overlap", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x42","original":"00","replacement":"01"}]}]}"#]), .overlap(option: "o", other: "fix", offset: 0x42)),
            ("length", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x90","original":"00 00","replacement":"01"}]}]}"#]), .lengthMismatch(option: "o", value: "v")),
            ("slotLength", F.json(extraOptions: [#"{"id":"o",\#(g),"slot":{"offset":"0x90","original":"00 00","palette":"p"}}"#]), .lengthMismatch(option: "o", value: "a")),
            ("hex", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[{"id":"v","name":"V","edits":[{"offset":"0x90","original":"0G","replacement":"01"}]}]}"#]), .invalidHex(field: "options.o.v")),
            ("empty", F.json(extraOptions: [#"{"id":"o",\#(g),"values":[]}"#]), .noValues(option: "o")),
        ]
    }()

    @Test(arguments: broken.indices)
    func rejectsInvalidDefinitions(_ index: Int) {
        let (name, data, expected) = Self.broken[index]
        #expect(F.issues(data).contains(expected), "\(name): \(F.issues(data))")
    }

    @Test func rejectsMalformedJSONAndOptionsWithoutValues() {
        #expect(F.issues(Data("{".utf8)).count == 1)
        let both = F.json(extraOptions: [#"{"id":"o","group":"g","name":"N"}"#])
        #expect(F.issues(both).contains { if case .malformed = $0 { true } else { false } })
    }
}

@Suite("自定义固件：构建")
struct FirmwarePatcherTests {
    typealias F = CustomFirmwareFixture

    @Test func buildsPatchedImageWithFreshCRC() throws {
        let build = try FirmwarePatcher.build(["fix": "on", "key": "b", "mode": "y"], definition: F.definition, stock: F.stock)
        try build.image.validate()
        #expect(build.crc == Checksums.telinkCRC32(build.image.firmware.dropLast(4)) && build.crc != F.stock.embeddedCRC)
        #expect(build.edits.map(\.offset) == [0x40, 0x60, 0x80])
        let changed = zip(F.stock.firmware.dropLast(4), build.image.firmware.dropLast(4)).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(Set(changed).isSubset(of: Set(Array(0x40 ..< 0x44) + Array(0x60 ..< 0x63) + Array(0x80 ..< 0x82))))
        #expect(build.changedByteCount == changed.count)
        #expect(Array(build.image.firmware[0x80 ..< 0x82]) == [0x33, 0x44])
        #expect(build.image.vendorID == F.stock.vendorID && build.image.usagePage == F.stock.usagePage && build.image.reportID == F.stock.reportID)
        #expect(build.selections == ["fix": "on", "key": "b", "mode": "y"])
    }

    @Test func stockChoicesBuildTheStockImage() throws {
        for selections in [[:], ["key": "a"], ["bare": FirmwareDefinition.stockValueID]] as [[String: String]] {
            let build = try FirmwarePatcher.build(selections, definition: F.definition, stock: F.stock)
            #expect(build.isStock && build.crc == F.stock.embeddedCRC && build.image.firmware == F.stock.firmware)
            #expect(build.selections.isEmpty)
        }
    }

    @Test func refusesOtherImagesAndUnknownChoices() throws {
        let other = try TestFirmware.updaterImage(size: 336)
        #expect(throws: CustomFirmwareError.stockMismatch(expectedCRC: F.stock.embeddedCRC, actualCRC: other.embeddedCRC)) {
            try FirmwarePatcher.build([:], definition: F.definition, stock: other)
        }
        #expect(throws: CustomFirmwareError.unknownSelections(["gone", "key=zz"])) {
            try FirmwarePatcher.build(["gone": "on", "key": "zz"], definition: F.definition, stock: F.stock)
        }
    }

    @Test func findsDefinitionsWrittenForAnotherImage() throws {
        let wrong = F.json(replacingOptions: [
            #"{"id":"fix","group":"g","name":"Fix","values":[{"id":"on","name":"On","edits":[{"offset":"0x40","original":"00 00 00 00","replacement":"11 11 11 11"}]}]}"#,
        ])
        let definition = try FirmwareDefinition.decode(wrong, source: "wrong")
        #expect(FirmwarePatcher.mismatches(of: definition, in: F.stock) == [.originalMismatch(option: "fix", offset: 0x40)])
        #expect(FirmwarePatcher.mismatches(of: F.definition, in: F.stock).isEmpty)
        #expect(throws: CustomFirmwareError.invalidDefinition(source: "test-def", issues: [.originalMismatch(option: "fix", offset: 0x40)])) {
            try FirmwarePatcher.build(["fix": "on"], definition: definition, stock: F.stock)
        }
    }

    @Test func normalizesAndResolvesSelections() {
        let d = F.definition
        let selections = ["fix": "on", "key": "a", "gone": "x", "mode": "nope"]
        #expect(d.normalized(selections) == ["fix": "on", "gone": "x", "mode": "nope"])
        #expect(d.normalized(selections, droppingUnknown: true) == ["fix": "on"])
        let resolved = d.resolve(selections)
        #expect(resolved.unknown == ["gone", "mode=nope"])
        #expect(resolved.changes.map(\.option.id) == ["fix"])
        #expect(resolved.choices.first { $0.option.id == "mode" }?.value.isStock == true)
        #expect(resolved.changedByteCount == resolved.edits[0].changedByteCount)
    }
}

@Suite("自定义固件：识别")
struct InstalledFirmwareTests {
    static let keyboard = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 1)
    static let date = Date(timeIntervalSince1970: 1_000_000)

    static func variant(_ name: String, crc: UInt32?, updated: TimeInterval = 0) -> FirmwareVariant {
        FirmwareVariant(name: name, definitionID: "test-def", createdAt: date, updatedAt: date.addingTimeInterval(updated), builtCRC: crc)
    }

    static func record(crc: UInt32, variant: UUID?, at offset: TimeInterval) -> FirmwareFlashRecord {
        FirmwareFlashRecord(date: date.addingTimeInterval(offset), keyboard: keyboard, definitionID: "test-def", crc: crc,
                            variantID: variant, variantName: "old", selections: ["fix": "on"])
    }

    @Test func prefersStockThenFlashedVariantThenNewestEditThenRecords() {
        let definitions = [CustomFirmwareFixture.definition]
        let stockCRC = CustomFirmwareFixture.stock.embeddedCRC
        let a = Self.variant("A", crc: 0xA, updated: 10), b = Self.variant("B", crc: 0xA, updated: 20), plain = Self.variant("P", crc: stockCRC)

        #expect(InstalledFirmware.identify(crc: stockCRC, definitions: definitions, variants: [plain], records: []) == .stock(definitionID: "test-def"))
        #expect(InstalledFirmware.identify(crc: 0xA, definitions: definitions, variants: [a, b], records: []) == .variant(id: b.id, definitionID: "test-def"))
        let flashedA = [Self.record(crc: 0xA, variant: b.id, at: 1), Self.record(crc: 0xA, variant: a.id, at: 2)]
        #expect(InstalledFirmware.identify(crc: 0xA, definitions: definitions, variants: [a, b], records: flashedA) == .variant(id: a.id, definitionID: "test-def"))

        let old = Self.record(crc: 0xB, variant: a.id, at: 3)
        #expect(InstalledFirmware.identify(crc: 0xB, definitions: definitions, variants: [a, b], records: flashedA + [old]) == .earlierBuild(old))
        #expect(InstalledFirmware.identify(crc: 0xC, definitions: definitions, variants: [a, b], records: [old]) == .unknown(crc: 0xC))
    }

    @Test func variantsAndRecordsRoundTripThroughJSON() throws {
        let v = Self.variant("方案", crc: 0x1234_5678)
        #expect(try FirmwareVariant.decode(v.encoded()) == v)
        #expect(throws: CustomFirmwareError.self) { try FirmwareVariant.decode(Data("[]".utf8)) }
    }
}

// MARK: - Service

final class MemoryDefinitionSource: FirmwareDefinitionSource {
    let docs: [FirmwareDefinitionDocument]
    init(_ docs: [FirmwareDefinitionDocument]) { self.docs = docs }
    func documents() async throws -> [FirmwareDefinitionDocument] { docs }
}

final class MemoryVariantStore: FirmwareVariantStore {
    let items = Mutex<[UUID: FirmwareVariant]>([:])
    func variants() async throws -> [FirmwareVariant] { items.withLock { Array($0.values) } }
    func save(_ variant: FirmwareVariant) async throws { items.withLock { $0[variant.id] = variant } }
    func delete(id: UUID) async throws { _ = items.withLock { $0.removeValue(forKey: id) } }
}

final class MemoryFlashLog: FirmwareFlashLog {
    let items = Mutex<[FirmwareFlashRecord]>([])
    func records() async throws -> [FirmwareFlashRecord] { items.withLock { $0.sorted { $0.date > $1.date } } }
    func append(_ record: FirmwareFlashRecord) async throws { items.withLock { $0.append(record) } }
}

@Suite("自定义固件：应用服务")
struct CustomFirmwareServiceTests {
    typealias F = CustomFirmwareFixture
    static let date = Date(timeIntervalSince1970: 2_000_000)

    static var updater: Data {
        Data(ResourceFixture.stream(name: "param_128K", value: TestFirmware.param())
            + ResourceFixture.stream(name: "code_2M", value: TestFirmware.code(firmware: TestFirmware.make(size: F.size))))
    }

    static func release(_ data: Data, name: String = "TEST_0117") -> FirmwareRelease {
        FirmwareRelease(name: name, deviceIndex: 0x33, versionCode: "0117", versionName: "0.1.1.7",
                        downloadURL: URL(string: "https://example.invalid/\(name).exe")!,
                        md5: Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined(), isForced: false)
    }

    static func service(
        _ ports: ServicePorts, docs: [FirmwareDefinitionDocument] = [.init(origin: .bundled, name: "t.cherryfw", data: F.json())],
        store: MemoryVariantStore = MemoryVariantStore(), log: MemoryFlashLog = MemoryFlashLog()
    ) -> CustomFirmwareService {
        let tick = Mutex(0.0)
        return CustomFirmwareService(firmware: ServiceBranchTests.service(ports), definitions: MemoryDefinitionSource(docs),
                                     variants: store, flashLog: log, now: { tick.withLock { t in defer { t += 1 }; return date.addingTimeInterval(t) } })
    }

    static func stock() throws -> FirmwarePackage {
        try FirmwareUpdateService.makePackage(data: updater, source: .localFile(URL(fileURLWithPath: "/tmp/stock.exe")))
    }

    @Test func userDefinitionsReplaceBundledOnesAndBadFilesAreReported() async throws {
        let user = F.json(extraOptions: [#"{"id":"extra","group":"g","name":"E","values":[{"id":"v","name":"V","edits":[{"offset":"0x90","original":"\#(F.original(0x90, 1))","replacement":"00"}]}]}"#])
        let docs: [FirmwareDefinitionDocument] = [
            .init(origin: .user, name: "u.cherryfw", data: user),
            .init(origin: .bundled, name: "b.cherryfw", data: F.json()),
            .init(origin: .bundled, name: "c.cherryfw", data: F.json()),
            .init(origin: .bundled, name: "bad.cherryfw", data: Data("{".utf8)),
            .init(origin: .bundled, name: "other.cherryfw", data: F.json(id: "other")),
        ]
        let catalog = try await Self.service(ServicePorts(channels: []), docs: docs).loadDefinitions()
        // Bundled files load first (by name); the user file replaces "test-def" in place.
        #expect(catalog.definitions.map(\.id) == ["test-def", "other"])
        #expect(catalog.definitions.first { $0.id == "test-def" }?.option("extra") != nil)
        #expect(catalog.rejected.count == 2)
        #expect(catalog.rejected.contains(.invalidDefinition(source: "c.cherryfw", issues: [.duplicateID("test-def")])))
        #expect(catalog.definitions(for: .pixiu75).count == 2)
    }

    @Test func stockImageComesFromTheCatalogAndMustMatchTheDefinition() async throws {
        let data = Self.updater
        let found = Self.service(ServicePorts(channels: [], entries: [Self.release(data, name: "OTHER"), Self.release(data)], data: data))
        let package = try await found.stockPackage(for: F.definition)
        #expect(package.image.embeddedCRC == F.stock.embeddedCRC)

        let missing = Self.service(ServicePorts(channels: [], entries: [Self.release(data, name: "OTHER")], data: data))
        await #expect(throws: CustomFirmwareError.stockNotInCatalog("TEST_0117")) { try await missing.stockPackage(for: F.definition) }

        let otherImage = Data(ResourceFixture.stream(name: "param_128K", value: TestFirmware.param())
            + ResourceFixture.stream(name: "code_2M", value: TestFirmware.code(firmware: TestFirmware.make(size: 336))))
        let wrong = Self.service(ServicePorts(channels: [], entries: [Self.release(otherImage)], data: otherImage))
        await #expect(throws: CustomFirmwareError.self) { try await wrong.stockPackage(for: F.definition) }

        let local = try found.stockPackage(for: F.definition, localData: data, url: URL(fileURLWithPath: "/tmp/x.exe"))
        #expect(local.source == .localFile(URL(fileURLWithPath: "/tmp/x.exe")))
    }

    @Test func variantsAreCreatedCopiedSavedAndDeleted() async throws {
        let store = MemoryVariantStore()
        let service = Self.service(ServicePorts(channels: []), store: store)
        await #expect(throws: CustomFirmwareError.invalidVariant("name")) { try await service.createVariant(named: "  ", for: F.definition) }

        var a = try await service.createVariant(named: " A ", for: F.definition)
        #expect(a.name == "A" && a.selections.isEmpty && a.createdAt == a.updatedAt)
        a.selections = ["fix": "on", "key": "a"]
        let stock = try Self.stock()
        let saved = try await service.save(a, definition: F.definition, stock: stock)
        #expect(saved.selections == ["fix": "on"])
        #expect(saved.builtCRC == (try FirmwarePatcher.build(["fix": "on"], definition: F.definition, stock: F.stock)).crc)

        // Without the stock image an unchanged variant keeps its CRC, an edited one loses it.
        #expect(try await service.save(saved, definition: F.definition, stock: nil).builtCRC == saved.builtCRC)
        var edited = saved
        edited.selections["mode"] = "x"
        #expect(try await service.save(edited, definition: F.definition, stock: nil).builtCRC == nil)

        let copy = try await service.createVariant(named: "B", for: F.definition, copying: saved)
        #expect(copy.id != saved.id && copy.selections == saved.selections)
        #expect(try await service.variants().map(\.name) == ["A", "B"])

        try await service.deleteVariant(id: copy.id)
        #expect(try await service.variants().map(\.id) == [saved.id])

        let foreign = FirmwareVariant(name: "X", definitionID: "other", createdAt: Self.date)
        await #expect(throws: CustomFirmwareError.variantDefinitionMismatch(variant: "X", definition: "test-def")) {
            try await service.save(foreign, definition: F.definition, stock: nil)
        }
    }

    @Test func flashesVerifiesAndRecordsAVariant() async throws {
        let store = MemoryVariantStore(), log = MemoryFlashLog()
        let stock = try Self.stock()
        var variant = FirmwareVariant(name: "A", definitionID: "test-def", selections: ["fix": "on"], createdAt: Self.date)
        try await store.save(variant)
        let probe = Self.service(ServicePorts(channels: []), store: store, log: log)
        let install = try probe.install(variant: variant, definition: F.definition, stock: stock)
        #expect(install.package.source == .customBuild(variantID: variant.id, name: "A"))
        #expect(install.package.image.firmware != stock.image.firmware)

        // The device reports the flashed image after its reboot.
        let device = SimulatedOTADevice(currentCRC: install.expectedCRC)
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [5], respond: device.respond), SimulatedChannel(inputReportIDs: [5], respond: device.respond)],
                                 lists: [[ServiceBranchTests.keyboard]])
        let service = Self.service(ports, store: store, log: log)
        #expect(try await service.flash(install, on: ServiceBranchTests.keyboard) { _ in } == .confirmed)
        let reassembled = device.memory.withLock { Array($0.image[0 ..< install.package.image.firmware.count]) }
        #expect(reassembled == install.package.image.firmware)

        let status = try await service.verify(install, on: ServiceBranchTests.keyboard.id, pollInterval: .milliseconds(1))
        #expect(status.crc == install.expectedCRC)
        let records = try await service.flashRecords()
        #expect(records.count == 1 && records[0].variantID == variant.id && records[0].crc == install.expectedCRC && records[0].selections == ["fix": "on"])
        variant.builtCRC = install.expectedCRC
        #expect(try await store.variants() == [variant])
    }

    @Test func wrongImageAfterRebootIsNotRecorded() async throws {
        let log = MemoryFlashLog()
        let stock = try Self.stock()
        let probe = Self.service(ServicePorts(channels: []), log: log)
        let install = try probe.restoreStock(definition: F.definition, stock: stock)
        #expect(install.variant == nil && install.expectedCRC == F.stock.embeddedCRC)

        let device = SimulatedOTADevice(currentCRC: 0x0BAD_F00D)
        let ports = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [5], respond: device.respond)], lists: [[ServiceBranchTests.keyboard]])
        await #expect(throws: CustomFirmwareError.verificationMismatch(expectedCRC: F.stock.embeddedCRC, actualCRC: 0x0BAD_F00D)) {
            try await Self.service(ports, log: log).verify(install, on: ServiceBranchTests.keyboard.id, pollInterval: .milliseconds(1))
        }
        #expect(try await log.records().isEmpty)

        let good = SimulatedOTADevice(currentCRC: F.stock.embeddedCRC)
        let goodPorts = ServicePorts(channels: [SimulatedChannel(inputReportIDs: [5], respond: good.respond)], lists: [[ServiceBranchTests.keyboard]])
        _ = try await Self.service(goodPorts, log: log).verify(install, on: ServiceBranchTests.keyboard.id, pollInterval: .milliseconds(1))
        #expect(try await log.records().map(\.variantID) == [nil])
    }

    @Test func buildRefusesForeignVariantsAndUnknownChoices() throws {
        let service = Self.service(ServicePorts(channels: []))
        let stock = try Self.stock()
        let foreign = FirmwareVariant(name: "X", definitionID: "other", createdAt: Self.date)
        #expect(throws: CustomFirmwareError.variantDefinitionMismatch(variant: "X", definition: "test-def")) {
            try service.install(variant: foreign, definition: F.definition, stock: stock)
        }
        let stale = FirmwareVariant(name: "S", definitionID: "test-def", selections: ["gone": "on"], createdAt: Self.date)
        #expect(throws: CustomFirmwareError.unknownSelections(["gone"])) { try service.install(variant: stale, definition: F.definition, stock: stock) }
    }

    @Test func coreServicesBuildTheServiceOnTheSharedFirmwareService() async throws {
        let ports = ServicePorts(channels: [])
        let services = CoreServices(discovery: ports, channels: ports, catalog: ports, downloader: ports)
        let service = services.customFirmware(
            definitions: MemoryDefinitionSource([.init(origin: .bundled, name: "t", data: F.json())]),
            variants: MemoryVariantStore(), flashLog: MemoryFlashLog()
        )
        #expect(try await service.loadDefinitions().definitions.map(\.id) == ["test-def"])
    }
}

/// Golden check of the shipped PIXIU 75 definition against the official 0117 image, when both are on disk.
@Suite("自定义固件：PIXIU 75 0117 定义")
struct PIXIU75DefinitionTests {
    static let definitionFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../App/Resources/FirmwareDefinitions/MX_PIXIU75_WIRELESS_0117.cherryfw").standardizedFileURL
    /// Produced by the `cherry-ota patch` CLI and flashed on hardware on 2026-10-11 (device read back CRC 0x46F8C57A).
    static let cliImage = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../../cherry-ota/patched/PIXIU75_0117_fnrow.bin").standardizedFileURL

    static var available: Bool {
        FileManager.default.fileExists(atPath: definitionFile.path) && FileManager.default.fileExists(atPath: RealUpdaterTests.updater.path)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: definitionFile.path)))
    func shippedDefinitionIsValid() throws {
        let definition = try FirmwareDefinition.decode(Data(contentsOf: Self.definitionFile), source: "MX_PIXIU75_WIRELESS_0117.cherryfw")
        #expect(definition.applies(to: .pixiu75) && definition.firmware.crc == 0xCFE1_A03E && definition.firmware.version == FirmwareVersion(code: 0x0117))
        #expect(definition.options.count == 26)
        // Every slot's stock bytes are named by the palette.
        #expect(definition.options.filter { !$0.isToggle }.allSatisfy { !$0.stockValue.name.isEmpty })
        #expect(definition.options.filter(\.isToggle).map(\.id) == ["frow.fixed", "frow.no-ctrl-fn-lock"])
    }

    @Test(.enabled(if: available))
    func buildsTheImageVerifiedOnHardware() throws {
        let definition = try FirmwareDefinition.decode(Data(contentsOf: Self.definitionFile), source: "MX_PIXIU75_WIRELESS_0117.cherryfw")
        let stock = try UpdaterImage(updaterExe: Data(contentsOf: RealUpdaterTests.updater))
        #expect(FirmwarePatcher.mismatches(of: definition, in: stock).isEmpty)

        let build = try FirmwarePatcher.build(["frow.fixed": "on", "frow.no-ctrl-fn-lock": "on"], definition: definition, stock: stock)
        #expect(build.crc == 0x46F8_C57A)
        #expect(build.changedByteCount == 9)
        if FileManager.default.fileExists(atPath: Self.cliImage.path) {
            #expect(build.image.firmware == [UInt8](try Data(contentsOf: Self.cliImage)))
        }

        let media = try FirmwarePatcher.build(["mac.f7": "previous-track", "mac.f8": "play-pause", "mac.f9": "next-track"], definition: definition, stock: stock)
        #expect(Array(media.image.firmware[0x1F1F1 ..< 0x1F1F4]) == [0x30, 0xB6, 0x00])
        try media.image.validate()
    }
}
