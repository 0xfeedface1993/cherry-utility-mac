import CherryCore
import Foundation
import IOKit
import IOKit.hid

/// IOKit adapter for keyboard discovery, report channels and key events.
///
/// All IOKit objects live on `HIDEventLoop`'s thread. `LoopState` is only ever touched from blocks the
/// loop executes, which is what makes the `@unchecked Sendable` wrappers below sound.
public final class IOKitHIDService: KeyboardDiscoveryPort, ReportChannelProvider, KeyEventSource, Sendable {
    let loop: HIDEventLoop
    private let state: LoopState

    public init(loop: HIDEventLoop, vendorID: UInt16 = KeyboardModel.cherryVendorID) {
        self.loop = loop
        let state = LoopState()
        state.diagnostics = loop.diagnostics
        self.state = state
        loop.execute { state.start(loop: loop, vendorID: vendorID) }
    }

    // MARK: KeyboardDiscoveryPort

    public func keyboards() async -> [KeyboardSummary] {
        let state = self.state
        return (try? await loop.run { state.summaries() }) ?? []
    }

    public func keyboardUpdates() -> AsyncStream<[KeyboardSummary]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [KeyboardSummary].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let state = self.state
        loop.execute {
            state.subscribers[id] = continuation
            continuation.yield(state.summaries())
        }
        continuation.onTermination = { [loop] _ in
            loop.execute { state.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: ReportChannelProvider

    public func openChannel(keyboard: KeyboardID, usagePage: UInt16, reportID: UInt8) async throws -> any HIDReportChannel {
        let state = self.state
        let loop = self.loop
        return try await loop.run { () throws -> IOKitReportChannel in
            guard let device = state.device(keyboard: keyboard, usagePage: usagePage) else {
                throw state.summaries().contains(where: { $0.id == keyboard })
                    ? CherryError.interfaceNotFound(usagePage: usagePage)
                    : CherryError.deviceNotFound(keyboard)
            }
            return try IOKitReportChannel.open(device: device, usagePage: usagePage, reportID: reportID, loop: loop, state: state)
        }
    }

    // MARK: KeyEventSource

    public func keyEvents(keyboard: KeyboardID) -> AsyncThrowingStream<Traced<KeyEvent>, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Traced<KeyEvent>.self, bufferingPolicy: .bufferingNewest(512))
        let state = self.state
        let subscription = KeyEventSubscription(continuation: continuation, diagnostics: loop.diagnostics)
        loop.execute { subscription.start(keyboard: keyboard, state: state) }
        continuation.onTermination = { [loop] _ in
            loop.execute { subscription.stop() }
        }
        return stream
    }
}

// MARK: - Loop-confined state

/// Mutable HID state. Every member is accessed exclusively on the HID thread.
final class LoopState: @unchecked Sendable {
    var diagnostics: Diagnostics = .noop
    var manager: IOHIDManager?
    var devices: [UInt64: IOHIDDevice] = [:]
    var subscribers: [UUID: AsyncStream<[KeyboardSummary]>.Continuation] = [:]
    /// Interfaces with an open report channel (one report callback per IOHIDDevice).
    var busyInterfaces: Set<UInt64> = []
    /// IOHIDDeviceOpen is shared between users of the same interface (report channel + key events),
    /// so opens are reference counted and the device is closed by the last user only.
    private var openCounts: [UInt64: Int] = [:]
    /// Device-level removal callbacks are single-slot; removals are fanned out from the manager instead.
    private var removalObservers: [UInt64: [UUID: () -> Void]] = [:]

    /// Input routing. IOKit cannot unregister report callbacks (passing a nil callback is ignored, and per-value
    /// callbacks never fire for keyboard interfaces – both verified on macOS 27), so each device gets one static
    /// report callback, installed once, whose context is this long-lived object. Report channels and key
    /// subscriptions only add/remove themselves as sinks.
    typealias DeviceKey = UnsafeMutableRawPointer
    private var reportSinks: [DeviceKey: [UUID: ([UInt8]) -> Void]] = [:]
    private var reportBuffers: [DeviceKey: UnsafeMutablePointer<UInt8>] = [:]

