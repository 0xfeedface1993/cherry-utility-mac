import Foundation

/// Runs the Telink USB OTA exchange over a `HIDReportChannel`: one output report per input report,
/// exactly like the Windows updater (verified on a PIXIU 75: 3461 reports out, 3461 acks in).
public struct FirmwareFlasher: Sendable {
    public struct Timeouts: Sendable {
        public var reply: Duration
        public var start: Duration
        public var ack: Duration
        public var result: Duration

        public init(reply: Duration = .seconds(2), start: Duration = .seconds(15), ack: Duration = .seconds(5), result: Duration = .seconds(30)) {
            self.reply = reply
            self.start = start
            self.ack = ack
            self.result = result
        }
    }

    public let channel: any HIDReportChannel
    public let otaProtocol: TelinkOTAProtocol
    public let timeouts: Timeouts
    let diagnostics: Diagnostics

    public init(channel: any HIDReportChannel, reportID: UInt8, timeouts: Timeouts = Timeouts(), diagnostics: Diagnostics = .noop) throws {
        self.channel = channel
        self.otaProtocol = try TelinkOTAProtocol(reportID: reportID, reportLength: channel.outputReportLength)
        self.timeouts = timeouts
        self.diagnostics = diagnostics
    }

    public func readFirmwareStatus() async throws -> DeviceFirmwareStatus {
        try Task.checkCancellation()
        await channel.discardPending()
        try Task.checkCancellation()
        try await channel.send(otaProtocol.versionQueryReport())
        let deadline = ContinuousClock.now + timeouts.reply
        while true {
            try Task.checkCancellation()
            let remaining = deadline - .now
            guard remaining > .zero, let reply = try await channel.receive(timeout: remaining) else {
                throw CherryError.timeout("设备未响应固件版本查询")
            }
            if let status = otaProtocol.parseVersion(reply) { return status }
        }
    }

    /// Cancelling mid-transfer leaves the keyboard on its current firmware: the new image is only
    /// activated after the end command passes the device-side CRC check.
    private func flashImpl(
        _ image: UpdaterImage,
        progress: @Sendable (FlashProgress) async -> Void
    ) async throws -> FlashOutcome {
        try Task.checkCancellation()
        try image.validate()
        let (reports, percents) = diagnostics.measure(.otaReports, metrics: .init(bytes: UInt64(image.firmware.count))) { otaProtocol.transferReports(firmware: image.firmware) }
        let total = reports.count + 1
        await reportProgress(.started(totalReports: total), progress: progress)

        await channel.discardPending()
        try Task.checkCancellation()
        let startAck = try await diagnostics.measure(.otaStart) {
            try await channel.send(otaProtocol.startReport())
            guard let ack = try await nextAck(timeout: timeouts.start) else {
                throw CherryError.timeout("设备未响应 OTA 开始命令（仍运行原固件，可安全重试）")
            }
            return ack
        }
        if let status = otaProtocol.parseResult(startAck) { return try outcome(status) }

        var lastPercent = -1
        for (i, report) in reports.enumerated() {
            try Task.checkCancellation()
            try await channel.send(report)
            if i == reports.count - 1 { break } // end command: answered by the result report
            guard let ack = try await nextAck(timeout: timeouts.ack) else {
                throw CherryError.timeout("第 \(i + 2)/\(total) 个报文无应答")
            }
            if let status = otaProtocol.parseResult(ack) { return try outcome(status) }
            if percents[i] != lastPercent {
                lastPercent = percents[i]
                await reportProgress(.transferred(reports: i + 2, totalReports: total, percent: percents[i]), progress: progress)
            }
        }

        await reportProgress(.verifying, progress: progress)
        let resultSpan = diagnostics.begin(.otaResult)
        do {
            let result = try await readResult()
            resultSpan.finish(DiagnosticOutcome(result))
            return result
        } catch { resultSpan.finish(error: error); throw error }
    }

    private func readResult() async throws -> FlashOutcome {
        let deadline = ContinuousClock.now + timeouts.result
        while true {
            try Task.checkCancellation()
            let remaining = deadline - .now
            guard remaining > .zero else { return .unconfirmed }
            do {
                guard let reply = try await nextAck(timeout: remaining) else { return .unconfirmed }
                if let status = otaProtocol.parseResult(reply) { return try outcome(status) }
            } catch CherryError.disconnected {
                return .deviceRebooted
            }
        }
    }

    private func outcome(_ status: UInt8) throws -> FlashOutcome {
        guard status == 0 else { throw CherryError.otaFailed(status: status) }
        return .confirmed
    }

    public func flash(_ image: UpdaterImage, progress: @Sendable (FlashProgress) async -> Void) async throws -> FlashOutcome {
        let span = diagnostics.begin(.otaTransfer, metrics: .init(bytes: UInt64(image.firmware.count)))
        do {
            let result = try await TraceContext.$current.withValue(span.context) { try await flashImpl(image, progress: progress) }
            span.finish(DiagnosticOutcome(result))
            return result
        } catch { span.finish(error: error); throw error }
    }

    private func nextAck(timeout: Duration) async throws -> [UInt8]? {
        guard diagnostics.isEnabled() else { return try await nextAckImpl(timeout: timeout) }
        let span = diagnostics.begin(.otaACK)
        do {
            let result = try await nextAckImpl(timeout: timeout)
            span.finish(result == nil ? .timeout : .success)
            return result
        } catch { span.finish(error: error); throw error }
    }

    private func reportProgress(_ value: FlashProgress, progress: @Sendable (FlashProgress) async -> Void) async {
        await diagnostics.measure(.otaProgress) { await progress(value) }
    }

    private func nextAckImpl(timeout: Duration) async throws -> [UInt8]? {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            let remaining = deadline - .now
            guard remaining > .zero, let report = try await channel.receive(timeout: remaining) else { return nil }
            if let id = report.first, channel.inputReportIDs.contains(id) { return report }
        }
    }
}
