import Foundation

public struct LEDColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses `#RRGGBB` / `RRGGBB`.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }

    public var description: String { String(format: "#%02X%02X%02X", r, g, b) }

    public static let white = LEDColor(r: 0xFF, g: 0xFF, b: 0xFF)
}

/// One entry of a model's lighting-effect table: the raw value stored in profile byte 1 and its name.
public struct LightingEffect: Hashable, Sendable, Identifiable {
    public let rawValue: UInt8
    public let name: String
    public let englishName: String
    public let symbol: String

    public init(rawValue: UInt8, name: String, englishName: String, symbol: String) {
        self.rawValue = rawValue
        self.name = name
        self.englishName = englishName
        self.symbol = symbol
    }

    public var id: UInt8 { rawValue }
}

/// The user-editable part of a profile block. Values are in UI units; `ProfileConfig` handles the byte encoding.
public struct ProfileSettings: Equatable, Sendable, Codable {
    public static let brightnessRange = 0...4
    public static let speedRange = 0...4
    /// First-stage sleep: 0 = never, otherwise seconds.
    public static let sleepSecondsRange = 30...300
    /// Second-stage (deep) sleep: 0 = never, otherwise minutes.
    public static let deepSleepMinutesRange = 15...300

    public var effect: UInt8
    /// 0 (off) … 4 (full).
    public var brightness: Int
    /// 0 (slowest) … 4 (fastest).
    public var speed: Int
    public var randomColor: Bool
    public var color: LEDColor
    public var sleepSeconds: Int
    public var deepSleepMinutes: Int

    public init(
        effect: UInt8, brightness: Int, speed: Int, randomColor: Bool, color: LEDColor, sleepSeconds: Int,
        deepSleepMinutes: Int
    ) {
        self.effect = effect
        self.brightness = brightness
        self.speed = speed
        self.randomColor = randomColor
        self.color = color
        self.sleepSeconds = sleepSeconds
        self.deepSleepMinutes = deepSleepMinutes
    }

    /// Clamped into what the firmware and the official UI accept.
    public var normalized: ProfileSettings {
        var s = self
        s.brightness = s.brightness.clamped(to: Self.brightnessRange)
        s.speed = s.speed.clamped(to: Self.speedRange)
        if s.sleepSeconds != 0 { s.sleepSeconds = s.sleepSeconds.clamped(to: Self.sleepSecondsRange) }
        if s.deepSleepMinutes != 0 { s.deepSleepMinutes = s.deepSleepMinutes.clamped(to: Self.deepSleepMinutesRange) }
        return s
    }
}

/// One independently editable setting; drives dirty tracking and partial writes.
public enum ProfileField: String, CaseIterable, Hashable, Sendable {
    case effect, brightness, speed, randomColor, color, sleepSeconds, deepSleepMinutes

    public func value(in s: ProfileSettings) -> AnyHashable {
        switch self {
        case .effect: s.effect
        case .brightness: s.brightness
        case .speed: s.speed
        case .randomColor: s.randomColor
        case .color: s.color
        case .sleepSeconds: s.sleepSeconds
        case .deepSleepMinutes: s.deepSleepMinutes
        }
    }

    /// Copies this field from `source` into `target`.
    public func copy(from source: ProfileSettings, into target: inout ProfileSettings) {
        switch self {
        case .effect: target.effect = source.effect
        case .brightness: target.brightness = source.brightness
        case .speed: target.speed = source.speed
        case .randomColor: target.randomColor = source.randomColor
        case .color: target.color = source.color
        case .sleepSeconds: target.sleepSeconds = source.sleepSeconds
        case .deepSleepMinutes: target.deepSleepMinutes = source.deepSleepMinutes
        }
    }

    public static func differences(between a: ProfileSettings, and b: ProfileSettings) -> Set<ProfileField> {
        Set(allCases.filter { $0.value(in: a) != $0.value(in: b) })
    }
}

/// The fields to change in a profile; everything else is preserved from what the keyboard currently holds.
public struct ProfilePatch: Equatable, Sendable {
    public private(set) var values: ProfileSettings?
    public private(set) var fields: Set<ProfileField>

    public init(_ values: ProfileSettings, fields: Set<ProfileField>) {
        self.values = fields.isEmpty ? nil : values
        self.fields = fields
    }

    public static func all(_ settings: ProfileSettings) -> ProfilePatch {
        ProfilePatch(settings, fields: Set(ProfileField.allCases))
    }

    public static func set<V>(_ keyPath: WritableKeyPath<ProfileSettings, V>, _ value: V, field: ProfileField, on base: ProfileSettings) -> ProfilePatch {
        var s = base
        s[keyPath: keyPath] = value
        return ProfilePatch(s, fields: [field])
    }

    public var isEmpty: Bool { fields.isEmpty }

    public func applied(to current: ProfileSettings) -> ProfileSettings {
        guard let values else { return current }
        var result = current
        for field in fields { field.copy(from: values, into: &result) }
        return result.normalized
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
