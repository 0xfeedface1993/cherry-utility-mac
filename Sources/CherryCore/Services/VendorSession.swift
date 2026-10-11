import Foundation

/// Client of the private configuration channel, over any `HIDReportChannel`.
public struct VendorSession: Sendable {
    public let channel: any HIDReportChannel
    public let reportID: UInt8
    public let replyTimeout: Duration
    let diagnostics: Diagnostics

    public init(channel: any HIDReportChannel, reportID: UInt8, replyTimeout: Duration = .seconds(2), diagnostics: Diagnostics = .noop) {
        self.channel = channel
        self.reportID = reportID
        self.replyTimeout = replyTimeout
        self.diagnostics = diagnostics
    }

    // MARK: Reads

    /// Reads `length` bytes at `offset`, split into 56-byte chunks like CHERRY Utility does.
    public func read(_ command: VendorCommand, length: Int, offset: Int = 0) async throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var position = 0
        while position < length {
            try Task.checkCancellation()
            let chunk = min(VendorPacket.maxChunk, length - position)
            let request = VendorPacket.request(command, length: chunk, offset: offset + position, reportID: reportID)
            let reply = try await exchange(request)
            out += try VendorPacket.payload(of: reply, for: request)
            position += chunk
        }
        return out
    }

    public func battery() async throws -> BatteryStatus {
        try BatteryStatus(raw: try await read(.readBattery, length: 6))
    }

    public func deviceStatus() async throws -> DeviceStatusBlock {
        try DeviceStatusBlock(raw: try await read(.readDeviceStatus, length: 56))
    }

    public func activeProfileNumber() async throws -> Int {
        Int(try await read(.readConfig, length: 1)[0])
    }

    public func profile(_ n: Int) async throws -> ProfileConfig {
        try ProfileConfig(profile: n, raw: try await read(.readConfig, length: ProfileConfig.blockSize, offset: n * ProfileConfig.blockSize))
    }

    /// The active-profile selector plus every onboard profile block (and the active block, should the selector
    /// point outside the model's range).
    public func configuration(profileCount: Int) async throws -> KeyboardConfiguration {
        let active = try await activeProfileNumber()
        var numbers = Array(0..<profileCount)
        if !numbers.contains(active) { numbers.append(active) }
        var profiles: [ProfileConfig] = []
        for n in numbers {
            try Task.checkCancellation()
            profiles.append(try await profile(n))
        }
        return try KeyboardConfiguration(activeProfile: active, profiles: profiles)
    }

    public func activeProfile() async throws -> ProfileConfig {
        try await profile(try await activeProfileNumber())
    }

    /// Battery, status and the active profile only.
    public func snapshot() async throws -> VendorSnapshot {
        VendorSnapshot(battery: try await battery(), status: try await deviceStatus(), profile: try await activeProfile())
    }

    /// Battery, status and every onboard profile.
    public func snapshot(profileCount: Int) async throws -> VendorSnapshot {
        VendorSnapshot(
            battery: try await battery(),
            status: try await deviceStatus(),
            configuration: try await configuration(profileCount: profileCount)
        )
    }

    // MARK: Writes

    /// Runs `body` between `beginConfig` and `endConfig`, like every write path of CHERRY Utility.
    /// `endConfig` is attempted even when `body` fails or the task was cancelled, so the keyboard is never
    /// left inside an open configuration transaction.
    public func transaction<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await control(.beginConfig)
        let value: T
        do {
            value = try await body()
        } catch {
            try? await control(.endConfig, honoringCancellation: false)
            throw error
        }
        try await control(.endConfig, honoringCancellation: false)
        return value
    }

    /// Writes `bytes` at `offset` of the configuration space (call inside `transaction`).
    public func write(_ bytes: [UInt8], at offset: Int) async throws {
        var position = 0
        while position < bytes.count {
            try Task.checkCancellation()
            let chunk = Array(bytes[position..<min(position + VendorPacket.maxChunk, bytes.count)])
            let request = VendorPacket.write(payload: chunk, offset: offset + position, reportID: reportID)
            let reply = try await exchange(request)
            try VendorPacket.checkStatus(of: reply, for: request)
            position += chunk.count
        }
    }

    /// Makes profile `n` the active one.
    public func activateProfile(_ n: Int) async throws {
        try await transaction { try await write([UInt8(n)], at: 0) }
    }

    /// Read-modify-write of profile `n`: only the bytes of the patched fields are sent, then the block is read back.
    public func update(profile n: Int, with patch: ProfilePatch) async throws -> ProfileConfig {
        let current = try await profile(n)
        let target = current.applying(patch)
        guard let range = current.changedRange(to: target) else {
            diagnostics.emit(.configurationWrite, outcome: .noChange)
            return current
        }
        try await transaction {
            try await write(Array(target[range]), at: n * ProfileConfig.blockSize + range.lowerBound)
        }
        return try await diagnostics.measure(.configurationReadBack) { try await profile(n) }
    }

    // MARK: Exchange

    private func control(_ command: VendorCommand, honoringCancellation: Bool = true) async throws {
        let request = VendorPacket.control(command, reportID: reportID)
        try await diagnostics.measure(command == .beginConfig ? .configurationBegin : .configurationEnd) {
            let reply = try await exchange(request, honoringCancellation: honoringCancellation)
            try VendorPacket.checkStatus(of: reply, for: request)
        }
    }

    private func exchange(_ request: [UInt8], honoringCancellation: Bool = true) async throws -> [UInt8] {
        try await diagnostics.measure(.vendorExchange, metrics: .init(command: request.count > 3 ? request[3] : nil)) {
            try await exchangeImpl(request, honoringCancellation: honoringCancellation)
        }
    }

    private func exchangeImpl(_ request: [UInt8], honoringCancellation: Bool = true) async throws -> [UInt8] {
        await channel.discardPending()
        try await channel.send(request)
        let deadline = ContinuousClock.now + replyTimeout
        while true {
            if honoringCancellation { try Task.checkCancellation() }
            let remaining = deadline - .now
            guard remaining > .zero, let reply = try await channel.receive(timeout: remaining) else {
                throw CherryError.timeout(String(format: "命令 0x%02X 无回复", request[3]))
            }
            // Other reports on the same interface (e.g. key reports) are skipped.
            if VendorPacket.matches(reply, request: request) { return reply }
        }
    }
}
