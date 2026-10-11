import Foundation

public struct KeyCap: Equatable, Sendable, Identifiable {
    public let id: Int
    public let label: String
    /// nil for keys the keyboard consumes internally (Fn) – they can't be observed over HID.
    public let usage: HIDUsage?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(id: Int, label: String, usage: HIDUsage?, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.label = label
        self.usage = usage
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct KeyboardLayout: Equatable, Sendable {
    public let name: String
    public let keys: [KeyCap]

    public init(name: String, keys: [KeyCap]) {
        self.name = name
        self.keys = keys
    }

    public var width: Double { keys.map { $0.x + $0.width }.max() ?? 0 }
    public var height: Double { keys.map { $0.y + $0.height }.max() ?? 0 }

    public var testableKeys: [KeyCap] { keys.filter { $0.usage != nil } }

    public func key(for usage: HIDUsage) -> KeyCap? {
        keys.first { $0.usage == usage }
    }
}
