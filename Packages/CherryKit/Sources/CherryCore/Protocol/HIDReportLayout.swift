import Foundation

/// Just enough of a HID report-descriptor parser to answer what Windows' `HidP_GetCaps`
/// gives the original updater: which report IDs belong to a top-level collection and how
/// long each input/output report is (in bytes, including the report-ID byte).
public struct HIDReportLayout: Sendable {
    public struct Collection: Sendable {
        public var usagePage: UInt16
        public var usage: UInt16
        public var inputBits: [UInt8: Int] = [:]
        public var outputBits: [UInt8: Int] = [:]
        public var featureBits: [UInt8: Int] = [:]
    }

    public private(set) var collections: [Collection] = []

    public init(descriptor d: [UInt8]) {
        var usagePage: UInt32 = 0
        var reportSize = 0, reportCount = 0
        var reportID: UInt8 = 0
        var pendingUsages: [UInt32] = []
        var globalStack: [(UInt32, Int, Int, UInt8)] = []
        var depth = 0
        var current = -1

        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE { // long item
                guard i + 1 < d.count else { break }
                i += 3 + Int(d[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard i + size < d.count else { break }
            var value: UInt32 = 0
            for k in 0..<size { value |= UInt32(d[i + 1 + k]) << (8 * k) }
            let type = (prefix >> 2) & 3, tag = prefix >> 4
            i += 1 + size

            switch (type, tag) {
            case (1, 0x0): usagePage = value
            case (1, 0x7): reportSize = Int(value)
            case (1, 0x8): reportID = UInt8(truncatingIfNeeded: value)
            case (1, 0x9): reportCount = Int(value)
            case (1, 0xA): globalStack.append((usagePage, reportSize, reportCount, reportID))
            case (1, 0xB): if let s = globalStack.popLast() { (usagePage, reportSize, reportCount, reportID) = s }
            case (2, 0x0): pendingUsages.append(size == 4 ? value : (usagePage << 16) | value)
            case (0, 0xA): // Collection
                if depth == 0 {
                    let u = pendingUsages.first ?? (usagePage << 16)
                    collections.append(Collection(usagePage: UInt16(u >> 16), usage: UInt16(u & 0xFFFF)))
                    current = collections.count - 1
                }
                depth += 1
                pendingUsages.removeAll()
            case (0, 0xC): depth = max(0, depth - 1); pendingUsages.removeAll()
            case (0, 0x8), (0, 0x9), (0, 0xB): // Input / Output / Feature
                if current >= 0 {
                    let bits = reportSize * reportCount
                    switch tag {
                    case 0x8: collections[current].inputBits[reportID, default: 0] += bits
                    case 0x9: collections[current].outputBits[reportID, default: 0] += bits
                    default: collections[current].featureBits[reportID, default: 0] += bits
                    }
                }
                pendingUsages.removeAll()
            default: break
            }
        }
    }

    public func collection(usagePage: UInt16) -> Collection? {
        collections.first { $0.usagePage == usagePage }
    }

    public static func byteLength(bits: Int, reportID: UInt8) -> Int {
        (bits + 7) / 8 + (reportID != 0 ? 1 : 0)
    }
}

extension HIDReportLayout.Collection {
    /// Report sizes in bytes (report ID byte included), as `HidP_GetCaps` would report them.
    public var summary: HIDCollectionSummary {
        func bytes(_ m: [UInt8: Int]) -> [UInt8: Int] {
            m.reduce(into: [:]) { $0[$1.key] = HIDReportLayout.byteLength(bits: $1.value, reportID: $1.key) }
        }
        return HIDCollectionSummary(
            usage: HIDUsage(page: usagePage, usage: usage),
            inputReports: bytes(inputBits), outputReports: bytes(outputBits), featureReports: bytes(featureBits)
        )
    }
}
