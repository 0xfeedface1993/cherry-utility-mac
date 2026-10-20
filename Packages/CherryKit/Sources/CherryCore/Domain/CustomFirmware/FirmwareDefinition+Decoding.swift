import Foundation

// Definition file, schema 1 (JSON):
//
// {
//   "schema": 1, "id": "…", "name": "…", "notes": "…",
//   "firmware": { "vendorID": "046A", "productID": "01E2", "versionCode": "0117",
//                 "catalogName": "MX_PIXIU75_WIRELESS_0117", "size": 165972, "crc32": "CFE1A03E" },
//   "palettes": [ { "id": "…", "items": [ { "id": "…", "name": "…", "bytes": "30 E2 00" } ] } ],
//   "groups":   [ { "id": "…", "name": "…", "detail": "…" } ],
//   "options":  [
//     { "id": "…", "group": "…", "name": "…", "detail": "…", "stability": "verified|experimental",
//       "values": [ { "id": "on", "name": "…", "edits": [ { "offset": "0x2550", "original": "03C54A01", "replacement": "0B656015" } ] } ] },
//     { "id": "…", "group": "…", "name": "…",
//       "slot": { "offset": "0x1F1F9", "original": "A0 00 00", "palette": "…" } }
//   ]
// }
//
// Numbers are decimal; strings holding numbers are hexadecimal (an optional "0x" prefix is allowed). A `values` option
// gets an implicit stock value ("stock", no edits). A `slot` option offers every palette item for the same bytes; the
// item equal to the stock bytes becomes the stock value (or a nameless "stock" value is added when none is).

extension FirmwareDefinition {
    public static let stockValueID = "stock"

    /// Parses and validates one definition file. `source` names the file in error reports.
    public static func decode(_ data: Data, source: String) throws -> FirmwareDefinition {
        let file: DefinitionFile
        do {
            file = try JSONDecoder().decode(DefinitionFile.self, from: data)
        } catch {
            throw CustomFirmwareError.invalidDefinition(source: source, issues: [.malformed(String(describing: error))])
        }
        guard file.schema == supportedSchema else {
            throw CustomFirmwareError.invalidDefinition(source: source, issues: [.unsupportedSchema(file.schema)])
        }
        var builder = DefinitionBuilder()
        let definition = builder.build(file)
        guard builder.issues.isEmpty, let definition else {
            throw CustomFirmwareError.invalidDefinition(source: source, issues: builder.issues)
        }
        return definition
    }
}

private struct DefinitionBuilder {
    var issues: [DefinitionIssue] = []

    mutating func build(_ file: DefinitionFile) -> FirmwareDefinition? {
        let fingerprint = firmware(file.firmware)
        var groups: [OptionGroup] = []
        for g in file.groups {
            if groups.contains(where: { $0.id == g.id }) { issues.append(.duplicateID(g.id)) }
            groups.append(OptionGroup(id: g.id, name: g.name, detail: g.detail))
        }
        var palettes: [String: [(id: String, name: String, bytes: [UInt8])]] = [:]
        for p in file.palettes ?? [] {
            if palettes[p.id] != nil { issues.append(.duplicateID(p.id)) }
            palettes[p.id] = p.items.compactMap { item in
                guard let bytes = Hex.bytes(item.bytes) else {
                    issues.append(.invalidHex(field: "palettes.\(p.id).\(item.id)"))
                    return nil
                }
                return (item.id, item.name, bytes)
            }
        }

        var options: [CustomizationOption] = []
        for o in file.options {
            if options.contains(where: { $0.id == o.id }) { issues.append(.duplicateID(o.id)) }
            if !groups.contains(where: { $0.id == o.group }) { issues.append(.unknownGroup(option: o.id, group: o.group)) }
            let stability: OptionStability
            switch o.stability {
            case nil: stability = .experimental
            case let raw?:
                guard let parsed = OptionStability(rawValue: raw) else {
                    issues.append(.malformed("option \(o.id): stability \(raw)"))
                    continue
                }
                stability = parsed
            }
            guard let values = values(of: o, palettes: palettes) else { continue }
            options.append(CustomizationOption(
                id: o.id, groupID: o.group, name: o.name, detail: o.detail, stability: stability, values: values,
                isToggle: o.slot == nil && o.values?.count == 1
            ))
        }
        guard let fingerprint else { return nil }
        check(options, size: fingerprint.size, protected: [0 ..< 0x30, fingerprint.size - 4 ..< fingerprint.size])
        return FirmwareDefinition(id: file.id, name: file.name, notes: file.notes, firmware: fingerprint, groups: groups, options: options)
    }

