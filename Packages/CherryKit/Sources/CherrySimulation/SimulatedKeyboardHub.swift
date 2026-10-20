import CherryAdapters
import CherryCore
import Foundation
import Synchronization

/// An in-memory stand-in for the HID adapter, used by UI tests and the demo mode.
///
/// It speaks the same wire protocols as a PIXIU 75 (vendor channel 0xFF1C #4 and Telink OTA 0xFFEF #5) on top
/// of a byte-level configuration space seeded with blocks captured from a real keyboard, so the whole core stack
/// – services, gate, codecs – runs unchanged. It also supports hot-plug, a firmware update that reboots into the
/// flashed version, and injected key events.
public final class SimulatedKeyboardHub: KeyboardDiscoveryPort, ReportChannelProvider, KeyEventSource, InputMonitoringPort, Sendable {
    public struct Scenario: Sendable, Equatable {
        public enum Device: String, Sendable { case pixiu75, unsupported, none }

        public var device: Device = .pixiu75
        /// Which CHERRY product the `.pixiu75` device presents itself as (product ID, OTA interface, battery support).
        public var model: KeyboardModel = .pixiu75
        public var accessDenied = false
        public var additionalDevice = false
        public var batteryPercent = 95
        public var charging = true
        public var wireless = false
        public var firmwareVersion: UInt16 = 0x0117
        /// Image CRC the OTA channel reports before any flash.
        public var firmwareCRC: UInt32 = SimulatedKeyboardHub.initialCRC
        /// How long the keyboard stays off the bus after a successful OTA.
        public var rebootDelay: Duration = .milliseconds(1200)
        /// Delay before each reply, so progress is observable in the UI.
        public var replyDelay: Duration = .zero
        /// Extra delay before each OTA reply (0xFFEF), so a flash lasts long enough to act on it while it runs.
        public var otaReplyDelay: Duration = .zero
        /// File holding the configuration space, shared by every process that simulates the same keyboard (the app and
        /// `cherry` connected directly, set with `CHERRY_SIMULATION_STATE`), so they see each other's writes.
        public var sharedState: URL?

        public init() {}

        /// `pixiu75` (default), `dual`, `slow`, `slowflash` (OTA replies take 40 ms: a flash takes about 5 s), `empty`,
        /// `unsupported`, `denied`, `wireless`, `customfw` (runs the synthetic stock image that `SimulatedCustomFirmware`
        /// has a definition for), and other models: `mx30s` (wired RGB board,
        /// no battery / OTA), `nbl` (wired, no backlight), `pixiu98` (type-B effect table, no OTA), `receiver` (PIXIU 75
        /// 2.4 GHz receiver).
        public static func named(_ name: String) -> Scenario {
            var s = Scenario()
            switch name {
            case "dual": s.additionalDevice = true
            case "slow": s.replyDelay = .milliseconds(180)
            case "slowflash": s.otaReplyDelay = .milliseconds(40)
            case "empty": s.device = .none
            case "unsupported": s.device = .unsupported
            case "denied": s.accessDenied = true
            case "wireless":
                s.wireless = true
                s.charging = false
                s.batteryPercent = 15
            case "customfw":
                s.firmwareCRC = SimulatedCustomFirmware.stockCRC
            case "mx30s": s.model = Self.model(0x0079); s.firmwareVersion = 0x0136
            case "nbl": s.model = Self.model(0x0077); s.firmwareVersion = 0x0120
            case "pixiu98": s.model = .pixiu98; s.firmwareVersion = 0x0113
            case "receiver": s.model = Self.model(0x01E4); s.charging = false; s.batteryPercent = 64
            default: break
            }
            return s
        }

        static func model(_ productID: UInt16) -> KeyboardModel {
            guard let model = KeyboardModel.matching(vendorID: KeyboardModel.cherryVendorID, productID: productID) else {
                preconditionFailure(String(format: "no catalog model for PID 0x%04X", productID))
            }
            return model
        }

        /// 2.4 GHz receivers report the wireless mode while plugged in over USB.
        var reportsWireless: Bool { wireless || model.kind == .receiver }
    }