    static func key(_ device: IOHIDDevice) -> DeviceKey {
        Unmanaged.passUnretained(device).toOpaque()
    }

    func routeInputReports(of device: IOHIDDevice, token: UUID, to sink: (([UInt8]) -> Void)?) {
        let key = Self.key(device)
        guard let sink else {
            reportSinks[key]?[token] = nil
            return
        }
        if reportBuffers[key] == nil {
            let size = max(HIDProperties.int(device, kIOHIDMaxInputReportSizeKey) ?? 0, 64)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            reportBuffers[key] = buffer
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, HIDCallbacks.inputReport, Unmanaged.passUnretained(self).toOpaque())
        }
        reportSinks[key, default: [:]][token] = sink
    }

    fileprivate func deliverReport(from sender: DeviceKey, _ report: [UInt8]) {
        guard let sinks = reportSinks[sender] else { return }
        for sink in sinks.values { sink(report) }
    }

    func acquireOpen(_ device: IOHIDDevice) throws {
        let id = HIDProperties.registryID(device)
        if openCounts[id, default: 0] == 0 {
            let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard rc == kIOReturnSuccess else { throw openFailure(rc) }
        }
        openCounts[id, default: 0] += 1
    }

    func releaseOpen(_ device: IOHIDDevice) {
        let id = HIDProperties.registryID(device)
        guard let count = openCounts[id] else { return } // already removed from the bus
        if count <= 1 {
            openCounts[id] = nil
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        } else {
            openCounts[id] = count - 1
        }
    }

    func observeRemoval(of registryID: UInt64, token: UUID, _ handler: @escaping () -> Void) {
        removalObservers[registryID, default: [:]][token] = handler
    }

    func stopObservingRemoval(of registryID: UInt64, token: UUID) {
        removalObservers[registryID]?[token] = nil
    }

    private func handleRemoval(_ device: IOHIDDevice) {
        let id = HIDProperties.registryID(device)
        let key = Self.key(device)
        devices[id] = nil
        openCounts[id] = nil
        busyInterfaces.remove(id)
        reportSinks[key] = nil
        // The device is gone, so IOKit will not write into its report buffer any more.
        reportBuffers.removeValue(forKey: key)?.deallocate()
        let observers = removalObservers.removeValue(forKey: id) ?? [:]
        for handler in observers.values { handler() }
        publish()
    }

    func start(loop: HIDEventLoop, vendorID: UInt16) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Int(vendorID)] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let state = Unmanaged<LoopState>.fromOpaque(context!).takeUnretainedValue()
            state.devices[HIDProperties.registryID(device)] = device
            state.publish()
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<LoopState>.fromOpaque(context!).takeUnretainedValue().handleRemoval(device)
        }, context)
        // Scheduling without IOHIDManagerOpen enumerates devices without opening them, so the app
        // does not trigger the Input Monitoring prompt until a feature actually needs input.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
    }

    func publish() {
        let list = summaries()
        var dropped: UInt64 = 0
        for continuation in subscribers.values {
            if case .dropped = continuation.yield(list) { dropped += 1 }
        }
        diagnostics.emit(.discovery, metrics: .init(count: UInt64(list.count), dropped: dropped))
    }

    func summaries() -> [KeyboardSummary] {
        let groups = Dictionary(grouping: devices.values) { HIDProperties.keyboardID($0) }
        return groups.map { id, devices in
            let sorted = devices.sorted { HIDProperties.registryID($0) < HIDProperties.registryID($1) }
            let first = sorted[0]
            return KeyboardSummary(
                id: id,
                product: HIDProperties.string(first, kIOHIDProductKey) ?? "Unknown",
                manufacturer: HIDProperties.string(first, kIOHIDManufacturerKey) ?? "",
                serialNumber: HIDProperties.string(first, kIOHIDSerialNumberKey).flatMap { $0.isEmpty ? nil : $0 },
                transport: HIDProperties.string(first, kIOHIDTransportKey) ?? "?",
                releaseNumber: UInt16(truncatingIfNeeded: HIDProperties.int(first, kIOHIDVersionNumberKey) ?? 0),
                interfaces: sorted.map(HIDProperties.interfaceSummary)
            )
        }
        .sorted { $0.id.locationID < $1.id.locationID }
    }

    func devices(of keyboard: KeyboardID) -> [IOHIDDevice] {
        devices.values.filter { HIDProperties.keyboardID($0) == keyboard }
    }

    func device(keyboard: KeyboardID, usagePage: UInt16) -> IOHIDDevice? {
        devices(of: keyboard).first { HIDProperties.interfaceSummary($0).has(usagePage: usagePage) }
    }
}

