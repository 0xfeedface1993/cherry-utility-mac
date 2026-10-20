import CherryCore
import Testing
@testable import CherryAdapters

@Suite("HID 发现缓存与对象身份移除")
struct HIDDiscoveryInventoryTests {
    static func summary(interface: UInt64, location: UInt32 = 1, transport: String = "USB") -> KeyboardSummary {
        .init(id: .init(vendorID: 0x046A, productID: 0x01E2, locationID: location), product: "PIXIU 75", manufacturer: "CHERRY", serialNumber: nil, transport: transport, releaseNumber: 0x0117,
              interfaces: [.init(id: interface, usages: [.init(page: interface == 2 ? 0xFF1C : 0x01, usage: 0x06)], maxInputReportSize: 64, maxOutputReportSize: 64, maxFeatureReportSize: 0, collections: [])])
    }
    @Test func removalUsesCachedIDAndLastInterfaceEmptiesList() {
        var inventory = HIDDiscoveryInventory<Int>()
        inventory.insert(Self.summary(interface: 1), token: 101)
        inventory.insert(Self.summary(interface: 2), token: 102)
        #expect(inventory.summaries.count == 1 && inventory.summaries.first?.canConfigure == true)
        let removed = inventory.remove(token: 102)
        #expect(removed?.interfaces.first?.id == 2)
        #expect(inventory.summaries.first?.transport == "USB")
        #expect(inventory.summaries.first?.firmwareVersion.code == 0x0117)
        #expect(inventory.summaries.first?.canConfigure == false)
        _ = inventory.remove(token: 101)
        #expect(inventory.summaries.isEmpty)
        #expect(inventory.remove(token: 101) == nil)
    }
    @Test func twoDevicesRemainSeparateAndReenumerationReplacesOldMetadata() {
        var inventory = HIDDiscoveryInventory<Int>()
        inventory.insert(Self.summary(interface: 2), token: 102)
        inventory.insert(Self.summary(interface: 3, location: 2), token: 103)
        #expect(inventory.summaries.count == 2)
        _ = inventory.remove(token: 102)
        #expect(inventory.summaries.first?.id.locationID == 2)
        inventory.insert(Self.summary(interface: 4, transport: "Bluetooth"), token: 104)
        #expect(inventory.summaries.first?.transport == "Bluetooth")
    }
    @Test func unknownTransportNeverUsesQuestionMark() {
        var inventory = HIDDiscoveryInventory<Int>()
        inventory.insert(Self.summary(interface: 2, transport: "?"), token: 102)
        #expect(inventory.summaries.first?.transport == "")
    }
}
