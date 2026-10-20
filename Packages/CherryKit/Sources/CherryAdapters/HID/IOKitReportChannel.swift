import CherryCore
import Foundation
import IOKit
import IOKit.hid

/// `HIDReportChannel` over one IOHIDDevice: output reports via `IOHIDDeviceSetReport`, input reports
/// routed by `LoopState` into this channel's `ReportMailbox` while it is open.
final class IOKitReportChannel: HIDReportChannel, Sendable {
    let outputReportLength: Int
    let inputReportIDs: Set<UInt8>
    private let loop: HIDEventLoop
    private let resources: Resources

    /// IOKit side of the channel; only touched on the HID thread (the mailbox is thread-safe on its own).
    private final class Resources: @unchecked Sendable {
        let device: IOHIDDevice
        let registryID: UInt64
        let state: LoopState
        let mailbox: ReportMailbox
        let removalToken = UUID()
        var isOpen = true

        init(device: IOHIDDevice, state: LoopState, diagnostics: Diagnostics) {
            self.device = device
            self.registryID = HIDProperties.registryID(device)
            self.state = state
            mailbox = ReportMailbox(diagnostics: diagnostics)
        }

        /// HID thread only. Idempotent.
        func teardown(deviceRemoved: Bool) {
            guard isOpen else { return }
            isOpen = false
            mailbox.close()
            guard !deviceRemoved else { return } // LoopState already dropped everything for this device
            state.routeInputReports(of: device, token: removalToken, to: nil)
            state.stopObservingRemoval(of: registryID, token: removalToken)
            state.releaseOpen(device)
            state.busyInterfaces.remove(registryID)
        }
    }

    private init(outputReportLength: Int, inputReportIDs: Set<UInt8>, loop: HIDEventLoop, resources: Resources) {
        self.outputReportLength = outputReportLength
        self.inputReportIDs = inputReportIDs
        self.loop = loop
        self.resources = resources
    }

    /// HID thread only.
    static func open(device: IOHIDDevice, usagePage: UInt16, reportID: UInt8, loop: HIDEventLoop, state: LoopState) throws -> IOKitReportChannel {
        let registryID = HIDProperties.registryID(device)
        guard !state.busyInterfaces.contains(registryID) else { throw CherryError.ioFailed("接口正被另一个操作占用") }

        // Same numbers Windows' HidP_GetCaps gives the official tools, from the collection that owns the page.
        let summary = HIDProperties.interfaceSummary(device)
        let collection = summary.collections.first { $0.usage.page == usagePage }
        let outputLength = collection?.outputReports[reportID] ?? collection?.outputReports.values.max() ?? summary.maxOutputReportSize
        var inputIDs = Set(collection.map { Array($0.inputReports.keys) } ?? [])
        if inputIDs.isEmpty { inputIDs = [reportID] }

        try state.acquireOpen(device)
        let resources = Resources(device: device, state: state, diagnostics: loop.diagnostics)
        let mailbox = resources.mailbox
        state.routeInputReports(of: device, token: resources.removalToken) { mailbox.push($0) }
        state.observeRemoval(of: registryID, token: resources.removalToken) { [resources] in
            resources.teardown(deviceRemoved: true)
        }
        state.busyInterfaces.insert(registryID)
        return IOKitReportChannel(outputReportLength: outputLength, inputReportIDs: inputIDs, loop: loop, resources: resources)
    }

    deinit {
        let resources = self.resources
        loop.execute { resources.teardown(deviceRemoved: false) }
    }

    func send(_ report: [UInt8]) async throws {
        let resources = self.resources
        try await loop.run {
            guard resources.isOpen else { throw CherryError.disconnected }
            try self.loop.diagnostics.measure(.hidSend, metrics: .init(bytes: UInt64(report.count))) {
                let rc = report.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(resources.device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, $0.count)
                }
                guard rc == kIOReturnSuccess else {
                    if rc == kIOReturnNotAttached || rc == kIOReturnNoDevice || rc == kIOReturnAborted { throw CherryError.disconnected }
                    throw CherryError.ioFailed(String(format: "IOHIDDeviceSetReport 0x%08X", UInt32(bitPattern: rc)))
                }
            }
        }
    }

    func receive(timeout: Duration) async throws -> [UInt8]? {
        try await resources.mailbox.next(timeout: timeout)
    }

    func discardPending() async {
        resources.mailbox.drain()
    }

    func close() async {
        let resources = self.resources
        _ = try? await loop.run { resources.teardown(deviceRemoved: false) }
    }
}

/// Key down/up events of one keyboard, decoded from the raw input reports of its keyboard / consumer
/// interfaces (IOKit's per-value callbacks don't fire for these interfaces).
final class KeyEventSubscription: @unchecked Sendable {
    // HID thread only, except `continuation` which is thread-safe.
    private let continuation: AsyncThrowingStream<Traced<KeyEvent>, any Error>.Continuation
    private let observation: KeyCaptureDiagnostics
    private var devices: [IOHIDDevice] = []
    private var state: LoopState?
    private var tracker = KeyStateTracker()
    private var stopped = false
    private let token = UUID()
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(continuation: AsyncThrowingStream<Traced<KeyEvent>, any Error>.Continuation, diagnostics: Diagnostics = .noop) {
        self.continuation = continuation
        observation = KeyCaptureDiagnostics(diagnostics)
    }

    func start(keyboard: KeyboardID, state: LoopState) {
        guard !stopped else { return }
        self.state = state
        let targets = state.devices(of: keyboard).compactMap { device -> (IOHIDDevice, HIDInputDecoder)? in
            let decoder = HIDInputDecoder(descriptor: HIDProperties.descriptor(device))
            return decoder.fields.isEmpty ? nil : (device, decoder)
        }
        guard !targets.isEmpty else {
            observation.finish(error: CherryError.deviceNotFound(keyboard))
            continuation.finish(throwing: CherryError.deviceNotFound(keyboard))
            return
        }
        for (index, (device, decoder)) in targets.enumerated() {
            do {
                try state.acquireOpen(device)
            } catch {
                observation.finish(error: error)
                stop()
                continuation.finish(throwing: error)
                return
            }
            devices.append(device)
            state.routeInputReports(of: device, token: token) { [weak self] report in
                self?.handle(report, decoder: decoder, interface: index)
            }
            state.observeRemoval(of: HIDProperties.registryID(device), token: token) { [weak self] in
                guard let self else { return }
                let gone = HIDProperties.registryID(device)
                self.devices.removeAll { HIDProperties.registryID($0) == gone }
                self.observation.finish(.disconnected)
                self.continuation.finish(throwing: CherryError.disconnected)
                self.stop()
            }
        }
    }

    private func handle(_ report: [UInt8], decoder: HIDInputDecoder, interface: Int) {
        let stamp = observation.stamp()
        guard let decoded = decoder.pressedUsages(in: report) else { return }
        observation.decoded(since: stamp)
        let nanos = mach_absolute_time() * UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
        let events = tracker.update(source: interface << 8 | Int(decoded.reportID), pressed: decoded.usages, timestamp: nanos)
        for event in events {
            observation.yielded(continuation.yield(Traced(event, stamp: stamp)))
        }
    }

    /// HID thread only. Idempotent.
    func stop() {
        guard !stopped else { return }
        stopped = true
        observation.finish(.stopped)
        for device in devices {
            state?.routeInputReports(of: device, token: token, to: nil)
            state?.stopObservingRemoval(of: HIDProperties.registryID(device), token: token)
            state?.releaseOpen(device)
        }
        devices.removeAll()
    }
}
