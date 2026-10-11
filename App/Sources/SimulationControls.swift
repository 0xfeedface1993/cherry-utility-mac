import AppKit
import CherryAdapters
import CherryCore
import SwiftUI

/// Simulation-mode hooks: hot-plug commands and key input routed from AppKit into the simulated keyboard.
final class SimulationControls: Sendable {
    let hub: SimulatedKeyboardHub
    let keyInput: SimulatedKeyInput

    init(hub: SimulatedKeyboardHub) {
        self.hub = hub
        keyInput = SimulatedKeyInput(hub: hub)
    }
}

/// Turns key events the app receives (typed by a UI test or a person) into HID usages of the simulated keyboard,
/// and implements "suppress app shortcuts" on the same monitor so the two never race.
final class SimulatedKeyInput: Sendable {
    private let hub: SimulatedKeyboardHub
    private let state = MainActorBox()

    @MainActor private final class MainActorBox: Sendable {
        var monitor: Any?
        var suppressions = 0
        nonisolated init() {}
    }

    init(hub: SimulatedKeyboardHub) {
        self.hub = hub
    }

    @MainActor
    func start() {
        guard state.monitor == nil else { return }
        let hub = hub
        let state = state
        state.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            Self.forward(event, to: hub)
            return state.suppressions > 0 ? nil : event
        }
    }

    @MainActor
    func suppressUntilCancelled() async {
        state.suppressions += 1
        defer { state.suppressions -= 1 }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    @MainActor
    private static func forward(_ event: NSEvent, to hub: SimulatedKeyboardHub) {
        guard let usage = usages[event.keyCode] else { return }
        switch event.type {
        case .keyDown where !event.isARepeat: hub.inject(usage, isDown: true)
        case .keyUp: hub.inject(usage, isDown: false)
        case .flagsChanged:
            guard let flag = modifierFlags[event.keyCode] else { return }
            hub.inject(usage, isDown: event.modifierFlags.contains(flag))
        default: break
        }
    }

    private static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
        0x37: .command, 0x36: .command, 0x38: .shift, 0x3C: .shift, 0x3A: .option, 0x3D: .option,
        0x3B: .control, 0x3E: .control, 0x39: .capsLock,
    ]

    /// macOS virtual key code → HID keyboard usage (page 0x07), for the keys a PIXIU 75 has.
    private static let usages: [UInt16: HIDUsage] = {
        let table: [UInt16: UInt16] = [
            0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B,
            0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13,
            0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
            0x10: 0x1C, 0x06: 0x1D,
            0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25,
            0x19: 0x26, 0x1D: 0x27,
            0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F,
            0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
            0x39: 0x39,
            0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41,
            0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, 0x69: 0x46,
            0x74: 0x4B, 0x75: 0x4C, 0x79: 0x4E, 0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,
            0x3B: 0xE0, 0x38: 0xE1, 0x3A: 0xE2, 0x37: 0xE3, 0x3E: 0xE4, 0x3C: 0xE5, 0x3D: 0xE6, 0x36: 0xE7,
        ]
        return table.mapValues { HIDUsage.keyboard($0) }
    }()
}

/// "模拟设备" menu, present only in simulation mode.
struct SimulationCommands: Commands {
    let controls: SimulationControls?

    var body: some Commands {
        if let controls {
            CommandMenu("模拟设备") {
                Button("拔出键盘") { controls.hub.unplug() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Button("插入键盘") { controls.hub.plug() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
    }
}
