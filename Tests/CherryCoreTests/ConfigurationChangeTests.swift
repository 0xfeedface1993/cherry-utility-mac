import CherryCore
import Testing

@Suite("配置读回与意图合并领域语义")
struct ConfigurationChangeTests {
    @Test func mergingKeepsOtherFieldsAndNewestDeclaredValue() {
        let settings = ProfileSettings(effect: 0, brightness: 4, speed: 2, randomColor: false, color: .init(r: 1, g: 2, b: 3), sleepSeconds: 60, deepSleepMinutes: 30)
        let a = ProfilePatch.set(\.brightness, 0, field: .brightness, on: settings)
        let b = ProfilePatch.set(\.speed, 0, field: .speed, on: settings)
        let c = ProfilePatch.set(\.brightness, 2, field: .brightness, on: settings)
        let patch = a.merging(b).merging(c)
        #expect(patch.fields == [.brightness, .speed])
        let result = patch.applied(to: settings)
        #expect(result.brightness == 2 && result.speed == 0)
        #expect(result.effect == settings.effect && result.color == settings.color)
    }
}
