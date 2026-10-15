import CherryCore
import Foundation
import Testing
@testable import CherrySimulation

/// The other-model scenarios behave like their driver profile, so UI tests can exercise capability gating end to end.
@Suite("模拟其它型号")
struct MultiModelSimulationTests {
    static func services(_ name: String) async throws -> (SimulatedKeyboardHub, KeyboardSummary, KeyboardInspector, KeyboardConfigurator) {
        let hub = SimulatedKeyboardHub(scenario: .named(name))
        let keyboard = try #require(await hub.keyboards().first)
        let channels = ExclusiveChannelProvider(base: hub)
        return (hub, keyboard, KeyboardInspector(channels: channels), KeyboardConfigurator(channels: channels))
    }

    @Test func wiredBoardHasNoBatteryStatusOrOTA() async throws {
        let (_, keyboard, inspector, configurator) = try await Self.services("mx30s")
        let model = try #require(keyboard.model)
        #expect(keyboard.id.productID == 0x0079 && model.name == "MX BOARD 3.0S FL RGB")
        #expect(!keyboard.hasInterface(usagePage: 0xFFEF) && keyboard.canConfigure)
        let snapshot = try await inspector.vendorSnapshot(of: keyboard)
        #expect(snapshot.battery == nil && snapshot.status == nil)
        let updated = try await configurator.update(
            profile: snapshot.configuration.activeProfile, on: keyboard,
            patch: .set(\.brightness, 1, field: .brightness, on: snapshot.profile.settings)
        )
        #expect(updated.brightness == 1)
        // The simulated board rejects 0x1A like the real wired firmware would; the service never sends it.
        await #expect(throws: CherryError.self) { try await inspector.battery(of: keyboard) }
    }

    @Test func noBacklightBoardOnlySwitchesProfiles() async throws {
        let (_, keyboard, _, configurator) = try await Self.services("nbl")
        let model = try #require(keyboard.model)
        #expect(model.editableFields.isEmpty)
        let switched = try await configurator.activateProfile(0, on: keyboard)
        #expect(switched.activeProfile == 0)
        await #expect(throws: CherryError.self) {
            try await configurator.update(profile: 0, on: keyboard, patch: .set(\.brightness, 1, field: .brightness, on: switched.active.settings))
        }
    }

    @Test func typeBBoardStartsOnItsOwnEffectTable() async throws {
        let (_, keyboard, inspector, configurator) = try await Self.services("pixiu98")
        let model = try #require(keyboard.model)
        let snapshot = try await inspector.vendorSnapshot(of: keyboard)
        #expect(snapshot.configuration.profiles.allSatisfy { model.effect($0.lightingEffect) != nil })
        #expect(snapshot.battery != nil)
        let updated = try await configurator.update(profile: 0, on: keyboard, patch: .set(\.effect, 5, field: .effect, on: snapshot.configuration.profiles[0].settings))
        #expect(model.effect(updated.lightingEffect)?.englishName == "Rainbow Rain")
    }

    @Test func receiverReportsWirelessOverUSB() async throws {
        let (_, keyboard, inspector, _) = try await Self.services("receiver")
        #expect(keyboard.model?.kind == .receiver && keyboard.displayName.hasSuffix("Receiver"))
        let snapshot = try await inspector.vendorSnapshot(of: keyboard)
        #expect(snapshot.status?.mode == .wireless(2) && snapshot.battery?.percent == 64)
        #expect(!keyboard.hasInterface(usagePage: 0xFFEF))
    }

    @Test func simulatedCatalogServesTheModelsOwnRelease() async throws {
        let model = KeyboardModel.pixiu98
        let releases = try await SimulatedFirmwareCatalog(model: model).releases()
        #expect(FirmwareUpdateService.latestRelease(for: model, in: releases)?.name == "MX_PIXIU98_WIRELESS_0118")
    }
}