/// The only report callback ever registered with IOKit. Its context is the `LoopState`, which lives as
/// long as the HID service; `sender` is the IOHIDDevice the data came from.
enum HIDCallbacks {
    static let inputReport: IOHIDReportCallback = { context, _, sender, _, reportID, report, length in
        guard let context, let sender else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        // macOS hands numbered reports over with the ID byte; normalise defensively.
        if reportID != 0, bytes.first != UInt8(truncatingIfNeeded: reportID) {
            bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        Unmanaged<LoopState>.fromOpaque(context).takeUnretainedValue().deliverReport(from: sender, bytes)
    }
}

enum HIDProperties {
    static func int(_ d: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(d, key as CFString) as? Int
    }

    static func string(_ d: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(d, key as CFString) as? String
    }

    static func registryID(_ d: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &id)
        return id
    }

    static func keyboardID(_ d: IOHIDDevice) -> KeyboardID {
        KeyboardID(
            vendorID: UInt16(truncatingIfNeeded: int(d, kIOHIDVendorIDKey) ?? 0),
            productID: UInt16(truncatingIfNeeded: int(d, kIOHIDProductIDKey) ?? 0),
            locationID: UInt32(truncatingIfNeeded: int(d, kIOHIDLocationIDKey) ?? 0)
        )
    }

    static func descriptor(_ d: IOHIDDevice) -> [UInt8] {
        [UInt8]((IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data) ?? Data())
    }

    static func interfaceSummary(_ d: IOHIDDevice) -> HIDInterfaceSummary {
        let pairs = (IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]) ?? []
        var usages = pairs.map {
            HIDUsage(
                page: UInt16(truncatingIfNeeded: $0[kIOHIDDeviceUsagePageKey] as? Int ?? 0),
                usage: UInt16(truncatingIfNeeded: $0[kIOHIDDeviceUsageKey] as? Int ?? 0)
            )
        }
        if usages.isEmpty {
            usages = [HIDUsage(
                page: UInt16(truncatingIfNeeded: int(d, kIOHIDPrimaryUsagePageKey) ?? 0),
                usage: UInt16(truncatingIfNeeded: int(d, kIOHIDPrimaryUsageKey) ?? 0)
            )]
        }
        return HIDInterfaceSummary(
            id: registryID(d),
            usages: usages,
            maxInputReportSize: int(d, kIOHIDMaxInputReportSizeKey) ?? 0,
            maxOutputReportSize: int(d, kIOHIDMaxOutputReportSizeKey) ?? 0,
            maxFeatureReportSize: int(d, kIOHIDMaxFeatureReportSizeKey) ?? 0,
            collections: HIDReportLayout(descriptor: descriptor(d)).collections.map(\.summary)
        )
    }
}

func openFailure(_ rc: IOReturn) -> CherryError {
    rc == kIOReturnNotPermitted ? .accessDenied : .openFailed(rc)
}
