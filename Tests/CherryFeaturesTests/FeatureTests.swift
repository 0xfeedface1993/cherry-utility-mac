import CherryCore
import ComposableArchitecture
import Foundation
import Synchronization
import Testing
@testable import CherryFeatures

@MainActor
@Suite("KeyTestFeature")
struct KeyTestFeatureTests {
    @Test func tracksPressedTestedAndRollover() async {
        let store = TestStore(initialState: KeyTestFeature.State(keyboard: .preview)) {
            KeyTestFeature()
        }
        store.exhaustivity = .off

        await store.send(.keyEvent(KeyEvent(usage: .keyboard(0x04), isDown: true, timestamp: 1_000_000))) {
            $0.pressed = [.keyboard(0x04)]
            $0.tested = [.keyboard(0x04)]
            $0.maxSimultaneous = 1
        }
        await store.send(.keyEvent(KeyEvent(usage: .keyboard(0x05), isDown: true, timestamp: 3_000_000))) {
            $0.pressed = [.keyboard(0x04), .keyboard(0x05)]
            $0.maxSimultaneous = 2
        }
        await store.send(.keyEvent(KeyEvent(usage: .keyboard(0x04), isDown: false, timestamp: 4_500_000))) {
            $0.pressed = [.keyboard(0x05)]
        }
        #expect(store.state.testedLayoutCount == 2)
        #expect(store.state.log.first?.label == "A")
        #expect(store.state.log.first?.isDown == false)
        #expect(store.state.log.first?.deltaMs == 1.5)

        await store.send(.resetTapped) {
            $0.pressed = []
            $0.tested = []
            $0.maxSimultaneous = 0
            $0.log = []
        }
    }

    @Test func latencyIsMeasuredInTheEffectFromTheAdapterStamp() async throws {
        let events = Mutex<[DiagnosticEvent]>([])
        let port = Diagnostics.recording { event in events.withLock { $0.append(event) } }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Traced<KeyEvent>.self)
        var state = KeyTestFeature.State(keyboard: .preview)
        state.access = .granted
        state.suppressAppShortcuts = false
        let store = TestStore(initialState: state) { KeyTestFeature() } withDependencies: {
            $0.diagnostics = port
            $0.keyTestClient.keyEvents = { _ in stream }
        }
        store.exhaustivity = .off
        await store.send(.startCapture)
        let session = TraceContext(origin: .keytest)
        continuation.yield(Traced(KeyEvent(usage: .keyboard(4), isDown: true, timestamp: 1), stamp: port.stamp(context: session)))
        await store.receive(\.keyEvent)
        continuation.finish()
        await store.receive(\.captureEnded)
        let recorded = events.withLock { $0 }
        #expect(recorded.map(\.operation) == [.keyDispatch, .keyPipeline])
        #expect(recorded.allSatisfy { $0.context == session && $0.phase == .summary })
        // reducer 不读时钟、不写观测：直接发送按键只改状态。
        await store.send(.keyEvent(KeyEvent(usage: .keyboard(5), isDown: true, timestamp: 2)))
        #expect(events.withLock { $0.count } == 2)
    }

    @Test func startsCaptureWhenAccessGrantedAndStopsOnDisappear() async {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: Traced<KeyEvent>.self)
        let store = TestStore(initialState: KeyTestFeature.State(keyboard: .preview)) {
            KeyTestFeature()
        } withDependencies: {
            $0.keyTestClient.accessStatus = { .granted }
            $0.keyTestClient.keyEvents = { _ in events }
            $0.keyTestClient.suppressAppKeyEvents = { try? await Task.never() }
        }

        await store.send(.task)
        await store.receive(\.accessChecked) { $0.access = .granted }
        await store.receive(\.startCapture) { $0.isCapturing = true }

        continuation.yield(Traced(KeyEvent(usage: .consumer(0xE9), isDown: true, timestamp: 1)))
        await store.receive(\.keyEvent) {
            $0.pressed = [.consumer(0xE9)]
            $0.tested = [.consumer(0xE9)]
            $0.maxSimultaneous = 1
            $0.eventCount = 1
            $0.log = [.init(id: 1, usage: .consumer(0xE9), label: "⟳", isDown: true, deltaMs: nil)]
            $0.lastTimestamp = 1
        }

        await store.send(.viewDisappeared) {
            $0.isCapturing = false
            $0.pressed = []
        }
    }

    @Test func doesNotCaptureWithoutAccess() async {
        let store = TestStore(initialState: KeyTestFeature.State(keyboard: .preview)) {
            KeyTestFeature()
        } withDependencies: {
            $0.keyTestClient.accessStatus = { .denied }
        }
        await store.send(.task)
        await store.receive(\.accessChecked) { $0.access = .denied }
    }
}

