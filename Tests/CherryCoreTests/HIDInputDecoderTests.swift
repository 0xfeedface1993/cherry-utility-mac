import Testing
@testable import CherryCore

/// Descriptors dumped from a real PIXIU 75 (interfaces 0 and 1).
@Suite("HID input decoding")
struct HIDInputDecoderTests {
    static let bootKeyboard = hex("""
    05 01 09 06 A1 01 05 07 19 E0 29 E7 15 00 25 01 75 01 95 08 81 02 95 01 75 08 81 01 95 05 75 01 05 08 19 01 29 05 91 02 95 01 75 03 91 01 95 06 75 08
    15 00 26 FF 00 05 07 19 00 2A FF 00 81 00 05 0C 09 00 15 80 25 7F 95 40 75 08 B1 02 C0
    """)

    static let composite = hex("""
    05 01 09 06 A1 01 85 01 05 07 19 04 29 70 15 00 25 01 75 01 95 78 81 02 C0 05 01 09 80 A1 01 85 02 05 01 19 81 29 83 15 00 25 01 95 03 75 01 81 02 95
    01 75 05 81 01 C0 05 0C 09 01 A1 01 85 03 15 00 26 FF 1F 19 00 2A FF 1F 75 10 95 01 81 00 C0 06 1C FF 09 92 A1 01 85 04 19 00 2A FF 00 15 00 26 FF 00
    75 08 95 3F 91 00 19 00 2A FF 00 81 00 C0 05 01 09 00 A1 01 85 05 15 00 26 FF 00 75 08 95 20 09 01 81 02 09 02 91 02 C0 05 01 09 02 A1 01 85 06 09 01
    A1 00 05 09 19 01 29 05 15 00 25 01 95 05 75 01 81 02 95 01 75 03 81 01 05 01 09 30 09 31 16 00 80 26 FF 7F 75 10 95 02 81 06 09 38 15 81 25 7F 75 08
    95 01 81 06 05 0C 0A 38 02 15 81 25 7F 75 08 95 01 81 06 C0 C0
    """)

    static func hex(_ s: String) -> [UInt8] {
        s.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
    }

    @Test func bootKeyboardModifiersAndArray() throws {
        let decoder = HIDInputDecoder(descriptor: Self.bootKeyboard)
        #expect(!decoder.usesReportIDs)
        // Left Shift + A + S
        let report: [UInt8] = [0x02, 0x00, 0x04, 0x16, 0, 0, 0, 0]
        let decoded = try #require(decoder.pressedUsages(in: report))
        #expect(decoded.usages == [.keyboard(0xE1), .keyboard(0x04), .keyboard(0x16)])
        #expect(decoder.pressedUsages(in: [UInt8](repeating: 0, count: 8))?.usages == [])
    }

    @Test func nkroBitmapAndConsumerArray() throws {
        let decoder = HIDInputDecoder(descriptor: Self.composite)
        #expect(decoder.usesReportIDs)
        #expect(decoder.keyReportIDs == [1, 3])

        var nkro = [UInt8](repeating: 0, count: 16)
        nkro[0] = 1
        nkro[1] = 0b0000_0001          // bit 0 → usage 0x04 (A)
        nkro[1 + (0x29 - 0x04) / 8] |= 1 << ((0x29 - 0x04) % 8) // Esc
        #expect(decoder.pressedUsages(in: nkro)?.usages == [.keyboard(0x04), .keyboard(0x29)])

        // Consumer Volume Up (0xE9), as the knob sends it.
        let consumer: [UInt8] = [3, 0xE9, 0x00]
        #expect(decoder.pressedUsages(in: consumer)?.usages == [.consumer(0xE9)])
        #expect(decoder.pressedUsages(in: [3, 0, 0])?.usages == [])
        // Vendor and mouse reports are not key reports.
        #expect(decoder.pressedUsages(in: [4] + [UInt8](repeating: 0, count: 63)) == nil)
        #expect(decoder.pressedUsages(in: [6, 1, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test func trackerMergesSourcesIntoSingleEvents() {
        var tracker = KeyStateTracker()
        // Boot interface and NKRO interface both report A.
        #expect(tracker.update(source: 0, pressed: [.keyboard(0x04)], timestamp: 1) == [KeyEvent(usage: .keyboard(0x04), isDown: true, timestamp: 1)])
        #expect(tracker.update(source: 1, pressed: [.keyboard(0x04)], timestamp: 2).isEmpty)
        #expect(tracker.update(source: 0, pressed: [], timestamp: 3).isEmpty)
        #expect(tracker.update(source: 1, pressed: [], timestamp: 4) == [KeyEvent(usage: .keyboard(0x04), isDown: false, timestamp: 4)])
    }
}
