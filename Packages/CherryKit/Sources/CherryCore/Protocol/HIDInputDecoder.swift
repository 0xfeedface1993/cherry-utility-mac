import Foundation

/// Decodes raw HID input reports into the set of pressed keyboard (0x07) / consumer (0x0C) usages, using the
/// interface's report descriptor. Needed because IOKit's per-value callbacks do not fire for keyboard
/// interfaces opened by an app (verified on macOS 27), while raw input reports do.
public struct HIDInputDecoder: Sendable {
    public struct Field: Equatable, Sendable {
        public let reportID: UInt8
        /// Bit offset of the field within the report payload (after the report-ID byte, if any).
        public let bitOffset: Int
        public let size: Int
        public let count: Int
        public let isArray: Bool
        public let usagePage: UInt16
        public let usages: [UInt32]
        public let usageMin: UInt32
        public let usageMax: UInt32
        public let logicalMin: Int64
        public let logicalMax: Int64
    }

    public let fields: [Field]
    public let usesReportIDs: Bool

    public static let pages: Set<UInt16> = [0x07, 0x0C]

    public init(descriptor d: [UInt8]) {
        var fields: [Field] = []
        var usesReportIDs = false
        // Globals
        var usagePage: UInt32 = 0, logicalMin: Int64 = 0, logicalMax: Int64 = 0
        var reportSize = 0, reportCount = 0, reportID: UInt8 = 0
        var stack: [(UInt32, Int64, Int64, Int, Int, UInt8)] = []
        // Locals
        var usages: [UInt32] = [], usageMin: UInt32?, usageMax: UInt32?
        var offsets: [UInt8: Int] = [:]

        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE {
                guard i + 1 < d.count else { break }
                i += 3 + Int(d[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard i + size < d.count else { break }
            var raw: UInt32 = 0
            for k in 0..<size { raw |= UInt32(d[i + 1 + k]) << (8 * k) }
            let signed: Int64 = switch size {
            case 1: Int64(Int8(truncatingIfNeeded: raw))
            case 2: Int64(Int16(truncatingIfNeeded: raw))
            case 4: Int64(Int32(truncatingIfNeeded: raw))
            default: 0
            }
            let type = (prefix >> 2) & 3, tag = prefix >> 4
            i += 1 + size

            func fullUsage(_ v: UInt32) -> UInt32 { size == 4 ? v : (usagePage << 16) | v }

            switch (type, tag) {
            case (1, 0x0): usagePage = raw
            case (1, 0x1): logicalMin = signed
            case (1, 0x2): logicalMax = (logicalMin >= 0 && signed < 0) ? Int64(raw) : signed
            case (1, 0x7): reportSize = Int(raw)
            case (1, 0x8): reportID = UInt8(truncatingIfNeeded: raw); usesReportIDs = true
            case (1, 0x9): reportCount = Int(raw)
            case (1, 0xA): stack.append((usagePage, logicalMin, logicalMax, reportSize, reportCount, reportID))
            case (1, 0xB): if let s = stack.popLast() { (usagePage, logicalMin, logicalMax, reportSize, reportCount, reportID) = s }
            case (2, 0x0): usages.append(fullUsage(raw))
            case (2, 0x1): usageMin = fullUsage(raw)
            case (2, 0x2): usageMax = fullUsage(raw)
            case (0, 0x8): // Input
                let offset = offsets[reportID, default: 0]
                // Skip constants (padding) and relative fields (e.g. the mouse collection's consumer AC Pan).
                let isConstant = raw & 1 != 0, isRelative = raw & 4 != 0
                if !isConstant && !isRelative {
                    let page = UInt16(truncatingIfNeeded: (usages.first ?? usageMin ?? (usagePage << 16)) >> 16)
                    fields.append(Field(
                        reportID: reportID, bitOffset: offset, size: reportSize, count: reportCount,
                        isArray: raw & 2 == 0, usagePage: page, usages: usages,
                        usageMin: usageMin ?? 0, usageMax: usageMax ?? 0,
                        logicalMin: logicalMin, logicalMax: logicalMax
                    ))
                }
                offsets[reportID] = offset + reportSize * reportCount
                usages.removeAll(); usageMin = nil; usageMax = nil
            case (0, _): // Output / Feature / Collection / End Collection
                usages.removeAll(); usageMin = nil; usageMax = nil
            default: break
            }
        }
        self.fields = fields.filter { Self.pages.contains($0.usagePage) && $0.size > 0 && $0.size <= 32 }
        self.usesReportIDs = usesReportIDs
    }

    public var keyReportIDs: Set<UInt8> { Set(fields.map(\.reportID)) }

    /// Pressed usages carried by `report`, or nil if the report holds no key fields.
    public func pressedUsages(in report: [UInt8]) -> (reportID: UInt8, usages: Set<HIDUsage>)? {
        let reportID: UInt8 = usesReportIDs ? (report.first ?? 0) : 0
        let payload = usesReportIDs ? Array(report.dropFirst()) : report
        let relevant = fields.filter { $0.reportID == reportID }
        guard !relevant.isEmpty else { return nil }
        // 截断快照不能参与按键状态合并，否则缺失字段会被当成松键。
        guard relevant.allSatisfy({ $0.bitOffset + $0.count * $0.size <= payload.count * 8 }) else { return nil }

        var pressed = Set<HIDUsage>()
        for field in relevant {
            for index in 0..<field.count {
                let start = field.bitOffset + index * field.size
                guard start + field.size <= payload.count * 8 else { break }
                let value = Self.bits(payload, from: start, count: field.size)
                let usage: UInt32?
                if field.isArray {
                    let v = Int64(value)
                    guard v >= field.logicalMin, v <= field.logicalMax else { continue }
                    let n = Int(v - field.logicalMin)
                    usage = field.usages.isEmpty ? field.usageMin + UInt32(n) : (n < field.usages.count ? field.usages[n] : nil)
                } else {
                    guard value != 0 else { continue }
                    if !field.usages.isEmpty {
                        usage = field.usages[min(index, field.usages.count - 1)]
                    } else {
                        let u = field.usageMin + UInt32(index)
                        usage = u <= field.usageMax ? u : nil
                    }
                }
                guard let usage else { continue }
                let page = UInt16(truncatingIfNeeded: usage >> 16), id = UInt16(truncatingIfNeeded: usage & 0xFFFF)
                switch page {
                case 0x07 where (0x04...0xE7).contains(id): pressed.insert(.keyboard(id))
                case 0x0C where id != 0: pressed.insert(.consumer(id))
                default: break
                }
            }
        }
        return (reportID, pressed)
    }

    static func bits(_ bytes: [UInt8], from start: Int, count: Int) -> UInt32 {
        var value: UInt32 = 0
        for k in 0..<count {
            let bit = start + k
            if bytes[bit / 8] & (1 << (bit % 8)) != 0 { value |= 1 << k }
        }
        return value
    }
}

/// Turns per-source "pressed" snapshots into down/up events on the union of all sources, so a key reported
/// by both the boot and the NKRO interface yields a single event.
public struct KeyStateTracker: Sendable {
    private var sources: [Int: Set<HIDUsage>] = [:]

    public init() {}

    public var pressed: Set<HIDUsage> { sources.values.reduce(into: []) { $0.formUnion($1) } }

    public mutating func update(source: Int, pressed now: Set<HIDUsage>, timestamp: UInt64) -> [KeyEvent] {
        let before = pressed
        sources[source] = now
        let after = pressed
        let released = before.subtracting(after).sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
        let newlyPressed = after.subtracting(before).sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
        return released.map { KeyEvent(usage: $0, isDown: false, timestamp: timestamp) }
            + newlyPressed.map { KeyEvent(usage: $0, isDown: true, timestamp: timestamp) }
    }
}