    mutating func firmware(_ f: DefinitionFile.Firmware) -> FirmwareFingerprint? {
        func field<T: FixedWidthInteger>(_ scalar: Scalar, _ name: String, as: T.Type) -> T? {
            guard let v = scalar.integer, let t = T(exactly: v) else {
                issues.append(.invalidHex(field: "firmware.\(name)"))
                return nil
            }
            return t
        }
        let vid = field(f.vendorID, "vendorID", as: UInt16.self)
        let pid = field(f.productID, "productID", as: UInt16.self)
        let version = field(f.versionCode, "versionCode", as: UInt16.self)
        let crc = field(f.crc32, "crc32", as: UInt32.self)
        guard f.size > 0x30, f.size <= UpdaterImage.maxFirmwareSize else {
            issues.append(.malformed("firmware.size \(f.size)"))
            return nil
        }
        guard let vid, let pid, let version, let crc else { return nil }
        return FirmwareFingerprint(vendorID: vid, productID: pid, versionCode: version, catalogName: f.catalogName, size: f.size, crc: crc)
    }

    mutating func values(
        of o: DefinitionFile.Option, palettes: [String: [(id: String, name: String, bytes: [UInt8])]]
    ) -> [OptionValue]? {
        switch (o.values, o.slot) {
        case (let explicit?, nil):
            guard !explicit.isEmpty else {
                issues.append(.noValues(option: o.id))
                return nil
            }
            var values = [OptionValue(id: FirmwareDefinition.stockValueID, name: "", isStock: true, edits: [])]
            for v in explicit {
                if values.contains(where: { $0.id == v.id }) { issues.append(.duplicateID("\(o.id).\(v.id)")) }
                let edits = v.edits.compactMap { edit(o.id, v.id, $0) }
                guard edits.count == v.edits.count else { continue }
                values.append(OptionValue(id: v.id, name: v.name, isStock: false, edits: edits))
            }
            return values

        case (nil, let slot?):
            guard let items = palettes[slot.palette] else {
                issues.append(.unknownPalette(option: o.id, palette: slot.palette))
                return nil
            }
            guard let offset = slot.offset.integer, let original = Hex.bytes(slot.original), !original.isEmpty else {
                issues.append(.invalidHex(field: "options.\(o.id).slot"))
                return nil
            }
            var stock: OptionValue?
            var others: [OptionValue] = []
            for item in items {
                guard item.bytes.count == original.count else {
                    issues.append(.lengthMismatch(option: o.id, value: item.id))
                    continue
                }
                if item.bytes == original {
                    stock = OptionValue(id: item.id, name: item.name, isStock: true, edits: [])
                } else {
                    others.append(OptionValue(id: item.id, name: item.name, isStock: false,
                                              edits: [ByteEdit(offset: offset, original: original, replacement: item.bytes)]))
                }
            }
            let stockValue = stock ?? OptionValue(id: FirmwareDefinition.stockValueID, name: "", isStock: true, edits: [])
            if others.contains(where: { $0.id == stockValue.id }) { issues.append(.duplicateID("\(o.id).\(stockValue.id)")) }
            // The slot's own range is checked even when only the stock value exists.
            let probe = ByteEdit(offset: offset, original: original, replacement: original)
            return [OptionValue(id: stockValue.id, name: stockValue.name, isStock: true, edits: stock == nil ? [] : [probe])] + others

        default:
            issues.append(.malformed("option \(o.id) needs exactly one of values / slot"))
            return nil
        }
    }

