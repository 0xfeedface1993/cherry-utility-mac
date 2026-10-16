import Foundation

extension KeyboardID: LosslessStringConvertible {
    /// Parses `description` (`046A:01E2@03100000`): how automation entry points name a keyboard.
    public init?(_ description: String) {
        let parts = description.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let ids = parts[0].split(separator: ":", omittingEmptySubsequences: false)
        guard ids.count == 2, ids[0].count == 4, ids[1].count == 4, parts[1].count == 8,
              (ids + [parts[1]]).allSatisfy({ $0.allSatisfy(\.isHexDigit) }),
              let vendorID = UInt16(ids[0], radix: 16), let productID = UInt16(ids[1], radix: 16),
              let locationID = UInt32(parts[1], radix: 16) else { return nil }
        self.init(vendorID: vendorID, productID: productID, locationID: locationID)
    }
}
