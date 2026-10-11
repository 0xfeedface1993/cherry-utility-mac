import CherryCore
import ComposableArchitecture
import Foundation
import Testing
@testable import CherryFeatures

@MainActor
@Suite("业务分支与竞态回归")
struct BranchTests {
    @Test func busyFlashIgnoresLateFileSelection() async {
        var state = FirmwareFeature.State(keyboard: .preview)
        state.package = .loaded(FirmwareFeatureTests.package)
        state.phase = .flashing(sent: 2, total: 10, percent: 20)
        let store = TestStore(initialState: state) { FirmwareFeature() } withDependencies: {
            $0.firmwareClient.loadLocal = { _ in throw CherryError.firmwareFormat("晚到的文件") }
        }
        await store.send(.localFileSelected(.success(URL(fileURLWithPath: "/tmp/late.exe"))))
        await store.finish()
    }

    @Test func busyFlashIgnoresLatePackageResult() async {
        var state = FirmwareFeature.State(keyboard: .preview)
        state.package = .loaded(FirmwareFeatureTests.package)
        state.phase = .waitingForReboot(.confirmed)
        let store = TestStore(initialState: state) { FirmwareFeature() }
        await store.send(.packageLoaded(.failure(CherryError.network("旧下载失败"))))
    }

    @Test func disconnectIgnoresLateBatteryResult() async throws {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loaded(.preview)
        let store = TestStore(initialState: state) { DeviceInfoFeature() }
        await store.send(.keyboardUpdated(nil)) { $0.isConnected = false; $0.configurationRevision += 1; $0.loadGeneration += 1 }
        await store.send(.batteryLoaded(.success(try BatteryStatus(raw: [20, 0]))))
    }

    @Test func disconnectedInfoIgnoresRefreshAndLateHIDResults() async {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.isConnected = false
        let store = TestStore(initialState: state) { DeviceInfoFeature() }
        await store.send(.refresh)
        await store.send(.batteryTick)
        await store.send(.vendorLoaded(.success(.preview)))
        await store.send(.firmwareLoaded(.failure(CherryError.disconnected)))
    }

    @Test func batteryTimerUpdatesOnlyBatteryAndStopsWithViewTask() async throws {
        let clock = TestClock()
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loaded(.preview)
        let battery = try BatteryStatus(raw: [30, 2])
        let date = Date(timeIntervalSince1970: 100)
        let store = TestStore(initialState: state) { DeviceInfoFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.keyboardClient.battery = { _ in battery }
            $0.date.now = date
        }
        let task = await store.send(.task)
        await clock.advance(by: .seconds(29))
        #expect(store.state.lastUpdated == nil)
        await clock.advance(by: .seconds(1))
        await store.receive(\.batteryTick)
        await store.receive(\.batteryLoaded) {
            $0.vendor = .loaded(VendorSnapshot.preview.with(battery: battery))
            $0.lastUpdated = date
        }
        await task.cancel()
    }

    @Test func disconnectCancelsInFlightBatteryPoll() async {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loaded(.preview)
        let store = TestStore(initialState: state) { DeviceInfoFeature() } withDependencies: {
            $0.keyboardClient.battery = { _ in try await Task.never() }
        }
        await store.send(.batteryTick)
        await store.send(.keyboardUpdated(nil)) { $0.isConnected = false; $0.configurationRevision += 1; $0.loadGeneration += 1 }
        await store.finish()
    }

    @Test func unsupportedInfoAndFirmwareDoNotCallClients() async {
        let keyboard = KeyboardSummary(id: KeyboardID(vendorID: 1, productID: 2, locationID: 3), product: "Unknown", manufacturer: "", serialNumber: nil, transport: "USB", releaseNumber: 0, interfaces: [])
        let info = TestStore(initialState: DeviceInfoFeature.State(keyboard: keyboard)) { DeviceInfoFeature() }
        await info.send(.refresh) {
            $0.vendor = .failed(CherryError.unsupportedModel.userMessage)
            $0.firmware = .failed(CherryError.unsupportedModel.userMessage)
        }
        let firmware = TestStore(initialState: FirmwareFeature.State(keyboard: keyboard)) { FirmwareFeature() }
        await firmware.send(.refreshLatest) { $0.latest = .failed(CherryError.unsupportedModel.userMessage) }
        await firmware.send(.downloadTapped)
    }