@MainActor
@Suite("DeviceInfoFeature")
struct DeviceInfoFeatureTests {
    @Test func refreshLoadsVendorFirmwareAndRelease() async {
        let release = FirmwareRelease(
            name: "MX_PIXIU75_WIRELESS_0120", deviceIndex: 60, versionCode: "0120", versionName: "0.1.2.0",
            downloadURL: URL(string: "https://example.invalid/x.exe")!, md5: "00", isForced: false
        )
        let store = TestStore(initialState: DeviceInfoFeature.State(keyboard: .preview)) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.keyboardClient.firmwareStatus = { _ in DeviceFirmwareStatus(version: 0, crc: 0xCFE1_A03E) }
            $0.firmwareClient.latestRelease = { _ in release }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off

        await store.send(.refresh) {
            $0.vendor = .loading
            $0.firmware = .loading
            $0.latestRelease = .loading
            $0.loadGeneration = 1
        }
        // The vendor/firmware and catalog effects run concurrently; assert the settled state.
        await store.finish()
        await store.skipReceivedActions()
        #expect(store.state.vendor == .loaded(.preview))
        #expect(store.state.firmware == .loaded(DeviceFirmwareStatus(version: 0, crc: 0xCFE1_A03E)))
        #expect(store.state.latestRelease == .loaded(release))
        #expect(store.state.lastUpdated == Date(timeIntervalSince1970: 0))
        #expect(store.state.updateAvailable == true)
    }

    @Test func refreshesAfterReconnect() async {
        var state = DeviceInfoFeature.State(keyboard: .preview)
        state.isConnected = false
        let store = TestStore(initialState: state) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.keyboardClient.vendorSnapshot = { _ in throw CherryError.disconnected }
            $0.keyboardClient.firmwareStatus = { _ in throw CherryError.disconnected }
            $0.firmwareClient.latestRelease = { _ in nil }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.keyboardUpdated(.preview)) { $0.isConnected = true }
        await store.receive(\.refresh)
        await store.finish()
        await store.skipReceivedActions()
        #expect(store.state.vendor == .failed(CherryError.disconnected.message))
        #expect(store.state.latestRelease == .loaded(nil))
    }
}

@MainActor
@Suite("FirmwareFeature")
struct FirmwareFeatureTests {
    static let package: FirmwarePackage = {
        var param = [UInt8](repeating: 0xFF, count: 256)
        param.replaceSubrange(64..<74, with: Array("046A01E205".utf8))
        param.replaceSubrange(80..<84, with: Array("FFEF".utf8))
        var fw = [UInt8](repeating: 0x11, count: 320)
        fw.replaceSubrange(0x18..<0x1C, with: [0x40, 0x01, 0, 0])
        let crc = Checksums.telinkCRC32(fw.dropLast(4))
        fw.replaceSubrange(316..<320, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        var code = [UInt8](repeating: 0, count: 256)
        code.replaceSubrange(48..<52, with: [0, 0, 0x01, 0x40])
        let image = try! UpdaterImage(param: param, code: code + fw)
        return FirmwarePackage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, source: .localFile(URL(fileURLWithPath: "/tmp/x.exe")), fileMD5: "AA", image: image)
    }()

