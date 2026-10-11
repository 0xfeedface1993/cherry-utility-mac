import Foundation

/// Byte-exact port of the Windows updater's report framing (`usb_Form.ota_write`, `user_sendDataToDevice`).
///
/// Every output report is `[reportID] + cmd[0 ..< reportLength-1]`, `cmd` pre-filled with 0xFF and starting
/// with `[type, len lo, len hi, payload…]`:
/// - version query: type 1, empty                       → reply `[rid, 1, 8, 0, version u32, crc u32]`
/// - start:         type 2, `01 FF` (0xFF01)
/// - data:          type 2, 1 or 3 × `[index u16][16 bytes][crc16]`
/// - end:           type 2, `02 FF` + last index u16 + (0x10000 − last index) u16
/// - result:        reply `[rid, 2, 3, 0, 06, FF, status]`, status 0 = success
public struct TelinkOTAProtocol: Sendable {
    public let reportID: UInt8
    /// Whole output report length including the report-ID byte (Windows `OutputReportByteLength`).
    public let reportLength: Int

    public static let packetSize = 20

    public var packetsPerReport: Int { reportID == 7 ? 1 : 3 }
    public var minimumReportLength: Int { 1 + 3 + packetsPerReport * Self.packetSize }

    public init(reportID: UInt8, reportLength: Int) throws {
        self.reportID = reportID
        self.reportLength = reportLength
        guard reportLength >= minimumReportLength else {
            throw CherryError.incompatibleFirmware("输出报告长度 \(reportLength) 小于所需 \(minimumReportLength)")
        }
    }

    private func frame(_ cmd: [UInt8]) -> [UInt8] { [reportID] + cmd.prefix(reportLength - 1) }

    private func blankCommand(type: UInt8) -> [UInt8] {
        var cmd = [UInt8](repeating: 0xFF, count: reportLength)
        cmd[0] = type
        cmd[1] = 0
        cmd[2] = 0
        return cmd
    }

    public func versionQueryReport() -> [UInt8] { frame(blankCommand(type: 1)) }

    public func startReport() -> [UInt8] {
        var cmd = blankCommand(type: 2)
        cmd[1] = 2
        cmd[3] = 0x01
        cmd[4] = 0xFF
        return frame(cmd)
    }

    /// Data reports followed by the end report, in send order, with the updater's progress value for each.
    public func transferReports(firmware: [UInt8]) -> (reports: [[UInt8]], progress: [Int]) {
        let size = firmware.count
        // The updater copies the image into a zeroed 2 MB buffer and pads 16 bytes of 0xFF after it.
        let source = firmware + [UInt8](repeating: 0xFF, count: 16) + [UInt8](repeating: 0, count: 32)
        var reports: [[UInt8]] = []
        var progress: [Int] = []
        var index = 0

        while true {
            var cmd = blankCommand(type: 2)
            var packets = [UInt8](repeating: 0, count: 60)
            for j in 0..<packetsPerReport {
                var pkt = [UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)]
                pkt += source[index * 16 ..< index * 16 + 16]
                let crc = Checksums.otaCRC16(pkt)
                pkt += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
                packets.replaceSubrange(20 * j ..< 20 * j + 20, with: pkt)
                index += 1
                if index * 16 >= size + 16 {
                    index -= 1
                    break
                }
                cmd[1] = UInt8(20 * j + 20)
            }
            for l in 0..<Int(cmd[1]) { cmd[3 + l] = packets[l] }

            if cmd[1] == 0 {
                let last = UInt16(truncatingIfNeeded: index - 1)
                let neg = UInt16(truncatingIfNeeded: 0x10000 - Int(last))
                cmd[1] = 6
                cmd[2] = 0
                cmd[3] = 0x02
                cmd[4] = 0xFF
                cmd[5] = UInt8(last & 0xFF)
                cmd[6] = UInt8(last >> 8)
                cmd[7] = UInt8(neg & 0xFF)
                cmd[8] = UInt8(neg >> 8)
                reports.append(frame(cmd))
                progress.append(100)
                return (reports, progress)
            }
            reports.append(frame(cmd))
            progress.append(min(100, index * 16 * 100 / size))
        }
    }

    public func parseVersion(_ r: [UInt8]) -> DeviceFirmwareStatus? {
        guard r.count >= 12, r[0] == reportID, r[1] == 1, r[2] == 8, r[3] == 0 else { return nil }
        return DeviceFirmwareStatus(version: le32(r, 4), crc: le32(r, 8))
    }

    /// OTA status byte if `r` is a result report (0 = success).
    public func parseResult(_ r: [UInt8]) -> UInt8? {
        guard r.count >= 7, r[0] == reportID, r[1] == 2, r[2] == 3, r[3] == 0, r[4] == 6, r[5] == 0xFF else { return nil }
        return r[6]
    }

    private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
