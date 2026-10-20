import CherryAdapters
import CherryCore
import Foundation
import Testing
@testable import CherrySimulation

/// The custom-firmware flow end to end: simulated keyboard, real core services and the on-disk stores.
@Suite("模拟键盘：自定义固件")
struct SimulatedCustomFirmwareTests {
    @Test func simulatedDefinitionMatchesTheSyntheticStockImage() throws {
        let definition = try FirmwareDefinition.decode(SimulatedCustomFirmware.definitionData, source: "sim")
        let stock = try UpdaterImage(updaterExe: SimulatedCustomFirmware.stockUpdater)
        #expect(definition.firmware.matches(stock) && stock.embeddedCRC == SimulatedCustomFirmware.stockCRC)
        #expect(FirmwarePatcher.mismatches(of: definition, in: stock).isEmpty)
        #expect(definition.option("mac.f8")?.stockValue.name == "")
        #expect(SimulatedKeyboardHub.Scenario.named("customfw").firmwareCRC == SimulatedCustomFirmware.stockCRC)
        #expect(SimulatedKeyboardHub.Scenario.named("pixiu75").firmwareCRC == SimulatedKeyboardHub.initialCRC)
    }

    @Test func variantIsFlashedRecognisedAndStockRestored() async throws {
        var scenario = SimulatedKeyboardHub.Scenario.named("customfw")
        scenario.rebootDelay = .milliseconds(100)
        let hub = SimulatedKeyboardHub(scenario: scenario)
        let catalog = SimulatedStockCatalog()
        let services = CoreServices(discovery: hub, channels: hub, catalog: catalog, downloader: catalog)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CherrySimCustom-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let variants = FileFirmwareVariantStore(directory: directory.appendingPathComponent("Variants"))
        let log = FileFirmwareFlashLog(file: directory.appendingPathComponent("flash-history.json"))
        let service = services.customFirmware(definitions: SimulatedFirmwareDefinitions(), variants: variants, flashLog: log)
        let keyboard = try #require(await hub.keyboards().first)

        let definitions = try await service.loadDefinitions()
        let definition = try #require(definitions.definitions(for: .pixiu75).first)
        func installed() async throws -> InstalledFirmware {
            let crc = try await services.inspector.firmwareStatus(of: keyboard).crc
            return InstalledFirmware.identify(crc: crc, definitions: definitions.definitions,
                                              variants: try await service.variants(), records: try await service.flashRecords())
        }
        #expect(try await installed() == .stock(definitionID: definition.id))

        let stock = try await service.stockPackage(for: definition)
        var variant = try await service.createVariant(named: "媒体键", for: definition)
        variant.selections = ["frow.fixed": "on", "mac.f8": "play-pause"]
        variant = try await service.save(variant, definition: definition, stock: stock)

        let install = try service.install(variant: variant, definition: definition, stock: stock)
        #expect(install.expectedCRC == variant.builtCRC)
        #expect(try await service.flash(install, on: keyboard) { _ in } == .confirmed)
        let status = try await service.verify(install, on: keyboard.id, timeout: .seconds(5), pollInterval: .milliseconds(50))
        #expect(status.crc == install.expectedCRC && status.version == 0x0117)
        #expect(try await installed() == .variant(id: variant.id, definitionID: definition.id))

        // Editing the variant afterwards: the keyboard still runs the earlier build.
        variant.selections["mac.f8"] = "next-track"
        variant = try await service.save(variant, definition: definition, stock: stock)
        guard case .earlierBuild(let record) = try await installed() else {
            Issue.record("expected the earlier build")
            return
        }
        #expect(record.variantID == variant.id && record.selections == ["frow.fixed": "on", "mac.f8": "play-pause"])

        let restore = try service.restoreStock(definition: definition, stock: stock)
        #expect(try await service.flash(restore, on: keyboard) { _ in } == .confirmed)
        _ = try await service.verify(restore, on: keyboard.id, timeout: .seconds(5), pollInterval: .milliseconds(50))
        #expect(try await installed() == .stock(definitionID: definition.id))
        #expect(try await service.flashRecords().map(\.variantID) == [nil, variant.id])
    }
}