    @Test func fullFlashFlowWithConfirmationAndVerification() async {
        let package = Self.package
        let newStatus = DeviceFirmwareStatus(version: 0, crc: package.image.embeddedCRC)
        let store = TestStore(initialState: FirmwareFeature.State(keyboard: .preview)) {
            FirmwareFeature()
        } withDependencies: {
            $0.firmwareClient.loadLocal = { _ in package }
            $0.firmwareClient.deviceFirmware = { _, _ in DeviceFirmwareStatus(version: 0, crc: 0xDEAD_BEEF) }
            $0.firmwareClient.flash = { _, _, progress in
                await progress(.started(totalReports: 3))
                await progress(.transferred(reports: 2, totalReports: 3, percent: 100))
                await progress(.verifying)
                return .confirmed
            }
            $0.firmwareClient.verifyAfterFlash = { _, _ in newStatus }
        }

        await store.send(.localFileSelected(.success(URL(fileURLWithPath: "/tmp/x.exe")))) { $0.package = .loading }
        await store.receive(\.packageLoaded) { $0.package = .loaded(package) }
        await store.receive(\.readDeviceFirmware) { $0.deviceFirmware = .loading }
        await store.receive(\.deviceFirmwareLoaded) { $0.deviceFirmware = .loaded(DeviceFirmwareStatus(version: 0, crc: 0xDEAD_BEEF)) }
        #expect(store.state.canFlash)
        #expect(store.state.deviceMatchesPackage == false)

        await store.send(.flashTapped) {
            $0.alert = FirmwareFeature.confirmation(package: package, keyboard: .preview, sameImage: false)
        }
        await store.send(.alert(.presented(.confirmFlash))) {
            $0.alert = nil
            $0.phase = .flashing(sent: 0, total: 0, percent: 0)
        }
        await store.receive(\.flashProgress) { $0.phase = .flashing(sent: 0, total: 3, percent: 0) }
        await store.receive(\.flashProgress) { $0.phase = .flashing(sent: 2, total: 3, percent: 100) }
        await store.receive(\.flashProgress) { $0.phase = .verifyingImage }
        await store.receive(\.flashFinished) { $0.phase = .waitingForReboot(.confirmed) }
        await store.receive(\.verifyFinished) {
            $0.deviceFirmware = .loaded(newStatus)
            $0.phase = .finished(outcome: .confirmed, firmware: newStatus, matches: true)
        }
    }

    @Test func refusesIncompatiblePackage() async {
        var keyboard = KeyboardSummary.preview
        keyboard = KeyboardSummary(
            id: KeyboardID(vendorID: 0x046A, productID: 0x0999, locationID: 1), product: "Other", manufacturer: "CHERRY",
            serialNumber: nil, transport: "USB", releaseNumber: 0x100, interfaces: keyboard.interfaces
        )
        var state = FirmwareFeature.State(keyboard: keyboard)
        state.package = .loaded(Self.package)
        let store = TestStore(initialState: state) { FirmwareFeature() }
        #expect(!store.state.canFlash)
        #expect(store.state.incompatibilities.count == 1)
        await store.send(.flashTapped)
    }

    @Test func flagsSameVersionDifferentImageAsModified() {
        let release = FirmwareRelease(
            name: "MX_PIXIU75_WIRELESS_0117", deviceIndex: 60, versionCode: "0117", versionName: "0.1.1.7",
            downloadURL: URL(string: "https://example.invalid/x.exe")!, md5: "AA", isForced: false
        )
        var state = FirmwareFeature.State(keyboard: .preview) // bcdDevice 0x0117
        state.package = .loaded(FirmwarePackage(source: .catalog(release), fileMD5: "AA", image: Self.package.image))
        state.deviceFirmware = .loaded(DeviceFirmwareStatus(version: 0, crc: 0x46F8_C57A)) // patched build
        #expect(state.deviceRunsModifiedFirmware)
        state.deviceFirmware = .loaded(DeviceFirmwareStatus(version: 0, crc: Self.package.image.embeddedCRC))
        #expect(!state.deviceRunsModifiedFirmware)
    }

    @Test func busyFlowSurvivesDisconnect() async {
        var state = FirmwareFeature.State(keyboard: .preview)
        state.phase = .waitingForReboot(.deviceRebooted)
        let store = TestStore(initialState: state) { FirmwareFeature() }
        await store.send(.keyboardUpdated(nil)) { $0.isConnected = false }
        await store.send(.keyboardUpdated(.preview)) { $0.isConnected = true }
    }
}

@MainActor
@Suite("AppFeature")
struct AppFeatureTests {
    @Test func keepsDetailWhileBusyAndSelectsFirstKeyboard() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            // A newly attached keyboard is also read by the status item.
            $0.keyboardClient.vendorSnapshot = { _ in .preview }
            $0.date.now = Date(timeIntervalSince1970: 0)
        }
        store.exhaustivity = .off
        await store.send(.keyboardsUpdated([.preview])) {
            $0.keyboards = [.preview]
            $0.detail = KeyboardFeature.State(keyboard: .preview)
        }
        await store.send(.detail(.firmware(.flashProgress(.started(totalReports: 10))))) {
            $0.detail?.firmware.phase = .flashing(sent: 0, total: 10, percent: 0)
        }
        await store.send(.keyboardsUpdated([])) { $0.keyboards = [] }
        await store.receive(\.detail.keyboardUpdated) { $0.detail?.isConnected = false }
        #expect(store.state.detail != nil)
        await store.send(.selectKeyboard(nil))
        #expect(store.state.detail != nil) // selection is locked while flashing
    }
}