    @Test func failedBatteryPollKeepsLastGoodSnapshot() async {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.vendor = .loaded(.preview)
        let store = TestStore(initialState: state) { DeviceInfoFeature() }
        await store.send(.batteryLoaded(.failure(CherryError.disconnected)))
    }

    @Test func packageFailureAndFlashFailureAreSurfaced() async {
        let store = TestStore(initialState: FirmwareFeature.State(keyboard: .preview)) { FirmwareFeature() }
        await store.send(.localFileSelected(.failure(CherryError.firmwareFormat("坏文件")))) {
            $0.package = .failed(CherryError.firmwareFormat("坏文件").userMessage)
        }
        await store.send(.packageLoaded(.failure(CherryError.network("失败")))) {
            $0.package = .failed(CherryError.network("失败").userMessage)
        }
        await store.send(.flashFinished(.failure(CherryError.otaFailed(status: 3)))) {
            $0.phase = .failed(CherryError.otaFailed(status: 3).userMessage)
        }
        await store.receive(\.readDeviceFirmware)
    }

    @Test(arguments: [FlashOutcome.confirmed, .deviceRebooted, .unconfirmed])
    func verificationUsesCRCForAllTransferOutcomes(_ outcome: FlashOutcome) async {
        for matches in [true, false] {
            var state = FirmwareFeature.State(keyboard: .preview)
            state.package = .loaded(FirmwareFeatureTests.package)
            state.phase = .waitingForReboot(outcome)
            let status = DeviceFirmwareStatus(version: 0, crc: matches ? FirmwareFeatureTests.package.image.embeddedCRC : 0)
            let store = TestStore(initialState: state) { FirmwareFeature() }
            await store.send(.verifyFinished(outcome: outcome, .success(status))) {
                $0.deviceFirmware = .loaded(status)
                $0.phase = .finished(outcome: outcome, firmware: status, matches: matches)
            }
        }
    }

    @Test func failedReadBackIsNotShownAsSuccessfulUpgrade() async {
        var state = FirmwareFeature.State(keyboard: .preview)
        state.phase = .waitingForReboot(.confirmed)
        let store = TestStore(initialState: state) { FirmwareFeature() }
        await store.send(.verifyFinished(outcome: .confirmed, .failure(CherryError.disconnected))) {
            $0.phase = .failed("刷写已完成，但重新读取设备固件失败：设备已断开")
        }
    }

    @Test func confirmationRechecksConnectionAndBusyStateBlocksPackageChanges() async {
        var state = FirmwareFeature.State(keyboard: .preview)
        state.package = .loaded(FirmwareFeatureTests.package)
        state.alert = FirmwareFeature.confirmation(package: FirmwareFeatureTests.package, keyboard: .preview, sameImage: false)
        state.isConnected = false
        let store = TestStore(initialState: state) { FirmwareFeature() }
        await store.send(.alert(.presented(.confirmFlash))) { $0.alert = nil }
        var busy = FirmwareFeature.State(keyboard: .preview)
        busy.phase = .verifyingImage
        let busyStore = TestStore(initialState: busy) { FirmwareFeature() }
        await busyStore.send(.downloadTapped)
        await busyStore.send(.importTapped)
        await busyStore.send(.localFileSelected(.failure(CherryError.disconnected)))
    }