    mutating func edit(_ option: String, _ value: String, _ e: DefinitionFile.Edit) -> ByteEdit? {
        guard let offset = e.offset.integer, let original = Hex.bytes(e.original), let replacement = Hex.bytes(e.replacement) else {
            issues.append(.invalidHex(field: "options.\(option).\(value)"))
            return nil
        }
        guard !original.isEmpty, original.count == replacement.count else {
            issues.append(.lengthMismatch(option: option, value: value))
            return nil
        }
        return ByteEdit(offset: offset, original: original, replacement: replacement)
    }

    /// Ranges inside the image and outside the header/CRC; no two options touch the same byte, and no value
    /// touches a byte twice. Values of one option may share bytes (they are alternatives).
    mutating func check(_ options: [CustomizationOption], size: Int, protected: [Range<Int>]) {
        var claimed: [(range: Range<Int>, option: String)] = []
        for option in options {
            var ranges: [Range<Int>] = []
            for value in option.values {
                var own: [Range<Int>] = []
                for e in value.edits {
                    guard e.offset >= 0, e.range.upperBound <= size else {
                        issues.append(.outOfRange(option: option.id, offset: e.offset))
                        continue
                    }
                    if protected.contains(where: { $0.overlaps(e.range) }) {
                        issues.append(.protectedRange(option: option.id, offset: e.offset))
                    }
                    if own.contains(where: { $0.overlaps(e.range) }) {
                        issues.append(.overlap(option: option.id, other: option.id, offset: e.offset))
                    }
                    own.append(e.range)
                }
                ranges += own
            }
            for range in ranges {
                if let clash = claimed.first(where: { $0.option != option.id && $0.range.overlaps(range) }) {
                    issues.append(.overlap(option: option.id, other: clash.option, offset: range.lowerBound))
                }
            }
            claimed += ranges.map { ($0, option.id) }
        }
    }
}

// MARK: - File format

private struct DefinitionFile: Decodable {
    let schema: Int
    let id: String
    let name: String
    let notes: String?
    let firmware: Firmware
    let palettes: [Palette]?
    let groups: [Group]
    let options: [Option]

    struct Firmware: Decodable {
        let vendorID: Scalar
        let productID: Scalar
        let versionCode: Scalar
        let catalogName: String
        let size: Int
        let crc32: Scalar
    }

    struct Palette: Decodable {
        let id: String
        let items: [Item]
        struct Item: Decodable {
            let id: String
            let name: String
            let bytes: String
        }
    }

    struct Group: Decodable {
        let id: String
        let name: String
        let detail: String?
    }

    struct Option: Decodable {
        let id: String
        let group: String
        let name: String
        let detail: String?
        let stability: String?
        let values: [Value]?
        let slot: Slot?
    }

    struct Value: Decodable {
        let id: String
        let name: String
        let edits: [Edit]
    }

    struct Edit: Decodable {
        let offset: Scalar
        let original: String
        let replacement: String
    }

    struct Slot: Decodable {
        let offset: Scalar
        let original: String
        let palette: String
    }
}

/// A JSON number (decimal) or a string holding a hexadecimal number.
private enum Scalar: Decodable {
    case number(Int)
    case text(String)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self = .number(n)
        } else {
            self = .text(try c.decode(String.self))
        }
    }

    var integer: Int? {
        switch self {
        case .number(let n): n
        case .text(let s): Hex.integer(s)
        }
    }
}

enum Hex {
    static func integer(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { t.removeFirst(2) }
        return t.isEmpty ? nil : Int(t, radix: 16)
    }

    /// "03C54A01" or "03 C5 4A 01".
    static func bytes(_ s: String) -> [UInt8]? {
        let digits = Array(s.filter { !$0.isWhitespace })
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let b = UInt8(String(digits[i ... i + 1]), radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }
}
