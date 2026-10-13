import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("设置与实验性功能")
struct SettingsFeatureTests {
    @Test func enablingCustomFirmwareRequiresAcknowledgement() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
        }

        await store.send(.customFirmwareToggled(true)) {
            $0.isConfirmingCustomFirmware = true
        }
        // Confirming without ticking the box does nothing.
        await store.send(.confirmCustomFirmwareTapped)
        #expect(store.state.customFirmwareEnabled == false)

        await store.send(.binding(.set(\.riskAcknowledged, true))) {
            $0.riskAcknowledged = true
        }
        await store.send(.confirmCustomFirmwareTapped) {
            $0.$customFirmwareEnabled.withLock { $0 = true }
            $0.isConfirmingCustomFirmware = false
        }

        // Turning it off needs no confirmation.
        await store.send(.customFirmwareToggled(false)) {
            $0.$customFirmwareEnabled.withLock { $0 = false }
        }
    }

    @Test func cancellingTheRiskSheetKeepsTheSectionHidden() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
        }
        await store.send(.customFirmwareToggled(true)) { $0.isConfirmingCustomFirmware = true }
        await store.send(.binding(.set(\.riskAcknowledged, true))) { $0.riskAcknowledged = true }
        await store.send(.cancelCustomFirmwareTapped) {
            $0.isConfirmingCustomFirmware = false
            $0.riskAcknowledged = false
        }
        #expect(store.state.customFirmwareEnabled == false)
    }

    @Test func turningOffAutomaticChecksAlsoTurnsOffAutomaticDownloads() async {
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.appUpdateClient = AppUpdateClient(
                snapshot: { AppUpdateSnapshot(isAvailable: true, automaticallyChecks: false, automaticallyDownloads: false, canCheckNow: true, lastCheck: nil, version: "1.0.0 (1)") },
                setAutomaticallyChecks: { value in calls.withValue { $0.append("checks=\(value)") } },
                setAutomaticallyDownloads: { value in calls.withValue { $0.append("downloads=\(value)") } },
                checkForUpdates: {}
            )
            $0.loginItemClient = LoginItemClient(isEnabled: { false }, setEnabled: { _ in })
        }
        store.exhaustivity = .off
        await store.send(.automaticallyChecksChanged(false))
        await store.finish()
        #expect(calls.value == ["checks=false", "downloads=false"])
        #expect(store.state.update.automaticallyDownloads == false)
    }

    @Test func loginItemFailureRestoresTheActualState() async {
        struct Denied: Error {}
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.defaultAppStorage = Self.isolatedDefaults()
            $0.loginItemClient = LoginItemClient(isEnabled: { false }, setEnabled: { _ in throw Denied() })
        }
        await store.send(.launchAtLoginChanged(true)) { $0.launchAtLogin = true }
        await store.receive(\.loginItemFailed) {
            $0.launchAtLogin = false
            $0.loginItemError = Denied().localizedDescription
        }
    }

    @Test func experimentalSectionVisibility() {
        withDependencies {
            $0.defaultAppStorage = Self.isolatedDefaults()
        } operation: {
            var state = KeyboardFeature.State(keyboard: .preview)
            state.section = .customFirmware
            #expect(!state.visibleSections.contains(.customFirmware))
            #expect(state.displayedSection == .info, "hidden section falls back to the overview")

            state.$customFirmwareEnabled.withLock { $0 = true }
            #expect(state.visibleSections.contains(.customFirmware))
            #expect(state.displayedSection == .customFirmware)
        }
    }

    @Test func menuBarLabelFollowsTheBatteryPreference() {
        withDependencies {
            $0.defaultAppStorage = Self.isolatedDefaults()
        } operation: {
            var state = MenuBarFeature.State()
            state.keyboards = [.preview]
            state.snapshot = .loaded(.preview)
            state.snapshotID = KeyboardSummary.preview.id
            #expect(state.labelText == "95%")
            state.$showsBatteryInLabel.withLock { $0 = false }
            #expect(state.labelText == nil)
            #expect(state.labelAccessibilityValue == "95%", "VoiceOver still hears the level")
        }
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suite = "online.odeployer.CherryUtility.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
