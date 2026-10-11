import CherryCore
import CherryAdapters
import Synchronization
import Testing

@Suite("配置批次真实协议集成")
struct ConfigurationIntentIntegrationTests {
    @Test func batchUpdatesMultipleProfilesAndActivatesWithReadBackVerification() async throws {
        let hub = SimulatedKeyboardHub()
        let keyboard = try #require(await hub.keyboards().first)
        let events = Mutex<[DiagnosticEvent]>([])
        let diagnostics = Diagnostics.recording { event in events.withLock { $0.append(event) } }
        let configurator = KeyboardConfigurator(channels: ExclusiveChannelProvider(base: hub), diagnostics: diagnostics)
        let original = try await configurator.configuration(of: keyboard)
        let intent = ConfigurationIntent.update(0, patch: .set(\.brightness, 1, field: .brightness, on: original.active.settings))
            .merging(.update(2, patch: .set(\.effect, 2, field: .effect, on: original.active.settings)))
            .merging(.activate(2))
        let saved = try await configurator.apply(intent, on: keyboard)
        #expect(saved.activeProfile == 2)
        #expect(saved.profile(0)?.brightness == 1 && saved.profile(2)?.lightingEffect == 2)
        #expect(saved.profile(1) == original.profile(1))
        let count = hub.writeCount
        #expect(try await configurator.apply(intent, on: keyboard) == saved)
        #expect(hub.writeCount == count)
        #expect(events.withLock { $0.filter { $0.operation == .configurationWrite && $0.phase == .finished }.map(\.outcome) } == [.success, .noChange])
    }
    @Test func dualSimulationWritesAndUnplugAreIsolated() async throws {
        let hub = SimulatedKeyboardHub(scenario: .named("dual"))
        let keyboards = await hub.keyboards()
        #expect(keyboards.count == 2)
        let configurator = KeyboardConfigurator(channels: ExclusiveChannelProvider(base: hub))
        _ = try await configurator.apply(.activate(0), on: keyboards[0])
        #expect(try await configurator.configuration(of: keyboards[1]).activeProfile == 1)
        hub.unplug()
        #expect(await hub.keyboards().map(\.id) == [SimulatedKeyboardHub.secondKeyboardID])
        #expect(try await configurator.configuration(of: keyboards[1]).activeProfile == 1)
        hub.plug()
        #expect(await hub.keyboards().count == 2)
    }
}