    @Test func captureFailureReleasesPressedKeysAndSuppression() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: KeyEvent.self)
        var state = KeyTestFeature.State(keyboard: .preview)
        state.access = .granted
        state.pressed = [.keyboard(4)]
        let store = TestStore(initialState: state) { KeyTestFeature() } withDependencies: {
            $0.keyTestClient.keyEvents = { _ in stream }
            $0.keyTestClient.suppressAppKeyEvents = { try? await Task.never() }
        }
        await store.send(.startCapture) { $0.isCapturing = true }
        continuation.finish(throwing: CherryError.disconnected)
        await store.receive(\.captureEnded) {
            $0.isCapturing = false
            $0.pressed = []
            $0.captureError = "设备已断开"
        }
        await store.finish()
    }

    @Test func permissionResponseRechecksActualSystemStatus() async {
        let store = TestStore(initialState: KeyTestFeature.State(keyboard: .preview)) { KeyTestFeature() } withDependencies: {
            $0.keyTestClient.requestAccess = { false }
            $0.keyTestClient.accessStatus = { .denied }
            $0.keyTestClient.openAccessSettings = {}
        }
        await store.send(.requestAccessTapped)
        await store.receive(\.accessResponse)
        await store.receive(\.accessChecked) { $0.access = .denied }
        await store.send(.openSettingsTapped)
        await store.finish()
    }

    @Test func eventLogKeepsOnlyNewestFortyEvents() async {
        let store = TestStore(initialState: KeyTestFeature.State(keyboard: .preview)) { KeyTestFeature() }
        store.exhaustivity = .off
        for i in 1...45 {
            await store.send(.keyEvent(KeyEvent(usage: .keyboard(4), isDown: i % 2 == 1, timestamp: UInt64(i) * 1_000_000)))
        }
        #expect(store.state.log.count == 40)
        #expect(store.state.log.first?.id == 45 && store.state.log.last?.id == 6)
        #expect(store.state.eventCount == 45 && store.state.maxSimultaneous == 1)
        #expect(store.state.testedLayoutCount == 1)
    }

    @Test func appSelectionClearsIdleDetailAndIgnoresSameSelection() async {
        var state = AppFeature.State()
        state.keyboards = [.preview]
        state.detail = KeyboardFeature.State(keyboard: .preview)
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.selectKeyboard(KeyboardSummary.preview.id))
        await store.send(.selectKeyboard(nil)) { $0.detail = nil }
        await store.send(.selectKeyboard(KeyboardSummary.preview.id)) { $0.detail = KeyboardFeature.State(keyboard: .preview) }
    }

    @Test func profileEditorRebasesUntouchedFieldsAndSavesOnlyDirtyFields() throws {
        let base = VendorSnapshot.preview.profile.settings
        var editor = ProfileEditor(base: base)
        #expect(editor.beginSave() == nil)
        editor.edit { $0.brightness = base.brightness == 4 ? 3 : 4 }
        #expect(editor.dirty == [.brightness])
        var remote = base; remote.speed = base.speed == 4 ? 3 : 4
        editor.rebase(onto: remote)
        #expect(editor.draft.speed == remote.speed && editor.dirty == [.brightness])
        let begun = editor.beginSave() // mutating calls cannot run inside #require
        let patch = try #require(begun)
        #expect(patch.fields == [.brightness] && editor.isSaving)
        let duringSave = editor.draft
        editor.edit { $0.color = LEDColor(r: 1, g: 2, b: 3) }
        #expect(editor.draft == duringSave && editor.beginSave() == nil)
        editor.saveSucceeded(patch.applied(to: remote))
        #expect(!editor.hasUnsavedChanges && !editor.isSaving)
    }

    @Test func profileEditorRetainsFailedDraftAndCanDiscard() {
        let base = VendorSnapshot.preview.profile.settings
        var editor = ProfileEditor(base: base)
        var draft = base; draft.color = LEDColor(r: 1, g: 2, b: 3)
        editor.replaceDraft(with: draft)
        _ = editor.beginSave()
        editor.saveFailed()
        #expect(editor.draft == draft && editor.dirty == [.color] && !editor.isSaving)
        editor.discard()
        #expect(editor.draft == base && !editor.hasUnsavedChanges)
    }
}