    public static let keyboardID = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0310_0000)
    public static let secondKeyboardID = KeyboardID(vendorID: 0x046A, productID: 0x01E2, locationID: 0x0320_0000)
    public static let unsupportedID = KeyboardID(vendorID: 0x046A, productID: 0x0999, locationID: 0x0320_0000)
    public static let initialCRC: UInt32 = 0xCFE1_A03E

    struct Device {
        var attached: Bool
        var releaseNumber: UInt16
        var crc: UInt32
        var config: [UInt8]
        var battery: Int
        var charging: Bool
        var ota = OTAState()
    }

    /// 与 IOKit 适配器相同：每个订阅一个采集会话。
    struct KeySubscriber {
        let continuation: AsyncThrowingStream<Traced<KeyEvent>, any Error>.Continuation
        let observation: KeyCaptureDiagnostics
    }

    struct OTAState {
        var started = false
        var image: [UInt8] = []
        var highestIndex = -1
        var packetErrors = 0
    }

    private struct State {
        var device: Device
        var listSubscribers: [UUID: AsyncStream<[KeyboardSummary]>.Continuation] = [:]
        var keySubscribers: [UUID: KeySubscriber] = [:]
        var channels: [UUID: SimulatedReportChannel] = [:]
        /// Supervised reboot after an OTA; replaced or cancelled, never orphaned.
        var reboot: Task<Void, Never>?
        var writes = 0
    }

    public let scenario: Scenario
    private let diagnostics: Diagnostics
    private let state: Mutex<State>
    private let deviceID: KeyboardID
    private let secondary: SimulatedKeyboardHub?

    public init(scenario: Scenario = Scenario(), diagnostics: Diagnostics = .noop, keyboardID: KeyboardID? = nil) {
        deviceID = keyboardID ?? KeyboardID(vendorID: Self.keyboardID.vendorID, productID: scenario.model.productID, locationID: Self.keyboardID.locationID)
        if scenario.additionalDevice {
            var secondScenario = scenario
            secondScenario.additionalDevice = false
            secondScenario.batteryPercent = 53
            secondScenario.charging = false
            let secondID = KeyboardID(vendorID: Self.secondKeyboardID.vendorID, productID: scenario.model.productID, locationID: Self.secondKeyboardID.locationID)
            secondary = SimulatedKeyboardHub(scenario: secondScenario, diagnostics: diagnostics, keyboardID: secondID)
        } else { secondary = nil }
        self.scenario = scenario
        self.diagnostics = diagnostics
        var config = Self.capturedConfigurationSpace(for: scenario.model)
        if let shared = scenario.sharedState {
            SharedConfiguration.withLock(shared) {
                if let stored = SharedConfiguration.load(shared), stored.count == config.count { config = stored }
                else { SharedConfiguration.store(config, shared) }
            }
        }
        state = Mutex(State(device: Device(
            attached: scenario.device != .none,
            releaseNumber: scenario.firmwareVersion,
            crc: scenario.firmwareCRC,
            config: config,
            battery: scenario.batteryPercent,
            charging: scenario.charging
        )))
    }

    deinit {
        state.withLock { $0.reboot?.cancel() }
    }

    /// The captured space with every block's effect moved into `model`'s table (e.g. type-B numbering).
    static func capturedConfigurationSpace(for model: KeyboardModel) -> [UInt8] {
        var space = capturedConfigurationSpace()
        guard let fallback = model.lightingEffects.first?.rawValue else { return space }
        for n in 0..<model.profileCount where model.effect(space[n * 64 + 1] & ProfileConfig.effectMask) == nil {
            space[n * 64 + 1] = fallback
        }
        return space
    }

    /// Configuration space read from a real PIXIU 75 on 2026-10-11 (active profile 1, three blocks).
    static func capturedConfigurationSpace() -> [UInt8] {
        var space = [UInt8](repeating: 0x00, count: 0x200)
        space.replaceSubrange(0xC0..<0x140, with: [UInt8](repeating: 0xFF, count: 0x80))
        let heads: [[UInt8]] = [
            [0x01, 0x12, 0x04, 0x02, 0x00, 0x00, 0x33, 0xFF, 0x33],
            [0x01, 0x00, 0x04, 0x03, 0x00, 0xFF, 0xFF, 0xFF, 0xFF],
            [0x00, 0x03, 0x04, 0x02, 0x00, 0xFF, 0x00, 0x00, 0xFF],
        ]
        for (n, head) in heads.enumerated() {
            let base = n * 64
            space.replaceSubrange(base..<base + head.count, with: head)
            space[base + 0x19] = 0xFF
            space.replaceSubrange(base + 0x22..<base + 0x26, with: [0x2C, 0x01, 0x1E, 0x00])
        }
        space[0x14] = 0x01
        return space
    }

    // MARK: Test controls

    public func unplug() {
        let (lists, keys, channels) = state.withLock { s -> ([AsyncStream<[KeyboardSummary]>.Continuation], [KeySubscriber], [SimulatedReportChannel]) in
            s.device.attached = false
            s.device.ota = OTAState()
            let keys = Array(s.keySubscribers.values)
            s.keySubscribers.removeAll()
            let channels = Array(s.channels.values)
            s.channels.removeAll()
            return (Array(s.listSubscribers.values), keys, channels)
        }
        for channel in channels { channel.deviceRemoved() }
        for key in keys {
            key.observation.finish(.disconnected)
            key.continuation.finish(throwing: CherryError.disconnected)
        }
        let remaining = secondary.map { hub in hub.state.withLock { hub.summaries($0.device) } } ?? []
        for list in lists { list.yield(remaining) }
    }

    public func plug() {
        guard scenario.device != .none else { return }
        let (lists, summaries) = state.withLock { s -> ([AsyncStream<[KeyboardSummary]>.Continuation], [KeyboardSummary]) in
            s.device.attached = true
            return (Array(s.listSubscribers.values), summaries(s.device))
        }
        for list in lists { list.yield(summaries) }
    }

    /// Delivers a key press/release as if the keyboard had sent it.
    public func inject(_ usage: HIDUsage, isDown: Bool, timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let keys = state.withLock { Array($0.keySubscribers.values) }
        let event = KeyEvent(usage: usage, isDown: isDown, timestamp: timestamp)
        for key in keys {
            key.observation.yielded(key.continuation.yield(Traced(event, stamp: key.observation.stamp())))
        }
    }

    /// Number of accepted `writeConfig` packets (for tests).
    public var writeCount: Int { state.withLock { $0.writes } }

    public func configurationSpace() -> [UInt8] { state.withLock { $0.device.config } }

    // MARK: InputMonitoringPort

    public func status() -> InputMonitoringStatus { scenario.accessDenied ? .denied : .granted }
    public func request() async -> Bool { !scenario.accessDenied }

    // MARK: KeyboardDiscoveryPort

    public func keyboards() async -> [KeyboardSummary] {
        state.withLock { summaries($0.device) }
    }

    public func keyboardUpdates() -> AsyncStream<[KeyboardSummary]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [KeyboardSummary].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { s -> [KeyboardSummary] in
            s.listSubscribers[id] = continuation
            return summaries(s.device)
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.listSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func summaries(_ device: Device) -> [KeyboardSummary] {
        let additional = secondary.map { hub in hub.state.withLock { hub.summaries($0.device) } } ?? []
        guard device.attached else { return additional }
        switch scenario.device {
        case .none:
            return []
        case .unsupported:
            return [KeyboardSummary(
                id: Self.unsupportedID, product: "KC 200 MX", manufacturer: "CHERRY", serialNumber: nil, transport: "USB",
                releaseNumber: 0x0102,
                interfaces: [HIDInterfaceSummary(id: 11, usages: [HIDUsage(page: 0x01, usage: 0x06)], maxInputReportSize: 8, maxOutputReportSize: 1, maxFeatureReportSize: 0, collections: [])]
            )]
        case .pixiu75:
            var interfaces = [
                HIDInterfaceSummary(id: 1, usages: [HIDUsage(page: 0x01, usage: 0x06)], maxInputReportSize: 8, maxOutputReportSize: 1, maxFeatureReportSize: 64, collections: []),
                HIDInterfaceSummary(
                    id: 2, usages: [HIDUsage(page: 0x01, usage: 0x06), HIDUsage(page: 0x0C, usage: 0x01), HIDUsage(page: 0xFF1C, usage: 0x92)],
                    maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0,
                    collections: [HIDCollectionSummary(usage: HIDUsage(page: 0xFF1C, usage: 0x92), inputReports: [4: 64], outputReports: [4: 64], featureReports: [:])]
                ),
            ]
            if !scenario.wireless, scenario.model.ota != nil {
                interfaces.append(HIDInterfaceSummary(
                    id: 3, usages: [HIDUsage(page: 0xFFEF, usage: 0x00)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 64,
                    collections: [HIDCollectionSummary(usage: HIDUsage(page: 0xFFEF, usage: 0x00), inputReports: [5: 64], outputReports: [5: 64], featureReports: [5: 64])]
                ))
            }
            let product = scenario.model == .pixiu75 ? "PIXIU 75" : scenario.model.name
            return [KeyboardSummary(
                id: deviceID, product: product, manufacturer: "CHERRY", serialNumber: nil,
                transport: scenario.wireless ? "Bluetooth Low Energy" : "USB", releaseNumber: device.releaseNumber, interfaces: interfaces
            )] + additional
        }
    }

    // MARK: ReportChannelProvider

    public func openChannel(keyboard: KeyboardID, usagePage: UInt16, reportID: UInt8) async throws -> any HIDReportChannel {
        if let secondary, keyboard == secondary.deviceID {
            return try await secondary.openChannel(keyboard: keyboard, usagePage: usagePage, reportID: reportID)
        }
        let delay = usagePage == 0xFFEF ? scenario.replyDelay + scenario.otaReplyDelay : scenario.replyDelay
        let channel = SimulatedReportChannel(reportID: reportID, replyDelay: delay) { [weak self] report in
            self?.handle(report, usagePage: usagePage) ?? []
        }
        try state.withLock { s in
            guard s.device.attached, keyboard == deviceID || keyboard == Self.unsupportedID else { throw CherryError.deviceNotFound(keyboard) }
            guard summaries(s.device).first?.hasInterface(usagePage: usagePage) == true else { throw CherryError.interfaceNotFound(usagePage: usagePage) }
            if scenario.accessDenied, usagePage == 0xFF1C { throw CherryError.accessDenied }
            s.channels[channel.id] = channel
        }
        channel.onClose = { [weak self] id in self?.state.withLock { _ = $0.channels.removeValue(forKey: id) } }
        return channel
    }

    // MARK: KeyEventSource

    public func keyEvents(keyboard: KeyboardID) -> AsyncThrowingStream<Traced<KeyEvent>, any Error> {
        if let secondary, keyboard == secondary.deviceID { return secondary.keyEvents(keyboard: keyboard) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Traced<KeyEvent>.self, bufferingPolicy: .bufferingNewest(512))
        let id = UUID()
        let observation = KeyCaptureDiagnostics(diagnostics)
        let attached = state.withLock { s -> Bool in
            guard s.device.attached else { return false }
            s.keySubscribers[id] = KeySubscriber(continuation: continuation, observation: observation)
            return true
        }
        if !attached {
            let error = CherryError.deviceNotFound(keyboard)
            observation.finish(error: error)
            continuation.finish(throwing: error)
        }
        continuation.onTermination = { [weak self] _ in
            // 已因拔出结束的会话不会重复记录：span 只结束一次。
            observation.finish(.stopped)
            self?.state.withLock { _ = $0.keySubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Device side

    /// Replies to one output report (runs on the caller's task; never blocks).
    private func handle(_ r: [UInt8], usagePage: UInt16) -> [[UInt8]] {
        switch usagePage {
        case 0xFF1C: [vendorReply(r)]
        case 0xFFEF: otaReplies(r)
        default: []
        }
    }

    private func vendorReply(_ r: [UInt8]) -> [UInt8] {
        let command = r[3]
        var reply = Array(r.prefix(8)) + [UInt8](repeating: 0, count: 56)
        guard Checksums.vendorSum(r[3...]) == UInt16(r[1]) | UInt16(r[2]) << 8 else {
            reply[7] = 0xFE
            return reply
        }
        let accessesConfig = command == VendorCommand.readConfig.rawValue || command == VendorCommand.writeConfig.rawValue
        guard accessesConfig, let shared = scenario.sharedState else { return vendorReply(r, into: reply) }
        // Read-modify-write against the shared file, atomic with respect to the other process.
        return SharedConfiguration.withLock(shared) {
            if let stored = SharedConfiguration.load(shared) {
                state.withLock { if stored.count == $0.device.config.count { $0.device.config = stored } }
            }
            let answer = vendorReply(r, into: reply)
            if command == VendorCommand.writeConfig.rawValue {
                SharedConfiguration.store(state.withLock { $0.device.config }, shared)
            }
            return answer
        }
    }

    private func vendorReply(_ r: [UInt8], into reply: [UInt8]) -> [UInt8] {
        let command = r[3], length = Int(r[4]), offset = Int(r[5]) | Int(r[6]) << 8
        var reply = reply
        state.withLock { s in
            switch command {
            case VendorCommand.beginConfig.rawValue, VendorCommand.endConfig.rawValue:
                reply[7] = 0
            case VendorCommand.readConfig.rawValue where offset + length <= s.device.config.count:
                reply[7] = 0
                reply.replaceSubrange(8..<8 + length, with: s.device.config[offset..<offset + length])
            case VendorCommand.writeConfig.rawValue where r[7] == VendorPacket.writeMarker && offset + length <= s.device.config.count:
                s.device.config.replaceSubrange(offset..<offset + length, with: r[8..<8 + length])
                s.writes += 1
            // Wired-only boards do not implement battery / status: they reject the command like an unknown one.
            case VendorCommand.readBattery.rawValue where scenario.model.hasBattery:
                reply[7] = 0
                reply.replaceSubrange(8..<14, with: [UInt8(s.device.battery), s.device.charging ? 1 : 0, 0, 0, 0, 0])
            case VendorCommand.readDeviceStatus.rawValue where scenario.model.hasBattery:
                reply[7] = 0
                let mode: UInt8 = scenario.reportsWireless ? 2 : 1
                let pid = scenario.model.productID
                let block: [UInt8] = [0xAA, 0x55, 0, 0, 0x6A, 0x04, UInt8(pid & 0xFF), UInt8(pid >> 8), 1, 0, mode, 0, 1, 0]
                reply.replaceSubrange(8..<8 + block.count, with: block)
            default:
                reply[7] = 0xFF
            }
        }
        return reply
    }

    private func otaReplies(_ r: [UInt8]) -> [[UInt8]] {
        let rid = r[0]
        switch (r[1], r[4]) {
        case (1, _): // version query
            let (version, crc) = state.withLock { (UInt32($0.device.releaseNumber), $0.device.crc) }
            var reply = [UInt8](repeating: 0xFF, count: 64)
            reply.replaceSubrange(0..<4, with: [rid, 1, 8, 0])
            reply.replaceSubrange(4..<8, with: withUnsafeBytes(of: version.littleEndian, Array.init))
            reply.replaceSubrange(8..<12, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
            return [reply]
        case (2, 0x01) where r[2] == 2 && r[5] == 0xFF: // start
            state.withLock { $0.device.ota = OTAState(started: true) }
            return [r]
        case (2, 0x02) where r[2] == 6 && r[5] == 0xFF: // end
            let last = Int(r[6]) | Int(r[7]) << 8
            let flashed = state.withLock { s -> (version: UInt16, crc: UInt32)? in
                let ota = s.device.ota
                s.device.ota = OTAState()
                guard ota.started, ota.packetErrors == 0, ota.highestIndex == last, ota.image.count > 0x30 else { return nil }
                let size = Int(ota.image[0x18]) | Int(ota.image[0x19]) << 8 | Int(ota.image[0x1A]) << 16 | Int(ota.image[0x1B]) << 24
                guard size > 0x30, size <= ota.image.count else { return nil }
                let image = Array(ota.image[0..<size])
                let trailer = UInt32(image[size - 4]) | UInt32(image[size - 3]) << 8 | UInt32(image[size - 2]) << 16 | UInt32(image[size - 1]) << 24
                guard Checksums.telinkCRC32(image.dropLast(4)) == trailer else { return nil }
                let v = UInt16(image[SyntheticUpdater.versionOffset]) | UInt16(image[SyntheticUpdater.versionOffset + 1]) << 8
                return (v == 0 || v == 0xFFFF ? s.device.releaseNumber : v, trailer)
            }
            if let flashed { scheduleReboot(into: flashed) }
            return [[rid, 2, 3, 0, 6, 0xFF, flashed == nil ? 1 : 0] + [UInt8](repeating: 0xFF, count: 57)]
        default: // data
            let length = Int(r[2])
            state.withLock { s in
                guard s.device.ota.started else { return }
                for p in stride(from: 0, to: length, by: 20) where 4 + p + 20 <= r.count {
                    let packet = Array(r[4 + p..<4 + p + 20])
                    let crc = Checksums.otaCRC16(packet[0..<18])
                    guard packet[18] == UInt8(crc & 0xFF), packet[19] == UInt8(crc >> 8) else {
                        s.device.ota.packetErrors += 1
                        continue
                    }
                    let index = Int(packet[0]) | Int(packet[1]) << 8
                    let end = index * 16 + 16
                    if s.device.ota.image.count < end { s.device.ota.image += [UInt8](repeating: 0xFF, count: end - s.device.ota.image.count) }
                    s.device.ota.image.replaceSubrange(index * 16..<end, with: packet[2..<18])
                    s.device.ota.highestIndex = max(s.device.ota.highestIndex, index)
                }
            }
            return [r]
        }
    }

    /// The keyboard drops off the bus after the result report and comes back running the new image.
    ///
    /// Design decision (concurrency preflight "orphan-task"): the reboot needs its own timeline independent of
    /// any caller, so it is an unstructured task – but a supervised one: its handle lives in `state.reboot`,
    /// a newer reboot cancels the previous one, and `deinit` cancels whatever is still pending.
    private func scheduleReboot(into flashed: (version: UInt16, crc: UInt32)) {
        let delay = scenario.rebootDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20)) // let the result report reach the host first
            guard !Task.isCancelled, let self else { return }
            self.unplug()
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.state.withLock {
                $0.device.releaseNumber = flashed.version
                $0.device.crc = flashed.crc
            }
            self.plug()
        }
        let previous = state.withLock { s -> Task<Void, Never>? in
            defer { s.reboot = task }
            return s.reboot
        }
        previous?.cancel()
    }
}

/// Report channel of the simulated keyboard: replies are produced synchronously and handed over through the
/// same mailbox the IOKit channel uses.
final class SimulatedReportChannel: HIDReportChannel, Sendable {
    let id = UUID()
    let outputReportLength = 64
    let inputReportIDs: Set<UInt8>
    private let replyDelay: Duration
    private let respond: @Sendable ([UInt8]) -> [[UInt8]]
    private let mailbox = ReportMailbox()
    private let closeHandler = Mutex<(@Sendable (UUID) -> Void)?>(nil)

    init(reportID: UInt8, replyDelay: Duration, respond: @escaping @Sendable ([UInt8]) -> [[UInt8]]) {
        inputReportIDs = [reportID]
        self.replyDelay = replyDelay
        self.respond = respond
    }

    var onClose: (@Sendable (UUID) -> Void)? {
        get { closeHandler.withLock { $0 } }
        set { closeHandler.withLock { $0 = newValue } }
    }

    func send(_ report: [UInt8]) async throws {
        guard !mailbox.isClosed else { throw CherryError.disconnected }
        if replyDelay > .zero { try await Task.sleep(for: replyDelay) }
        try Task.checkCancellation()
        respond(report).forEach(mailbox.push) // synchronous hand-off, nothing awaited
    }

    func receive(timeout: Duration) async throws -> [UInt8]? {
        try await mailbox.next(timeout: timeout)
    }

    func discardPending() async {
        mailbox.drain()
    }

    func close() async {
        mailbox.close()
        let handler = closeHandler.withLock { h -> (@Sendable (UUID) -> Void)? in
            defer { h = nil }
            return h
        }
        handler?(id)
    }

    /// The device went away: pending and future reads fail with `disconnected`.
    func deviceRemoved() {
        mailbox.close()
    }
}

/// Firmware catalog with one release of the simulated model, served from memory.
public struct SimulatedFirmwareCatalog: FirmwareCatalogPort, FirmwareDownloadPort {
    public let latestVersion: UInt16
    private let catalogName: String
    private let updater: Data

    public init(model: KeyboardModel = .pixiu75, latestVersion: UInt16 = 0x0118) {
        self.latestVersion = latestVersion
        catalogName = model.catalogName ?? "SIMULATED_\(String(format: "%04X", model.productID))"
        updater = SyntheticUpdater.updaterExe(for: model, version: latestVersion)
    }

    public func releases() async throws -> [FirmwareRelease] {
        let code = String(format: "%04X", latestVersion)
        let name = catalogName + "_" + code
        return [
            FirmwareRelease(
                name: name, deviceIndex: 0x33, versionCode: code,
                versionName: code.map(String.init).joined(separator: "."),
                downloadURL: URL(string: "https://simulated.invalid/\(name).exe")!,
                md5: SyntheticUpdater.md5(updater), isForced: false
            ),
            FirmwareRelease(
                name: catalogName + "_DONGLE_" + code, deviceIndex: 0x34, versionCode: code,
                versionName: "dongle", downloadURL: URL(string: "https://simulated.invalid/dongle.exe")!, md5: "00", isForced: false
            ),
        ]
    }

    public func download(_ release: FirmwareRelease) async throws -> Data {
        try await Task.sleep(for: .milliseconds(200))
        return updater
    }
}
