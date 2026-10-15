import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

enum MultiModelFeatureFixtures {
    /// The preview keyboard re-badged as `productID`, without the OTA interface when the model has none.
    static func keyboard(_ productID: UInt16) -> KeyboardSummary {
        let preview = KeyboardSummary.preview
        let model = KeyboardModel.matching(vendorID: 0x046A, productID: productID)
        return KeyboardSummary(
            id: KeyboardID(vendorID: 0x046A, productID: productID, locationID: preview.id.locationID),
            product: model?.name ?? "Keyboard", manufacturer: "CHERRY", serialNumber: nil, transport: "USB", releaseNumber: 0x0110,
            interfaces: preview.interfaces.filter { model?.ota != nil || !$0.has(usagePage: 0xFFEF) }
        )
    }

    /// What a wired-only board returns: configuration only.
    static let wiredSnapshot = VendorSnapshot(battery: nil, status: nil, configuration: .preview)

    static let base = ProfileSettings(effect: 0, brightness: 2, speed: 2, randomColor: false, color: .white, sleepSeconds: 300, deepSleepMinutes: 30)

    static func configurationState(_ productID: UInt16, draft: ProfileSettings = base) -> ConfigurationFeature.State {
        var state = ConfigurationFeature.State(keyboard: keyboard(productID))
        state.configuration = .loaded(.preview)
        state.selectedProfile = 1
        var editor = ProfileEditor(base: base)
        editor.replaceDraft(with: draft)
        state.editor = editor
        return state
    }
}

@MainActor
@Suite("多型号：界面按能力呈现")
struct MultiModelFeatureTests {
    @Test func configurationShowsOnlyWhatTheModelCanStore() {
        let wired = MultiModelFeatureFixtures.configurationState(0x0079)
        #expect(wired.lightingPresentation?.showsColor == true && wired.powerPresentation == nil)

        let singleColor = MultiModelFeatureFixtures.configurationState(0x00B4)
        #expect(singleColor.lightingPresentation?.showsColor == false)
        #expect(singleColor.lightingPresentation?.effects.map(\.id) == [0, 2, 18, 21, 3, 8])

        let noBacklight = MultiModelFeatureFixtures.configurationState(0x0077)
        #expect(noBacklight.lightingPresentation == nil && noBacklight.powerPresentation == nil)

        let pixiu75 = MultiModelFeatureFixtures.configurationState(0x01E2)
        #expect(pixiu75.lightingPresentation != nil && pixiu75.powerPresentation != nil)
    }

    @Test func customEffectHintFollowsTheModelsNumbering() {
        var draft = MultiModelFeatureFixtures.base
        draft.effect = 4
        #expect(MultiModelFeatureFixtures.configurationState(0x01E6, draft: draft).lightingPresentation?.isCustomEffect == true)
        draft.effect = 8
        // Breathing on type-B boards, Custom on the PIXIU 75.
        #expect(MultiModelFeatureFixtures.configurationState(0x01E6, draft: draft).lightingPresentation?.isCustomEffect == false)
        #expect(MultiModelFeatureFixtures.configurationState(0x01E2, draft: draft).lightingPresentation?.isCustomEffect == true)
    }

    @Test func loadingAPresetOnlyTouchesFieldsTheModelCanStore() async {
        let preset = ProfilePreset(
            name: "全局", createdAt: Date(timeIntervalSince1970: 0), productID: nil,
            settings: ProfileSettings(effect: 18, brightness: 4, speed: 1, randomColor: true, color: .white, sleepSeconds: 60, deepSleepMinutes: 15)
        )
        var state = MultiModelFeatureFixtures.configurationState(0x0079)
        state.presets = .loaded([preset])
        let store = TestStore(initialState: state) { ConfigurationFeature() }
        store.exhaustivity = .off
        await store.send(.loadPresetTapped(preset.id))
        let dirty = store.state.editor?.dirty ?? []
        #expect(dirty == [.effect, .brightness, .speed, .randomColor])
        #expect(store.state.editor?.draft.sleepSeconds == 300)
    }

    @Test func menuBarHidesBatteryAndColorWhereTheModelHasNone() {
        var state = MenuBarFeature.State()
        let wired = MultiModelFeatureFixtures.keyboard(0x0079)
        state.keyboards = [wired]
        state.snapshot = .loaded(MultiModelFeatureFixtures.wiredSnapshot)
        state.snapshotID = wired.id
        #expect(state.statusPresentation?.showsBattery == false)
        #expect(state.statusPresentation?.connection == "USB")
        #expect(state.labelText == nil && state.labelAccessibilityValue == "有线")
        #expect(state.lightingPresentation?.showsLighting == true && state.lightingPresentation?.showsColor == true)

        let noBacklight = MultiModelFeatureFixtures.keyboard(0x0077)
        state.keyboards = [noBacklight]
        state.snapshotID = noBacklight.id
        #expect(state.lightingPresentation?.showsLighting == false)
        #expect(state.lightingPresentation?.profiles.count == 3)
    }

    @Test func firmwarePageExplainsModelsItCannotFlash() async {
        let release = FirmwareRelease(
            name: "MX_BOARD_3.0S_FL_RGB_0136", deviceIndex: 4, versionCode: "0136", versionName: "0.1.3.6",
            downloadURL: URL(string: "https://example.invalid/x.exe")!, md5: "00", isForced: false
        )
        var state = FirmwareFeature.State(keyboard: MultiModelFeatureFixtures.keyboard(0x0079))
        state.latest = .loaded(release)
        #expect(state.flashUnsupportedReason?.contains("Sonix") == true)
        let store = TestStore(initialState: state) { FirmwareFeature() }
        // Neither entry point starts a download or a file dialog.
        await store.send(.downloadTapped)
        await store.send(.importTapped)
        #expect(FirmwareFeature.State(keyboard: .preview).flashUnsupportedReason == nil)
        #expect(FirmwareFeature.State(keyboard: MultiModelFeatureFixtures.keyboard(0x01F3)).flashUnsupportedReason?.contains("没有") == true)
    }

    @Test func overviewDoesNotReadFirmwareCRCWithoutAnOTAInterface() async {
        let store = TestStore(initialState: DeviceInfoFeature.State(keyboard: MultiModelFeatureFixtures.keyboard(0x0079))) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in MultiModelFeatureFixtures.wiredSnapshot }
            // firmwareStatus and battery stay unimplemented: calling them fails the test.
            $0.firmwareClient.latestRelease = { _ in nil }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.refresh)
        await store.finish()
        await store.skipReceivedActions()
        #expect(store.state.vendor == .loaded(MultiModelFeatureFixtures.wiredSnapshot))
        #expect(store.state.firmware == .idle)
        await store.send(.batteryTick)
    }
}
